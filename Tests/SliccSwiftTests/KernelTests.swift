import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import SliccSwift

func withKernel(
  openTimeout: Duration = KernelProtocol.openTimeout,
  _ body: @Sendable (Harness, Int) async throws -> Void
) async throws {
  try await withHarness(kernelPort: 0, kernelOpenTimeout: openTimeout) { harness in
    try await body(harness, try #require(harness.kernelPort))
  }
}

func probeObject(_ harness: Harness) async throws -> [String: Any] {
  let (_, bytes) = try await harness.post(headers: [(RawFetchProtocol.probeHeader, "1")])
  return try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
}

func errorBody(_ reply: HTTPReply) -> String? {
  (try? JSONSerialization.jsonObject(with: Data(reply.body)) as? [String: String])?["error"]
}

@Suite struct KernelTests {
  @Test func probeAnnouncesTheTunnelAndItsPort() async throws {
    try await withKernel { harness, port in
      let probe = try await probeObject(harness)
      #expect(probe["kernelTunnel"] as? Int == 1)
      #expect(probe["kernelPort"] as? Int == port)
    }
  }

  @Test func probeOmitsTheTunnelWhenTheListenerIsOff() async throws {
    try await withHarness { harness in
      #expect(harness.kernelPort == nil)
      let probe = try await probeObject(harness)
      #expect(probe["kernelTunnel"] == nil)
      let refused = try await WSClient.tunnel(harness)
      #expect(refused.reply.status == 404)
      refused.close()
    }
  }

  @Test func aTakenPortTurnsTheListenerOffWithAWarning() async throws {
    let blocker = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .bind(host: "127.0.0.1", port: 0).get()
    let taken = try #require(blocker.localAddress?.port)
    try await withHarness(kernelPort: taken) { harness in
      #expect(harness.kernelPort == nil)
      #expect(
        harness.warnings.lines == [
          "kernel services are off: cannot listen on 127.0.0.1:\(taken) (EADDRINUSE); try --kernel-port"
        ])
      let probe = try await probeObject(harness)
      #expect(probe["kernelTunnel"] == nil)
    }
    try await blocker.close()
  }

  @Test func theListenerServesOnlyKernelHosts() async throws {
    try await withKernel { _, port in
      for host in [
        "127.0.0.1:\(port)", "localhost", "kernel.localhost", "0.kernel.localhost",
        "08400.kernel.localhost", "65536.kernel.localhost", "8400.kernel.localhost.",
        "8400.kernel.localhost.evil.test", "evil.test", "8400.kernel.localhost:\(port + 1)",
        "8400.kernel.localhost:0\(port)",
      ] {
        let reply = try await kernelGet(port, host: host)
        #expect(reply.status == 421, "\(host)")
        #expect(reply.headers["x-proxy-error"] == "1")
        #expect(reply.text == "only <port>.kernel.localhost is served here\n")
      }
      #expect(try await rawExchange(port, "GARBAGE\r\n\r\n").hasPrefix("HTTP/1.1 400 "))
      #expect(
        try await rawExchange(
          port, "GET / HTTP/1.1\r\nHost: 1.kernel.localhost\r\nHost: 2.kernel.localhost\r\n\r\n"
        ).hasPrefix("HTTP/1.1 400 "))
      let big = "GET / HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 70 * 1024)
      #expect(try await rawExchange(port, big).hasPrefix("HTTP/1.1 431 "))
    }
  }

  @Test func withoutAPageTheListenerAnswers502() async throws {
    try await withKernel { _, port in
      let reply = try await kernelGet(port)
      #expect(reply.status == 502)
      #expect(reply.text == "no seven page connected\n")
      #expect(reply.headers["connection"] == "close")
      #expect(reply.headers["cache-control"] == "no-store")
    }
  }

  @Test func theTunnelTakesOnlyAnAllowedOriginWithTheKey() async throws {
    try await withKernel { harness, port in
      let tunnel = KernelProtocol.tunnelProtocol
      let key = KernelProtocol.keyProtocol + testKey
      let cases: [(WSClient, Int, String)] = [
        (
          try await WSClient.tunnel(harness, origin: "https://evil.test"), 403, "origin not allowed"
        ),
        (try await WSClient.tunnel(harness, origin: nil), 403, "origin not allowed"),
        (
          try await WSClient.tunnel(harness, protocols: [tunnel, "slicc.key.wrong"]), 403,
          "proxy key missing or wrong"
        ),
        (
          try await WSClient.tunnel(harness, protocols: [tunnel]), 403, "proxy key missing or wrong"
        ),
        (
          try await WSClient.tunnel(harness, protocols: [key]), 400,
          "subprotocol slicc.kernel-tunnel.v1 missing"
        ),
        (
          try await WSClient.tunnel(harness, host: "8400.kernel.localhost:\(harness.proxyPort)"),
          403,
          "host not allowed"
        ),
        (try await WSClient.tunnel(harness, path: "/elsewhere"), 404, "not found"),
      ]
      for (client, status, error) in cases {
        #expect(client.reply.status == status, "\(error)")
        #expect(errorBody(client.reply) == error)
        #expect(client.reply.headers["x-proxy-error"] == "1")
        #expect(client.reply.headers["access-control-allow-origin"] == nil)
        client.close()
      }
      let ok = try await WSClient.tunnel(harness)
      #expect(ok.reply.status == 101)
      #expect(ok.reply.headers["sec-websocket-protocol"] == tunnel)
      ok.close()
      let plain = try await harness.post(method: .GET, path: KernelProtocol.tunnelPath)
      #expect(plain.0.status == .notFound)
      _ = port
    }
  }

  @Test func requestsReachTheKernelPortWithKeepAliveAndBodies() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [8400: .upstream(harness.upstreamPort)])
      let (socket, inbox) = try await TestSocket.open(port)
      try await socket.write(kernelRequest(port, path: "/kernel/a?b=1"))
      let first = try await readReply(inbox)
      #expect(first.status == 200)
      let object = try JSONSerialization.jsonObject(with: Data(first.body)) as? [String: Any]
      #expect(object?["url"] as? String == "/kernel/a?b=1")
      #expect(object?["host"] as? String == "8400.kernel.localhost")
      #expect(object?["size"] as? Int == 0)
      let upload = [UInt8](repeating: 1, count: 1024 * 1024)
      try await socket.write(
        kernelRequest(port, path: "/kernel/upload", method: "POST", body: upload))
      let second = try await readReply(inbox)
      let sized = try JSONSerialization.jsonObject(with: Data(second.body)) as? [String: Any]
      #expect(sized?["size"] as? Int == upload.count)
      try await socket.write(kernelRequest(port, path: "/big"))
      let download = try await readReply(inbox)
      #expect(download.body == bigBody)
      #expect(await page.seen.opens == [8400])
      socket.close()
      await page.close()
      #expect(harness.logs.lines.contains("kernel GET 8400"))
    }
  }

  @Test func webSocketUpgradesPassThroughAsRawBytes() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [5173: .upstream(harness.upstreamPort)])
      let ws = try await WSClient.connect(port: port, path: "/hmr", host: "5173.kernel.localhost")
      #expect(ws.reply.status == 101)
      try await ws.send(1, Array("hello".utf8))
      let reply = try #require(await ws.receive())
      #expect(reply.opcode == 1)
      #expect(String(decoding: reply.payload, as: UTF8.self) == "echo hello")
      ws.close()
      await page.close()
    }
  }

  @Test func nothingListeningAndOtherDialFailuresAnswer502() async throws {
    try await withKernel { harness, port in
      let older = try await TestPage.connect(
        harness, ports: [9000: .hang], reason: "EHOSTDOWN\r\nX: y")
      let newer = try await TestPage.connect(harness)
      let refused = try await kernelGet(port, host: "8401.kernel.localhost")
      #expect(refused.status == 502)
      #expect(refused.text == "nothing listening on kernel port 8401\n")
      await newer.close()
      let other = try await kernelGet(port, host: "8402.kernel.localhost")
      #expect(other.status == 502)
      #expect(other.text == "kernel port 8402: EHOSTDOWNX: y\n")
      await older.close()
    }
  }

  @Test func theNewestPageWinsAndAnOlderOneTakesOver() async throws {
    try await withKernel { harness, port in
      let ports: [Int: PagePort] = [8400: .upstream(harness.upstreamPort)]
      let older = try await TestPage.connect(harness, ports: ports)
      let newer = try await TestPage.connect(harness, ports: ports)
      #expect(try await kernelGet(port).status == 200)
      #expect(await newer.seen.opens == [8400])
      #expect(await older.seen.opens == [])
      await newer.close()
      #expect(try await kernelGet(port).status == 200)
      #expect(await older.seen.opens == [8400])
      await older.close()
      #expect(harness.logs.lines.contains { $0.hasPrefix("kernel tunnel from \(hostedOrigin)") })
    }
  }

  @Test func theListenerNeverSendsMoreThanTheWindowBeforeThePageCredits() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(
        harness, ports: [8400: .upstream(harness.upstreamPort)], credit: false)
      let (socket, _) = try await TestSocket.open(port)
      let upload = kernelRequest(port, path: "/kernel/upload", method: "POST", body: bigBody)
      socket.channel.writeAndFlush(ByteBuffer(bytes: upload), promise: nil)
      try await Task.sleep(for: .milliseconds(300))
      let sent = await page.seen.received.values.first ?? 0
      #expect(sent > 0 && sent <= KernelProtocol.window, "\(sent)")
      socket.close()
      await page.close()
    }
  }

  @Test func aSlowBrowserHoldsThePageBackThenGetsEveryByte() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [8400: .upstream(harness.upstreamPort)])
      let socket = try await TestSocket.connect(port)
      try await socket.pause()
      try await socket.write(
        "GET /big HTTP/1.1\r\nHost: 8400.kernel.localhost\r\nConnection: close\r\n\r\n")
      try await Task.sleep(for: .milliseconds(300))
      let id = try #require(await page.seen.ids.first)
      let sent = await page.seen.sent[id] ?? 0
      let credited = await page.seen.credited[id] ?? 0
      #expect(sent < bigBody.count, "\(sent)")
      #expect(sent - credited <= KernelProtocol.window)
      let inbox = Inbox()
      Task { await inbox.feed(socket.events) }
      try await socket.resume()
      let reply = try await readReply(inbox)
      #expect(reply.body == bigBody)
      socket.close()
      await page.close()
    }
  }

  @Test func aPageThatOverrunsTheWindowLosesTheStream() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(
        harness, ports: [8400: .upstream(harness.upstreamPort)], greedy: true)
      let socket = try await TestSocket.connect(port)
      try await socket.pause()
      try await socket.write(
        "GET /big HTTP/1.1\r\nHost: 8400.kernel.localhost\r\nConnection: close\r\n\r\n")
      let id = try await page.seen.waitFor { $0.ids.first }
      let reason = try await page.seen.waitFor { $0.resets[id] }
      #expect(reason == "EPROTO")
      socket.close()
      await page.close()
    }
  }

  @Test func framesOutOfOrderResetOnlyTheirStream() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [8400: .hang])
      let cases: [(UInt8, [UInt8], String)] = [
        (3, Array("x".utf8), "EPROTO"), (4, [], "EPROTO"), (6, [0, 0, 0, 1], "EPROTO"),
        (5, [], "reset"),
      ]
      for (index, (type, payload, reason)) in cases.enumerated() {
        async let pending = kernelGet(port)
        let id = try await page.seen.waitFor { $0.ids.count > index ? $0.ids[index] : nil }
        try await page.send(type, id, payload)
        let reply = try await pending
        #expect(reply.status == 502)
        #expect(reply.text == "kernel port 8400: \(reason)\n")
      }
      try await page.send(3, 999_999, Array("x".utf8))
      try await Task.sleep(for: .milliseconds(50))
      #expect(await !page.ws.inbox.isEnded)
      await page.close()
    }
  }

  @Test func dataAfterThePageEndedOrEmptyDataResetsTheStream() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [5173: .upstream(harness.upstreamPort)])
      let sequences: [[(UInt8, [UInt8])]] = [
        [(3, [])], [(4, []), (4, [])], [(4, []), (3, Array("x".utf8))],
      ]
      for (index, frames) in sequences.enumerated() {
        let ws = try await WSClient.connect(port: port, path: "/hmr", host: "5173.kernel.localhost")
        #expect(ws.reply.status == 101)
        let id = try await page.seen.waitFor { $0.ids.count > index ? $0.ids[index] : nil }
        for (type, payload) in frames { try await page.send(type, id, payload) }
        let reason = try await page.seen.waitFor { $0.resets[id] }
        #expect(reason == "EPROTO")
        _ = await ws.inbox.rest()
        ws.close()
      }
      await page.close()
    }
  }

  @Test func aPageResetTearsDownALiveConnection() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [5173: .upstream(harness.upstreamPort)])
      let ws = try await WSClient.connect(port: port, path: "/hmr", host: "5173.kernel.localhost")
      #expect(ws.reply.status == 101)
      let id = try #require(await page.seen.ids.first)
      try await page.send(5, id, Array("gone".utf8))
      _ = await ws.inbox.rest()
      #expect(await ws.inbox.isEnded)
      await page.close()
    }
  }

  @Test func anUnansweredOpenTimesOutWith504() async throws {
    try await withKernel(openTimeout: .milliseconds(200)) { harness, port in
      let page = try await TestPage.connect(harness, ports: [8400: .hang])
      let reply = try await kernelGet(port)
      #expect(reply.status == 504)
      #expect(reply.text == "kernel port 8400 did not answer\n")
      let id = try #require(await page.seen.ids.first)
      #expect(try await page.seen.waitFor { $0.resets[id] } == "ETIMEDOUT")
      await page.close()
    }
  }

  @Test func aPageThatBreaksTheProtocolLosesItsTunnelAndStreams() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [8400: .hang])
      async let pending = kernelGet(port)
      _ = try await page.seen.waitFor { $0.ids.first }
      try await page.ws.send(1, Array("text".utf8))
      #expect(try await page.seen.waitFor { $0.closeCode } == 1003)
      #expect(try await pending.status == 502)
      let bad = try await WSClient.tunnel(harness)
      try await bad.sendTunnel(6, 1, [0, 0, 0, 0])
      #expect(await bad.closeCode() == 1002)
    }
  }

  @Test func malformedTunnelFramesCloseTheTunnel() async throws {
    try await withKernel { harness, _ in
      for frame: [UInt8] in [[3, 0, 0], [9, 0, 0, 0, 1], [1, 0, 0, 0, 1, 0, 80]] {
        let ws = try await WSClient.tunnel(harness)
        try await ws.send(2, frame)
        #expect(await ws.closeCode() == 1002)
      }
      let ws = try await WSClient.tunnel(harness)
      try await ws.send(2, [UInt8](repeating: 0, count: KernelProtocol.maxMessage + 1))
      #expect(await ws.closeCode() == 1009)
      let split = try await WSClient.tunnel(harness)
      try await split.send(2, [UInt8](repeating: 0, count: 40_000), fin: false)
      try await split.send(0, [UInt8](repeating: 0, count: 40_000))
      #expect(await split.closeCode() == 1009)
    }
  }

  @Test func aBrowserThatDropsALiveConnectionResetsTheStream() async throws {
    try await withKernel { harness, port in
      let page = try await TestPage.connect(harness, ports: [8400: .upstream(harness.upstreamPort)])
      let socket = try await TestSocket.connect(port)
      try await socket.pause()
      try await socket.write("GET /big HTTP/1.1\r\nHost: 8400.kernel.localhost\r\n\r\n")
      let id = try await page.seen.waitFor { $0.sent.keys.first }
      socket.reset()
      #expect(try await page.seen.waitFor { $0.resets[id] } == "closed")
      await page.close()
    }
  }

  @Test func theTunnelLogsConnectsAndCloses() async throws {
    try await withKernel { harness, _ in
      let page = try await TestPage.connect(harness)
      await page.close()
      try await Task.sleep(for: .milliseconds(100))
      #expect(harness.logs.lines.contains("kernel tunnel from \(hostedOrigin) (1 open)"))
      #expect(harness.logs.lines.contains("kernel tunnel from \(hostedOrigin) closed (0 open)"))
    }
  }
}
