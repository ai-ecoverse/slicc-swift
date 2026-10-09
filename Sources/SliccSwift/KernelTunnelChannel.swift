import CryptoKit
import Foundation
import HummingbirdCore
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOWebSocket
import ServiceLifecycle

struct KernelTunnelChannel: HTTPChannelHandler {
  enum Upgrade: Sendable {
    case http(NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>)
    case tunnel(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, String)
    case cdp(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
  }

  struct Value: ServerChildChannelValue {
    let upgrade: EventLoopFuture<Upgrade>
    let channel: any Channel
  }

  let responder: HTTPChannelHandler.Responder
  let gate: TunnelGate
  let tunnels: KernelTunnels
  let ping: Duration
  let cdp: CDPProxy?

  static func builder(gate: TunnelGate, tunnels: KernelTunnels, ping: Duration, cdp: CDPProxy?)
    -> HTTPServerBuilder
  {
    HTTPServerBuilder { responder in
      KernelTunnelChannel(responder: responder, gate: gate, tunnels: tunnels, ping: ping, cdp: cdp)
    }
  }

  func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
    let gate = gate
    return channel.eventLoop.makeCompletedFuture {
      let upgrade = NIOTypedHTTPServerUpgradeConfiguration<Upgrade>(
        upgraders: [SocketUpgrader(gate: gate)],
        notUpgradingCompletionHandler: { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))
            try channel.pipeline.syncOperations.addHandler(
              HTTPConnectionStateHandler(idleTimeout: nil, logger: logger))
            return Upgrade.http(
              try NIOAsyncChannel(
                wrappingChannelSynchronously: channel,
                configuration: .init(isOutboundHalfClosureEnabled: true)))
          }
        }
      )
      var configuration = NIOUpgradableHTTPServerPipelineConfiguration(
        upgradeConfiguration: upgrade)
      configuration.enablePipelining = false
      configuration.enableErrorHandling = false
      configuration.enableResponseHeaderValidation = false
      configuration.decoderConfiguration.maxHeaderFieldSize = RawFetchProtocol.maxHeaderBytes
      configuration.decoderConfiguration.maxHeaderListSize = RawFetchProtocol.maxHeaderBytes
      let future = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
        configuration: configuration)
      let upgradeHandler = try channel.pipeline.syncOperations.context(
        handlerType: NIOTypedHTTPServerUpgradeHandler<Upgrade>.self)
      try channel.pipeline.syncOperations.addHandler(
        UpgradeRefusal(gate: gate), position: .before(upgradeHandler.handler))
      return Value(upgrade: future, channel: channel)
    }
  }

  func handle(value: Value, logger: Logger) async {
    guard let upgrade = try? await value.upgrade.get() else { return }
    switch upgrade {
    case .http(let channel):
      await handleHTTP(asyncChannel: channel, logger: logger)
    case .tunnel(let socket, let origin):
      await KernelTunnelSession(socket: socket, origin: origin, tunnels: tunnels, ping: ping).run()
    case .cdp(let socket):
      if let cdp {
        await cdp.handle(socket)
      } else {
        try? await socket.channel.close()
      }
    }
  }

}

enum ProxyUpgrade {
  enum Decision: Sendable {
    case refuse(Int, String)
    case cdp
    case tunnel
  }

  static func decision(_ head: HTTPRequestHead, _ gate: TunnelGate) -> Decision {
    let protocols = head.headers[canonicalForm: "sec-websocket-protocol"].map(String.init)
    return route(
      host: head.headers.first(name: "host"),
      path: String(head.uri.split(separator: "?", maxSplits: 1).first ?? ""),
      origin: head.headers.first(name: "origin"),
      protocols: protocols.isEmpty ? nil : protocols.joined(separator: ", "),
      gate: gate
    )
  }

  static func route(
    host: String?, path: String, origin: String?, protocols: String?, gate: TunnelGate
  ) -> Decision {
    guard ProxySecurity.isLoopbackHost(host, port: gate.port.value) else {
      return .refuse(403, "host not allowed")
    }
    if path == CDPProtocol.path {
      if let refused = CDPProtocol.refusal(origin: origin, protocols: protocols, gate: gate) {
        return .refuse(refused.status, refused.message)
      }
      return .cdp
    }
    if let refused = KernelProtocol.refusal(
      host: host, path: path, origin: origin, protocols: protocols, gate: gate
    ) {
      return .refuse(refused.status, refused.message)
    }
    return .tunnel
  }
}

struct SocketUpgrader: NIOTypedHTTPServerProtocolUpgrader {
  typealias UpgradeResult = KernelTunnelChannel.Upgrade

  let supportedProtocol = "websocket"
  let requiredUpgradeHeaders: [String] = []
  let gate: TunnelGate

  func buildUpgradeResponse(
    channel: any Channel, upgradeRequest: HTTPRequestHead, initialResponseHeaders: HTTPHeaders
  ) -> EventLoopFuture<HTTPHeaders> {
    guard let key = upgradeRequest.headers.first(name: "sec-websocket-key"),
      upgradeRequest.headers.first(name: "sec-websocket-version") == "13"
    else {
      return channel.eventLoop.makeFailedFuture(ChannelError.inappropriateOperationForState)
    }
    let path = Self.path(upgradeRequest.uri)
    let selected =
      path == CDPProtocol.path ? CDPProtocol.cdpProtocol : KernelProtocol.tunnelProtocol
    var headers = initialResponseHeaders
    headers.replaceOrAdd(name: "upgrade", value: "websocket")
    headers.replaceOrAdd(name: "connection", value: "upgrade")
    headers.add(name: "sec-websocket-accept", value: Self.accept(key))
    headers.add(name: "sec-websocket-protocol", value: selected)
    return channel.eventLoop.makeSucceededFuture(headers)
  }

  func upgrade(channel: any Channel, upgradeRequest: HTTPRequestHead) -> EventLoopFuture<
    UpgradeResult
  > {
    let path = Self.path(upgradeRequest.uri)
    let limit = path == CDPProtocol.path ? CDPProtocol.maxMessage : KernelProtocol.maxMessage
    let origin = upgradeRequest.headers.first(name: "origin") ?? ""
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(WebSocketFrameEncoder())
      try channel.pipeline.syncOperations.addHandler(
        ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: limit)))
      try channel.pipeline.syncOperations.addHandler(WebSocketProtocolErrorHandler())
      let socket = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
        wrappingChannelSynchronously: channel)
      if path == CDPProtocol.path { return .cdp(socket) }
      return .tunnel(socket, origin)
    }
  }

  private static func path(_ uri: String) -> String {
    String(uri.split(separator: "?", maxSplits: 1).first ?? "")
  }

  private static func accept(_ key: String) -> String {
    let digest = Insecure.SHA1.hash(
      data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    return Data(digest).base64EncodedString()
  }
}

final class UpgradeRefusal: ChannelInboundHandler, RemovableChannelHandler, Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias InboundOut = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  let gate: TunnelGate
  private let refusing = NIOLockedValueBox(false)

  init(gate: TunnelGate) { self.gate = gate }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if refusing.withLockedValue({ $0 }) { return }
    guard case .head(let head) = unwrapInboundIn(data), head.headers.contains(name: "upgrade")
    else {
      return context.fireChannelRead(data)
    }
    let websocket =
      head.headers[canonicalForm: "upgrade"].contains { $0.lowercased() == "websocket" }
      && head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
      && head.headers.first(name: "sec-websocket-version") == "13"
      && head.headers.contains(name: "sec-websocket-key")
    let refusal: (status: Int, message: String)?
    switch ProxyUpgrade.decision(head, gate) {
    case .refuse(let status, let message):
      refusal = (status, message)
    case .cdp, .tunnel:
      refusal = websocket ? nil : (400, "bad upgrade")
    }
    guard let refused = refusal else {
      context.fireChannelRead(data)
      context.pipeline.syncOperations.removeHandler(self, promise: nil)
      return
    }
    refusing.withLockedValue { $0 = true }
    let body = ByteBuffer(string: "{\"error\":\"\(refused.message)\"}")
    let status = HTTPResponseStatus(statusCode: refused.status)
    let headers = HTTPHeaders([
      ("Content-Type", "application/json"),
      ("Content-Length", String(body.readableBytes)),
      (RawFetchProtocol.errorHeader, "1"),
      ("Connection", "close"),
    ])
    context.write(
      wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
      promise: nil)
    context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      context.close(promise: nil)
    }
  }
}

struct KernelTunnelSession {
  let socket: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
  let origin: String
  let tunnels: KernelTunnels
  let ping: Duration

  private static func closeFrame(_ code: UInt16, _ reason: String = "") -> WebSocketFrame {
    var data = ByteBuffer()
    data.writeInteger(code)
    data.writeString(reason)
    return WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
  }

  func run() async {
    let channel = socket.channel
    let (queue, sink) = AsyncStream<WebSocketFrame>.makeStream()
    let alive = NIOLockedValueBox(true)
    try? await socket.executeThenClose { inbound, outbound in
      let id = await tunnels.register(
        origin: origin,
        send: { sink.yield(WebSocketFrame(fin: true, opcode: .binary, data: $0)) },
        close: { channel.close(promise: nil) }
      )
      await withGracefulShutdownHandler {
        let pinger = Task {
          while (try? await Task.sleep(for: ping)) != nil {
            guard alive.withLockedValue({ $0 }) else {
              channel.close(promise: nil)
              return
            }
            alive.withLockedValue { $0 = false }
            sink.yield(WebSocketFrame(fin: true, opcode: .ping, data: ByteBuffer()))
          }
        }
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            var failed = false
            for await frame in queue where !failed {
              do {
                try await outbound.write(frame)
                if frame.opcode == .connectionClose { failed = true }
              } catch {
                failed = true
              }
              if failed { try? await channel.close() }
            }
          }
          if let close = await receive(inbound, tunnel: id, sink: sink, alive: alive) {
            sink.yield(close)
          }
          await tunnels.unregister(id)
          sink.finish()
          pinger.cancel()
        }
      } onGracefulShutdown: {
        channel.close(promise: nil)
      }
    }
  }

  private func receive(
    _ inbound: NIOAsyncChannelInboundStream<WebSocketFrame>, tunnel: Int,
    sink: AsyncStream<WebSocketFrame>.Continuation, alive: NIOLockedValueBox<Bool>
  ) async -> WebSocketFrame? {
    var message: ByteBuffer?
    var isText = false
    do {
      for try await frame in inbound {
        guard frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else {
          return Self.closeFrame(1002, "malformed tunnel frame")
        }
        let data = frame.unmaskedData
        switch frame.opcode {
        case .ping:
          sink.yield(WebSocketFrame(fin: true, opcode: .pong, data: data))
          continue
        case .pong:
          alive.withLockedValue { $0 = true }
          continue
        case .connectionClose:
          var reply = ByteBuffer()
          if let code = data.getInteger(at: data.readerIndex, as: UInt16.self) {
            reply.writeInteger(code)
          }
          return WebSocketFrame(fin: true, opcode: .connectionClose, data: reply)
        case .text, .binary:
          guard message == nil else { return Self.closeFrame(1002, "malformed tunnel frame") }
          isText = frame.opcode == .text
          message = data
        case .continuation:
          guard message != nil else { return Self.closeFrame(1002, "malformed tunnel frame") }
          var more = data
          message!.writeBuffer(&more)
        default:
          return Self.closeFrame(1002, "malformed tunnel frame")
        }
        guard let complete = message, complete.readableBytes <= KernelProtocol.maxMessage else {
          return Self.closeFrame(1009, "Max payload size exceeded")
        }
        guard frame.fin else { continue }
        message = nil
        if isText { return Self.closeFrame(1003, "binary frames only") }
        guard let decoded = KernelProtocol.decode(complete), KernelProtocol.valid(decoded) else {
          return Self.closeFrame(1002, "malformed tunnel frame")
        }
        await tunnels.receive(tunnel, decoded)
      }
    } catch {
      return nil
    }
    return nil
  }
}
