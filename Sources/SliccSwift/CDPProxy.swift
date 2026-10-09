import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import ServiceLifecycle

actor CDPProxy {
  let browser: String
  let reconnectDelay: Duration
  private let httpClient: HTTPClient
  private let log: @Sendable (String) -> Void
  private var cachedURL: String?
  private var chrome: ChromeLeg?
  private var connectTask: Task<ChromeLeg, Error>?
  private var connectingID: UUID?
  private var reconnectTask: Task<Void, Never>?
  private var activeClient: PageClient?
  private var chromeDropSlotHolderID: UUID?
  private var messageBuffer: ClientFrameBuffer?
  private var stopped = false

  init(
    httpClient: HTTPClient, browser: String, reconnectDelay: Duration,
    log: @escaping @Sendable (String) -> Void
  ) {
    self.httpClient = httpClient
    self.browser = browser
    self.reconnectDelay = reconnectDelay
    self.log = log
  }

  func handle(_ socket: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>) async {
    let (queue, sink) = AsyncStream<WebSocketFrame>.makeStream()
    let client = PageClient(
      send: { text in
        sink.yield(CDPFrames.text(text, mask: false))
      },
      close: { code, reason in
        sink.yield(CDPFrames.close(code, reason, mask: false))
      }
    )
    await addClient(client)
    let clientID = client.id
    let prepare = Task { await self.prepare(clientID) }
    let channel = socket.channel
    await withGracefulShutdownHandler {
      try? await socket.executeThenClose { inbound, outbound in
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            var failed = false
            for await frame in queue where !failed {
              do { try await outbound.write(frame) } catch { failed = true }
              if frame.opcode == .connectionClose { failed = true }
              if failed { try? await channel.close() }
            }
          }
          await self.readPage(inbound, clientID: clientID, sink: sink)
          sink.finish()
          prepare.cancel()
        }
      }
    } onGracefulShutdown: {
      channel.close(promise: nil)
    }
    prepare.cancel()
    removeClient(clientID)
  }

  func shutdown() async {
    stopped = true
    connectTask?.cancel()
    reconnectTask?.cancel()
    connectTask = nil
    connectingID = nil
    reconnectTask = nil
    cachedURL = nil
    messageBuffer = nil
    if let activeClient {
      activeClient.close(1000, "")
      self.activeClient = nil
    }
    let leg = chrome
    chrome = nil
    leg?.close()
  }

  private func prepare(_ clientID: UUID) async {
    do {
      let url = try await debuggerURL(fresh: chrome?.isOpen != true)
      try await ensure(url)
    } catch is CancellationError {
      return
    } catch {
      guard activeClient?.id == clientID else { return }
      log("cdp connection failed: \(error)")
      await closeActive(1000, "", drop: .clientDisconnected)
    }
  }

  private func debuggerURL(fresh: Bool) async throws -> String {
    if !fresh, let cachedURL { return cachedURL }
    let request = HTTPClientRequest(url: CDPProtocol.versionURL(browser))
    let response = try await httpClient.execute(request, timeout: .seconds(5))
    let body = try await response.body.collect(upTo: 1024 * 1024)
    guard response.status == .ok else {
      throw CDPError.discoveryFailed("json/version answered \(response.status.code)")
    }
    let url = try CDPProtocol.debuggerURL(Data(body.readableBytesView))
    _ = try CDPProtocol.endpoint(url)
    cachedURL = url
    return url
  }

  private func ensure(_ url: String) async throws {
    if let chrome, chrome.isOpen {
      try flush(chrome)
      return
    }
    if let pending = connectTask {
      let leg = try await pending.value
      let open = chrome?.isOpen == true ? chrome : (leg.isOpen ? leg : nil)
      if let open {
        do { try flush(open) } catch {
          await chromeClosed(open.id, buffer: nil, closeReason: "error")
        }
      }
      return
    }
    chrome?.close()
    chrome = nil
    let endpoint = try CDPProtocol.endpoint(url)
    let connectionID = UUID()
    let task: Task<ChromeLeg, Error> = Task.detached {
      let socket = try await CDPChrome.connect(endpoint, maxFrameSize: CDPProtocol.maxMessage)
      if Task.isCancelled {
        try? await socket.channel.close()
        throw CancellationError()
      }
      let leg = ChromeLeg(id: connectionID)
      leg.start(socket) { text in
        await self.deliver(text, connectionID: connectionID)
      } onClose: { reason in
        await self.chromeClosed(connectionID, buffer: nil, closeReason: reason)
      }
      return leg
    }
    connectTask = task
    connectingID = connectionID
    do {
      let leg = try await task.value
      guard connectingID == connectionID else {
        leg.close()
        return
      }
      chrome = leg
      connectTask = nil
      connectingID = nil
      log("cdp browser connected")
      do { try flush(leg) } catch { await chromeClosed(leg.id, buffer: nil, closeReason: "error") }
    } catch {
      if connectingID == connectionID {
        task.cancel()
        connectTask = nil
        connectingID = nil
        chrome = nil
      }
      throw error
    }
  }

  private func addClient(_ client: PageClient) async {
    if let activeClient {
      log("cdp client superseded")
      activeClient.close(CDPProtocol.supersededCloseCode, CDPProtocol.supersededCloseReason)
    } else {
      log("cdp client connected")
    }
    activeClient = client
    if let buffer = messageBuffer, buffer.generation.clientID != client.id {
      discard(.clientSuperseded)
    }
    if messageBuffer == nil {
      messageBuffer = ClientFrameBuffer(generation: generation(client.id))
    }
  }

  private func removeClient(_ id: UUID) {
    guard activeClient?.id == id else { return }
    activeClient = nil
    discard(.clientDisconnected)
    log("cdp client closed")
  }

  private func readPage(
    _ inbound: NIOAsyncChannelInboundStream<WebSocketFrame>, clientID: UUID,
    sink: AsyncStream<WebSocketFrame>.Continuation
  ) async {
    var buffer: ByteBuffer?
    var isText = false
    do {
      for try await frame in inbound {
        let data = frame.unmaskedData
        switch frame.opcode {
        case .ping:
          sink.yield(CDPFrames.pong(data, mask: false))
          continue
        case .pong, .connectionClose:
          if frame.opcode == .connectionClose { return }
          continue
        case .text:
          isText = true
          buffer = data
        case .binary:
          isText = false
          buffer = data
        case .continuation:
          guard var pending = buffer else { continue }
          var more = data
          pending.writeBuffer(&more)
          buffer = pending
        default:
          continue
        }
        guard frame.fin, let complete = buffer else { continue }
        buffer = nil
        guard isText,
          let text = complete.getString(at: complete.readerIndex, length: complete.readableBytes)
        else { continue }
        await receive(text, from: clientID)
      }
    } catch {
      return
    }
  }

  private func receive(_ text: String, from clientID: UUID) async {
    guard activeClient?.id == clientID else { return }
    guard text.utf8.count <= CDPProtocol.hardFrameCap else { return }
    if let chrome, chrome.isOpen, messageBuffer == nil {
      do { try chrome.send(text) } catch {
        await chromeClosed(chrome.id, buffer: text, closeReason: "error")
      }
    } else if messageBuffer != nil {
      append(text)
    }
  }

  private func deliver(_ text: String, connectionID: UUID) async {
    guard chrome?.id == connectionID else { return }
    if text.utf8.count > CDPProtocol.hardFrameCap {
      log("cdp dropped oversized browser frame (\(text.utf8.count))")
      return
    }
    guard !CDPProtocol.dropsChromeText(text) else { return }
    guard let activeClient else { return }
    activeClient.send(text)
  }

  private func chromeClosed(_ connectionID: UUID, buffer text: String?, closeReason: String) async {
    if let code = closeReason.split(separator: " ").last, closeReason.hasPrefix("close ") {
      log("cdp browser closed (\(code))")
    } else if closeReason.hasPrefix("error ") {
      log("cdp browser error: \(closeReason.dropFirst(6))")
    }
    guard chrome?.id == connectionID else { return }
    let dropped = connectionID
    chromeDropSlotHolderID = activeClient?.id
    chrome?.close()
    chrome = nil
    if messageBuffer == nil, activeClient != nil || text != nil {
      messageBuffer = ClientFrameBuffer(
        generation: ClientFrameBufferGeneration(
          chromeConnectionID: dropped, clientID: activeClient?.id))
    }
    if let text { append(text) }
    guard !stopped else {
      log("cdp browser reconnect cancelled (\(closeReason))")
      return
    }
    guard reconnectTask == nil else { return }
    let delay = Self.milliseconds(reconnectDelay)
    log("cdp browser reconnecting in \(delay)ms (\(closeReason))")
    reconnectTask = Task { await self.runReconnect() }
  }

  private func runReconnect() async {
    defer { reconnectTask = nil }
    var failures = 0
    var signaled = false
    while !stopped, !Task.isCancelled {
      do {
        try await Task.sleep(for: reconnectDelay)
        if stopped || Task.isCancelled {
          log("cdp browser reconnect cancelled")
          return
        }
        let url = try await debuggerURL(fresh: true)
        try await ensure(url)
        log("cdp browser reconnected")
        await resetStaleHolder()
        return
      } catch is CancellationError {
        log("cdp browser reconnect cancelled")
        return
      } catch {
        failures += 1
        log("cdp browser reconnect attempt \(failures) failed: \(error)")
        if !signaled, failures >= CDPProtocol.upstreamResetFailureThreshold {
          signaled = true
          log("cdp browser reconnect failed \(failures) times; resetting client")
          log("cdp client reset (reconnect-failed)")
          await closeActive(
            CDPProtocol.upstreamResetCloseCode, CDPProtocol.upstreamResetCloseReason,
            drop: .upstreamReset)
        }
      }
    }
  }

  private func resetStaleHolder() async {
    guard let holderID = chromeDropSlotHolderID else { return }
    if activeClient?.id == holderID {
      log("cdp client reset (reconnected)")
      await closeActive(
        CDPProtocol.upstreamResetCloseCode, CDPProtocol.upstreamResetCloseReason,
        drop: .upstreamReset)
      return
    }
    if activeClient != nil { log("cdp client connected during the outage") }
  }

  private static func milliseconds(_ delay: Duration) -> Int {
    let parts = delay.components
    return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
  }

  private func closeActive(_ code: UInt16, _ reason: String, drop: ClientFrameBufferDropReason)
    async
  {
    guard let activeClient else { return }
    self.activeClient = nil
    discard(drop)
    activeClient.close(code, reason)
  }

  private func generation(_ clientID: UUID?) -> ClientFrameBufferGeneration {
    let live = chrome?.isOpen ?? false
    return ClientFrameBufferGeneration(
      chromeConnectionID: live ? chrome?.id : nil, clientID: clientID)
  }

  private func append(_ text: String) {
    guard var buffer = messageBuffer else { return }
    var dropped = false
    while buffer.messages.count >= CDPProtocol.bufferLimit {
      buffer.messages.removeFirst()
      dropped = true
    }
    buffer.messages.append(text)
    messageBuffer = buffer
    if dropped { log("cdp client frame buffer full") }
  }

  private func flush(_ leg: ChromeLeg) throws {
    guard let buffer = messageBuffer else { return }
    messageBuffer = nil
    if let reason = ClientFrameBuffer.dropReason(
      generation: buffer.generation, chromeConnectionID: leg.id, clientID: activeClient?.id)
    {
      if !buffer.messages.isEmpty {
        log("cdp dropped \(buffer.messages.count) buffered frame(s): \(reason.rawValue)")
      }
      return
    }
    for text in buffer.messages {
      try leg.send(text)
    }
  }

  private func discard(_ reason: ClientFrameBufferDropReason) {
    guard let buffer = messageBuffer else { return }
    messageBuffer = nil
    if !buffer.messages.isEmpty {
      log("cdp dropped \(buffer.messages.count) buffered frame(s): \(reason.rawValue)")
    }
  }
}

struct CDPService: Service {
  let proxy: CDPProxy

  func run() async throws {
    try? await gracefulShutdown()
    await proxy.shutdown()
  }
}

private struct PageClient: Sendable {
  let id = UUID()
  let send: @Sendable (String) -> Void
  let close: @Sendable (UInt16, String) -> Void
}

private final class ChromeLeg: Sendable {
  let id: UUID
  private let alive = NIOLockedValueBox(true)
  private let outbound = NIOLockedValueBox<AsyncStream<WebSocketFrame>.Continuation?>(nil)
  private let stop = NIOLockedValueBox<(@Sendable () -> Void)?>(nil)

  init(id: UUID) { self.id = id }

  var isOpen: Bool { alive.withLockedValue { $0 } }

  func start(
    _ socket: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
    onText: @escaping @Sendable (String) async -> Void,
    onClose: @escaping @Sendable (String) async -> Void
  ) {
    let (queue, sink) = AsyncStream<WebSocketFrame>.makeStream()
    outbound.withLockedValue { $0 = sink }
    let channel = socket.channel
    stop.withLockedValue { $0 = { channel.close(promise: nil) } }
    Task {
      try? await socket.executeThenClose { inbound, outbound in
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            for await frame in queue {
              do { try await outbound.write(frame) } catch {
                try? await channel.close()
                return
              }
            }
            try? await channel.close()
          }
          var buffer: ByteBuffer?
          var isText = false
          var closeReason = "close"
          do {
            for try await frame in inbound {
              let data = frame.unmaskedData
              switch frame.opcode {
              case .ping:
                sink.yield(CDPFrames.pong(data, mask: true))
                continue
              case .pong:
                continue
              case .connectionClose:
                let code =
                  data.readableBytes >= 2
                  ? data.getInteger(at: data.readerIndex, as: UInt16.self) ?? 1005 : 1005
                closeReason = "close \(code)"
                channel.close(promise: nil)
                throw CancellationError()
              case .text:
                isText = true
                buffer = data
              case .binary:
                isText = false
                buffer = data
              case .continuation:
                guard var pending = buffer else { continue }
                var more = data
                pending.writeBuffer(&more)
                buffer = pending
              default:
                continue
              }
              guard frame.fin, let complete = buffer else { continue }
              buffer = nil
              guard isText,
                let text = complete.getString(
                  at: complete.readerIndex, length: complete.readableBytes)
              else { continue }
              await onText(text)
            }
          } catch {
            if closeReason == "close" { closeReason = "error \(error)" }
          }
          sink.finish()
          alive.withLockedValue { $0 = false }
          self.outbound.withLockedValue { $0 = nil }
          await onClose(closeReason)
        }
      }
    }
  }

  func send(_ text: String) throws {
    guard isOpen, let sink = outbound.withLockedValue({ $0 }) else {
      throw CDPError.discoveryFailed("chrome closed")
    }
    sink.yield(CDPFrames.text(text, mask: true))
  }

  func close() {
    alive.withLockedValue { $0 = false }
    outbound.withLockedValue { $0?.finish() }
    stop.withLockedValue { $0?() }
  }
}

private enum CDPChrome {
  static func connect(_ endpoint: DebuggerEndpoint, maxFrameSize: Int) async throws
    -> NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
  {
    let host =
      endpoint.host.contains(":")
      ? "[\(endpoint.host)]:\(endpoint.port)" : "\(endpoint.host):\(endpoint.port)"
    let pending = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connect(
      host: endpoint.host, port: endpoint.port
    ) { channel in
      let loop = channel.eventLoop
      do {
        let upgrader = NIOTypedWebSocketClientUpgrader<
          NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
        >(
          maxFrameSize: maxFrameSize,
          upgradePipelineHandler: { channel, _ in
            channel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                wrappingChannelSynchronously: channel)
            }
          }
        )
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: host)
        let head = HTTPRequestHead(
          version: .http1_1, method: .GET, uri: endpoint.uri, headers: headers)
        let configuration = NIOTypedHTTPClientUpgradeConfiguration(
          upgradeRequestHead: head,
          upgraders: [upgrader],
          notUpgradingCompletionHandler: { channel in
            channel.close(promise: nil)
            return channel.eventLoop.makeFailedFuture(
              CDPError.discoveryFailed("Chrome did not accept the debugger socket"))
          }
        )
        let upgrade = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
          configuration: .init(upgradeConfiguration: configuration))
        return loop.makeSucceededFuture(upgrade)
      } catch {
        return loop.makeFailedFuture(error)
      }
    }
    return try await pending.get()
  }
}

private enum CDPFrames {
  static func text(_ text: String, mask: Bool) -> WebSocketFrame {
    var data = ByteBuffer()
    data.writeString(text)
    return WebSocketFrame(fin: true, opcode: .text, maskKey: mask ? .random() : nil, data: data)
  }

  static func close(_ code: UInt16, _ reason: String, mask: Bool) -> WebSocketFrame {
    var data = ByteBuffer()
    data.writeInteger(code)
    data.writeString(reason)
    return WebSocketFrame(
      fin: true, opcode: .connectionClose, maskKey: mask ? .random() : nil, data: data)
  }

  static func pong(_ data: ByteBuffer, mask: Bool) -> WebSocketFrame {
    WebSocketFrame(fin: true, opcode: .pong, maskKey: mask ? .random() : nil, data: data)
  }
}
