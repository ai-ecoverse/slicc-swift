import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle
import Testing

@testable import SliccSwift

func cdpClient(
  _ harness: Harness, origin: String? = hostedOrigin, protocols: [String]? = nil,
  host: String? = nil, path: String = CDPProtocol.path, headers: [(String, String)] = []
) async throws -> WSClient {
  try await WSClient.connect(
    port: harness.proxyPort, path: path, host: host ?? "127.0.0.1:\(harness.proxyPort)",
    origin: origin,
    protocols: protocols ?? [CDPProtocol.cdpProtocol, KernelProtocol.keyProtocol + testKey],
    headers: headers)
}

func ping(_ client: WSClient) async throws {
  try await client.send(9, [])
  let frame = try #require(await client.receive())
  #expect(frame.opcode == 10)
}

actor ChromeHold {
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func set(_ held: Bool) {
    self.held = held
    if !held {
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.resume() }
    }
  }

  func wait() async {
    if !held { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

final class ChromeDouble: Sendable {
  let hold = ChromeHold()
  private let hits = NIOLockedValueBox(0)
  private let failAfter = NIOLockedValueBox<Int?>(nil)
  private let path = NIOLockedValueBox("devtools/browser/one")
  private let opened = NIOLockedValueBox<[String]>([])
  private let received = NIOLockedValueBox<[String: [String]]>([:])
  private let sinks = NIOLockedValueBox<[String: AsyncStream<String>.Continuation]>([:])

  func bump() -> Int {
    hits.withLockedValue { value in
      value += 1
      return value
    }
  }

  func hitCount() -> Int { hits.withLockedValue { $0 } }

  func setFailAfter(_ value: Int?) { failAfter.withLockedValue { $0 = value } }

  func rejects(_ hit: Int) -> Bool {
    failAfter.withLockedValue { limit in
      guard let limit else { return false }
      return hit > limit
    }
  }

  var currentPath: String { path.withLockedValue { $0 } }

  func setPath(_ value: String) { path.withLockedValue { $0 = value } }

  func attach(_ path: String, _ sink: AsyncStream<String>.Continuation) {
    opened.withLockedValue { $0.append(path) }
    sinks.withLockedValue { box in
      box[path]?.finish()
      box[path] = sink
    }
  }

  func append(_ path: String, _ text: String) {
    received.withLockedValue { $0[path, default: []].append(text) }
  }

  func texts(_ path: String) -> [String] { received.withLockedValue { $0[path] ?? [] } }

  func send(_ path: String, _ text: String) {
    sinks.withLockedValue { _ = $0[path]?.yield(text) }
  }

  func drop(_ path: String) {
    sinks.withLockedValue { box in
      box[path]?.finish()
      box[path] = nil
    }
  }

  func isOpen(_ path: String) -> Bool { opened.withLockedValue { $0.contains(path) } }

  func waitTexts(_ path: String, _ count: Int) async throws -> [String] {
    for _ in 0..<1000 {
      let found = texts(path)
      if found.count >= count { return found }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
  }

  func waitOpen(_ path: String) async throws {
    for _ in 0..<1000 {
      if isOpen(path) { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
  }

  func waitHits(_ count: Int) async throws {
    for _ in 0..<2000 {
      if hitCount() >= count { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
  }
}

func chromeRouter(_ chrome: ChromeDouble, _ ports: PortBox) -> Router<BasicWebSocketRequestContext>
{
  let router = Router(context: BasicWebSocketRequestContext.self)
  router.get("/json/version") { _, _ in
    await chrome.hold.wait()
    let hit = chrome.bump()
    if chrome.rejects(hit) { return Response(status: .internalServerError) }
    let port = await ports.wait()
    let url = "ws://127.0.0.1:\(port)/\(chrome.currentPath)"
    let json = "{\"Browser\":\"Chrome\",\"webSocketDebuggerUrl\":\"\(url)\"}"
    return Response(
      status: .ok, headers: [.contentType: "application/json"],
      body: .init(byteBuffer: ByteBuffer(string: json)))
  }
  for name in ["devtools/browser/one", "devtools/browser/two"] {
    router.ws("/\(name)") { inbound, outbound, _ in
      let (queue, sink) = AsyncStream<String>.makeStream()
      chrome.attach(name, sink)
      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          do {
            for try await frame in inbound {
              guard frame.opcode == .text else { continue }
              chrome.append(name, String(buffer: frame.data))
            }
          } catch {}
          sink.finish()
        }
        group.addTask {
          do {
            for await text in queue { try await outbound.write(.text(text)) }
            try await outbound.close(.goingAway, reason: nil)
          } catch {}
        }
      }
    }
  }
  return router
}

func withChrome(
  delay: Duration = .milliseconds(40),
  _ body: @Sendable (Harness, ChromeDouble) async throws -> Void
) async throws {
  let ports = PortBox()
  let chrome = ChromeDouble()
  let router = chromeRouter(chrome, ports)
  let app = Application(
    router: router,
    server: .http1WebSocketUpgrade(
      webSocketRouter: router,
      configuration: .init(
        http1: .init(
          httpDecoderConfiguration: .init(
            maxHeaderFieldSize: RawFetchProtocol.maxHeaderBytes,
            maxHeaderListSize: RawFetchProtocol.maxHeaderBytes)))),
    configuration: .init(address: .hostname("127.0.0.1", port: 0)),
    onServerRunning: { await ports.set($0.localAddress?.port ?? 0) },
    logger: quietLogger
  )
  let services = ServiceGroup(
    configuration: .init(services: [app], gracefulShutdownSignals: [], logger: quietLogger))
  let outcome = try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await services.run() }
    let port = await ports.wait()
    let result: Result<Void, any Error>
    do {
      try await withHarness(
        cdp: "http://127.0.0.1:\(port)", cdpReconnectDelay: delay
      ) { harness in
        try await body(harness, chrome)
      }
      result = .success(())
    } catch {
      result = .failure(error)
    }
    await chrome.hold.set(false)
    chrome.drop("devtools/browser/one")
    chrome.drop("devtools/browser/two")
    await services.triggerGracefulShutdown()
    try await group.waitForAll()
    return result
  }
  try outcome.get()
}

func waitLog(_ harness: Harness, _ needle: String) async throws {
  for _ in 0..<1000 {
    if harness.logs.lines.contains(where: { $0.contains(needle) }) { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw CancellationError()
}

@Suite struct CDPTests {
  @Test func debuggerURLIsReadFromTheVersionPayload() throws {
    let body = Data(
      #"{"Browser":"Chrome","webSocketDebuggerUrl":"ws:\/\/127.0.0.1:9222/devtools/browser/abc"}"#
        .utf8)
    #expect(
      try CDPProtocol.debuggerURL(body) == "ws://127.0.0.1:9222/devtools/browser/abc")
    let secure = Data(#"{"webSocketDebuggerUrl":"wss:\/\/browser.test/devtools/browser/a"}"#.utf8)
    #expect(try CDPProtocol.debuggerURL(secure) == "wss://browser.test/devtools/browser/a")
  }

  @Test func anEmptyDebuggerURLIsRejected() {
    let body = Data(#"{"Browser":"Chrome","webSocketDebuggerUrl":""}"#.utf8)
    #expect(throws: CDPError.self) { try CDPProtocol.debuggerURL(body) }
  }

  @Test func aVersionPayloadWithoutTheSocketIsRejected() {
    #expect(throws: CDPError.self) {
      try CDPProtocol.debuggerURL(Data(#"{"Browser":"Chrome"}"#.utf8))
    }
  }

  @Test func aDebuggerSocketIsAWebSocketURL() throws {
    let local = try CDPProtocol.endpoint("ws://127.0.0.1:9222/devtools/browser/abc")
    #expect(
      local
        == DebuggerEndpoint(
          host: "127.0.0.1", port: 9222, uri: "/devtools/browser/abc", tls: false))
    let v6 = try CDPProtocol.endpoint("ws://[::1]:9223/devtools/browser/x?y=1")
    #expect(
      v6 == DebuggerEndpoint(host: "::1", port: 9223, uri: "/devtools/browser/x?y=1", tls: false))
    let secure = try CDPProtocol.endpoint("wss://browser.test/devtools/browser/a")
    #expect(
      secure
        == DebuggerEndpoint(host: "browser.test", port: 443, uri: "/devtools/browser/a", tls: true))
    for url in ["http://127.0.0.1:9222/", ""] {
      #expect(throws: CDPError.self) { try CDPProtocol.endpoint(url) }
    }
    #expect(try CDPProtocol.browserEndpoint(nil) == nil)
    #expect(try CDPProtocol.browserEndpoint("  ") == nil)
    #expect(try CDPProtocol.browserEndpoint("http://127.0.0.1:9222") != nil)
    #expect(throws: CDPError.self) { try CDPProtocol.browserEndpoint("ws://127.0.0.1:9222") }
  }

  @Test func theCdpSocketTakesOnlyAnAllowedOriginWithTheKey() async throws {
    let bound = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .bind(host: "127.0.0.1", port: 0).get()
    let closed = try #require(bound.localAddress?.port)
    try await bound.close()
    try await withHarness { harness in
      let absent = try await cdpClient(harness)
      #expect(absent.reply.status == 404)
      #expect(errorBody(absent.reply) == "not found")
      #expect(absent.reply.headers["x-proxy-error"] == "1")
      #expect(absent.reply.headers["access-control-allow-origin"] == nil)
      absent.close()
      let probe = try await probeObject(harness)
      #expect(probe["cdp"] == nil)
    }
    try await withHarness(cdp: "http://127.0.0.1:\(closed)") { harness in
      let socket = CDPProtocol.cdpProtocol
      let key = KernelProtocol.keyProtocol + testKey
      let cases: [(WSClient, Int, String)] = [
        (try await cdpClient(harness, origin: "https://evil.test"), 403, "origin not allowed"),
        (try await cdpClient(harness, origin: nil), 403, "origin not allowed"),
        (
          try await cdpClient(harness, protocols: [socket, "slicc.key.wrong"]), 403,
          "proxy key missing or wrong"
        ),
        (try await cdpClient(harness, protocols: [socket]), 403, "proxy key missing or wrong"),
        (
          try await cdpClient(harness, protocols: [key]), 400,
          "subprotocol slicc.cdp.v1 missing"
        ),
        (try await cdpClient(harness, protocols: []), 400, "subprotocol slicc.cdp.v1 missing"),
        (
          try await cdpClient(
            harness, protocols: [socket], headers: [(ProxySecurity.keyHeader, testKey)]),
          403, "proxy key missing or wrong"
        ),
        (
          try await cdpClient(harness, protocols: [], path: "/cdp?key=\(testKey)"), 400,
          "subprotocol slicc.cdp.v1 missing"
        ),
        (
          try await cdpClient(
            harness, host: "8400.kernel.localhost:\(harness.proxyPort)"),
          403, "host not allowed"
        ),
        (try await cdpClient(harness, path: "/elsewhere"), 404, "not found"),
      ]
      for (client, status, error) in cases {
        #expect(client.reply.status == status, "\(error)")
        #expect(errorBody(client.reply) == error)
        #expect(client.reply.headers["x-proxy-error"] == "1")
        #expect(client.reply.headers["access-control-allow-origin"] == nil)
        client.close()
      }
      let queried = try await cdpClient(harness, path: "/cdp?key=wrong")
      #expect(queried.reply.status == 101)
      #expect(queried.reply.headers["sec-websocket-protocol"] == socket)
      #expect(queried.reply.headers["sec-websocket-protocol"]?.contains(testKey) == false)
      queried.close()
      let ok = try await cdpClient(harness)
      #expect(ok.reply.status == 101)
      #expect(ok.reply.headers["sec-websocket-protocol"] == socket)
      #expect(await ok.closeCode() == 1000)
      let plain = try await harness.post(method: .GET, path: CDPProtocol.path)
      #expect(plain.0.status == .notFound)
      let announced = try await probeObject(harness)
      #expect(announced["cdp"] as? Int == 1)
      #expect(announced["rawFetch"] as? Int == 1)
      #expect(announced["requestBodyStreaming"] as? Bool == false)
      #expect(announced["hostfs"] == nil)
      #expect(announced["kernelTunnel"] == nil)
    }
  }

  @Test func textFramesPassThroughFlattenedAndASecondClientSupersedes() async throws {
    try await withChrome { harness, chrome in
      let page = try await cdpClient(harness)
      defer { page.close() }
      #expect(page.reply.status == 101)
      let frames = NIOLockedValueBox<[(UInt8, [UInt8])]>([])
      let reader = Task {
        while let frame = await page.receive() {
          frames.withLockedValue { $0.append((frame.opcode, frame.payload)) }
        }
      }
      let attach = #"{"id":1,"method":"Target.attachToTarget","params":{"flatten":true}}"#
      try await page.send(1, Array(attach.utf8))
      let seen = try await chrome.waitTexts("devtools/browser/one", 1)
      #expect(seen == [attach])
      let session =
        #"{"method":"Target.attachedToTarget","params":{"sessionId":"abc"},"sessionId":"abc"}"#
      chrome.send("devtools/browser/one", session)
      chrome.send(
        "devtools/browser/one",
        #"{"method":"Network.webSocketFrameReceived","params":{"response":{"payloadData":"x"}}}"#)
      chrome.send(
        "devtools/browser/one", #"{"method":"Network.webSocketFrameSent","params":{}}"#)
      var forwarded: [String] = []
      for _ in 0..<400 {
        forwarded = frames.withLockedValue {
          $0.compactMap { opcode, payload in
            opcode == 1 ? String(decoding: payload, as: UTF8.self) : nil
          }
        }
        if forwarded.contains(session) { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      try await Task.sleep(for: .milliseconds(40))
      forwarded = frames.withLockedValue {
        $0.compactMap { opcode, payload in
          opcode == 1 ? String(decoding: payload, as: UTF8.self) : nil
        }
      }
      #expect(forwarded == [session])
      let next = try await cdpClient(harness)
      defer { next.close() }
      var closed: Int?
      var reason = ""
      for _ in 0..<400 {
        let found = frames.withLockedValue { $0.first { $0.0 == 8 && $0.1.count >= 2 } }
        if let found {
          closed = Int(found.1[0]) << 8 | Int(found.1[1])
          reason = String(decoding: found.1.dropFirst(2), as: UTF8.self)
          break
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(closed == Int(CDPProtocol.supersededCloseCode))
      #expect(reason == CDPProtocol.supersededCloseReason)
      let again = #"{"id":2,"method":"Target.createTarget","params":{}}"#
      try await next.send(1, Array(again.utf8))
      let both = try await chrome.waitTexts("devtools/browser/one", 2)
      #expect(both.last == again)
      next.close()
      page.close()
      _ = await reader.value
    }
  }

  @Test func theClientThatHeldTheSlotIsResetAfterReconnect() async throws {
    try await withChrome(delay: .milliseconds(200)) { harness, chrome in
      let page = try await cdpClient(harness)
      defer { page.close() }
      try await page.send(1, Array(#"{"id":1}"#.utf8))
      _ = try await chrome.waitTexts("devtools/browser/one", 1)
      chrome.setPath("devtools/browser/two")
      chrome.drop("devtools/browser/one")
      try await ping(page)
      try await chrome.waitOpen("devtools/browser/two")
      #expect(await page.closeCode() == Int(CDPProtocol.upstreamResetCloseCode))
      #expect(chrome.texts("devtools/browser/two").isEmpty)
    }
  }

  @Test func aClientThatJoinsDuringTheOutageIsKept() async throws {
    try await withChrome(delay: .milliseconds(30)) { harness, chrome in
      let first = try await cdpClient(harness)
      defer { first.close() }
      try await first.send(1, Array(#"{"id":1}"#.utf8))
      _ = try await chrome.waitTexts("devtools/browser/one", 1)
      await chrome.hold.set(true)
      chrome.drop("devtools/browser/one")
      try await waitLog(harness, "reconnecting")
      let next = try await cdpClient(harness)
      defer { next.close() }
      #expect(await first.closeCode() == Int(CDPProtocol.supersededCloseCode))
      let created = #"{"id":2,"method":"Target.createTarget","params":{}}"#
      try await next.send(1, Array(created.utf8))
      chrome.setPath("devtools/browser/two")
      await chrome.hold.set(false)
      let flushed = try await chrome.waitTexts("devtools/browser/two", 1)
      #expect(flushed == [created])
      try await ping(next)
      next.close()
    }
  }

  @Test func threeFailedRediscoveriesResetTheClientAndTheLoopContinues() async throws {
    try await withChrome(delay: .milliseconds(150)) { harness, chrome in
      chrome.setFailAfter(1)
      let page = try await cdpClient(harness)
      defer { page.close() }
      try await chrome.waitOpen("devtools/browser/one")
      chrome.drop("devtools/browser/one")
      try await chrome.waitHits(2)
      try await ping(page)
      #expect(await page.closeCode() == Int(CDPProtocol.upstreamResetCloseCode))
      try await chrome.waitHits(5)
    }
  }

  @Test func theFirstDiscoveryFailureDoesNotReconnect() async throws {
    try await withChrome(delay: .milliseconds(40)) { harness, chrome in
      chrome.setFailAfter(0)
      let page = try await cdpClient(harness)
      defer { page.close() }
      #expect(await page.closeCode() == 1000)
      try await Task.sleep(for: .milliseconds(300))
      #expect(chrome.hitCount() == 1)
    }
  }
}
