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
  }

  struct Value: ServerChildChannelValue {
    let upgrade: EventLoopFuture<Upgrade>
    let channel: any Channel
  }

  let responder: HTTPChannelHandler.Responder
  let gate: TunnelGate
  let tunnels: KernelTunnels
  let ping: Duration

  static func builder(gate: TunnelGate, tunnels: KernelTunnels, ping: Duration) -> HTTPServerBuilder
  {
    HTTPServerBuilder { responder in
      KernelTunnelChannel(responder: responder, gate: gate, tunnels: tunnels, ping: ping)
    }
  }

  func setup(channel: any Channel, logger: Logger) -> EventLoopFuture<Value> {
    let gate = gate
    return channel.eventLoop.makeCompletedFuture {
      let upgrader = NIOTypedWebSocketServerUpgrader<Upgrade>(
        maxFrameSize: KernelProtocol.maxMessage,
        shouldUpgrade: { channel, head in
          let refused = KernelProtocol.refusal(
            host: head.headers.first(name: "host"),
            path: String(head.uri.split(separator: "?", maxSplits: 1).first ?? ""),
            origin: head.headers.first(name: "origin"),
            protocols: head.headers[canonicalForm: "sec-websocket-protocol"].joined(
              separator: ", "),
            gate: gate
          )
          guard refused == nil else { return channel.eventLoop.makeSucceededFuture(nil) }
          return channel.eventLoop.makeSucceededFuture(
            HTTPHeaders([("Sec-WebSocket-Protocol", KernelProtocol.tunnelProtocol)]))
        },
        upgradePipelineHandler: { channel, head in
          channel.eventLoop.makeCompletedFuture {
            let socket = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
              wrappingChannelSynchronously: channel)
            return Upgrade.tunnel(socket, head.headers.first(name: "origin") ?? "")
          }
        }
      )
      let upgrade = NIOTypedHTTPServerUpgradeConfiguration<Upgrade>(
        upgraders: [upgrader],
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
    }
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
    let protocols = head.headers[canonicalForm: "sec-websocket-protocol"].map(String.init)
    let refused = KernelProtocol.refusal(
      host: head.headers.first(name: "host"),
      path: String(head.uri.split(separator: "?", maxSplits: 1).first ?? ""),
      origin: head.headers.first(name: "origin"),
      protocols: protocols.isEmpty ? nil : protocols.joined(separator: ", "),
      gate: gate
    )
    let websocket =
      head.headers[canonicalForm: "upgrade"].contains { $0.lowercased() == "websocket" }
      && head.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
      && head.headers.first(name: "sec-websocket-version") == "13"
      && head.headers.contains(name: "sec-websocket-key")
    guard let refused = refused ?? (websocket ? nil : (400, "bad upgrade")) else {
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
