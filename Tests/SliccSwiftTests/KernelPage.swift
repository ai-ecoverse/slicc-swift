import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import SliccSwift

enum SocketEvent: Sendable {
  case data([UInt8])
  case eof
  case closed
}

final class SocketPump: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer

  let sink: AsyncStream<SocketEvent>.Continuation

  init(sink: AsyncStream<SocketEvent>.Continuation) { self.sink = sink }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    sink.yield(.data(Array(unwrapInboundIn(data).readableBytesView)))
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case ChannelEvent.inputClosed = event { sink.yield(.eof) }
  }

  func channelInactive(context: ChannelHandlerContext) {
    sink.yield(.closed)
    sink.finish()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    context.close(promise: nil)
  }
}

actor Inbox {
  private var bytes: [UInt8] = []
  private var ended = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func feed(_ events: AsyncStream<SocketEvent>) async {
    for await event in events {
      switch event {
      case .data(let chunk): bytes += chunk
      case .eof, .closed: ended = true
      }
      wake()
    }
    ended = true
    wake()
  }

  private func wake() {
    let list = waiters
    waiters = []
    for waiter in list { waiter.resume() }
  }

  private func wait() async {
    await withCheckedContinuation { waiters.append($0) }
  }

  func take(_ count: Int) async -> [UInt8]? {
    while bytes.count < count {
      if ended { return nil }
      await wait()
    }
    defer { bytes.removeFirst(count) }
    return Array(bytes[..<count])
  }

  func until(_ separator: [UInt8]) async -> [UInt8]? {
    var from = 0
    while true {
      if bytes.count >= separator.count {
        for index in from...(bytes.count - separator.count)
        where Array(bytes[index..<(index + separator.count)]) == separator {
          defer { bytes.removeFirst(index + separator.count) }
          return Array(bytes[..<(index + separator.count)])
        }
        from = bytes.count - separator.count + 1
      }
      if ended { return nil }
      await wait()
    }
  }

  func rest() async -> [UInt8] {
    while !ended { await wait() }
    defer { bytes = [] }
    return bytes
  }

  var isEnded: Bool { ended }
}

final class TestSocket: Sendable {
  let channel: any Channel
  let events: AsyncStream<SocketEvent>

  private init(channel: any Channel, events: AsyncStream<SocketEvent>) {
    self.channel = channel
    self.events = events
  }

  static func connect(_ port: Int) async throws -> TestSocket {
    let (events, sink) = AsyncStream<SocketEvent>.makeStream()
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .channelOption(.allowRemoteHalfClosure, value: true)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(SocketPump(sink: sink))
        }
      }
      .connect(host: "127.0.0.1", port: port)
      .get()
    return TestSocket(channel: channel, events: events)
  }

  static func open(_ port: Int) async throws -> (TestSocket, Inbox) {
    let socket = try await connect(port)
    let inbox = Inbox()
    Task { await inbox.feed(socket.events) }
    return (socket, inbox)
  }

  func write(_ bytes: [UInt8]) async throws {
    try await channel.writeAndFlush(ByteBuffer(bytes: bytes)).get()
  }

  func write(_ text: String) async throws { try await write(Array(text.utf8)) }

  func shutdownOutput() { channel.close(mode: .output, promise: nil) }

  deinit { close() }

  func close() { channel.close(promise: nil) }

  func reset() {
    guard let provider = channel as? any SocketOptionProvider else { return close() }
    provider.setSoLinger(linger(l_onoff: 1, l_linger: 0)).whenComplete { _ in self.close() }
  }

  func pause() async throws { try await channel.setOption(.autoRead, value: false).get() }

  func resume() async throws { try await channel.setOption(.autoRead, value: true).get() }
}

struct HTTPReply {
  let status: Int
  let headers: [String: String]
  let body: [UInt8]

  var text: String { String(decoding: body, as: UTF8.self) }
}

func readReply(_ inbox: Inbox) async throws -> HTTPReply {
  let head = try #require(await inbox.until(Array("\r\n\r\n".utf8)))
  let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
  let status = Int(lines[0].split(separator: " ")[1]) ?? 0
  var headers: [String: String] = [:]
  for line in lines.dropFirst() where line.contains(":") {
    let parts = line.split(separator: ":", maxSplits: 1)
    headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
  }
  var body: [UInt8] = []
  if let length = headers["content-length"].flatMap(Int.init) {
    body = try #require(await inbox.take(length))
  } else if headers["transfer-encoding"] == "chunked" {
    while true {
      let line = try #require(await inbox.until(Array("\r\n".utf8)))
      let size = Int(String(decoding: line.dropLast(2), as: UTF8.self), radix: 16) ?? 0
      if size == 0 {
        _ = await inbox.until(Array("\r\n".utf8))
        break
      }
      body += try #require(await inbox.take(size))
      _ = await inbox.take(2)
    }
  } else if status >= 200 && status != 204 && status != 304 {
    body = await inbox.rest()
  }
  return HTTPReply(status: status, headers: headers, body: body)
}

func kernelRequest(
  _ port: Int, path: String = "/kernel/x", host: String = "8400.kernel.localhost",
  method: String = "GET", body: [UInt8] = []
) -> [UInt8] {
  var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host)\r\n"
  if !body.isEmpty || method == "POST" { head += "Content-Length: \(body.count)\r\n" }
  return Array((head + "\r\n").utf8) + body
}

func kernelGet(
  _ port: Int, path: String = "/kernel/x", host: String = "8400.kernel.localhost",
  method: String = "GET", body: [UInt8] = []
) async throws -> HTTPReply {
  let (socket, inbox) = try await TestSocket.open(port)
  defer { socket.close() }
  try await socket.write(kernelRequest(port, path: path, host: host, method: method, body: body))
  return try await readReply(inbox)
}

func rawExchange(_ port: Int, _ bytes: String) async throws -> String {
  let (socket, inbox) = try await TestSocket.open(port)
  defer { socket.close() }
  try await socket.write(bytes)
  return String(decoding: await inbox.rest(), as: UTF8.self)
}

struct WSFrame {
  let opcode: UInt8
  let payload: [UInt8]

  var closeCode: Int? {
    payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : nil
  }
}

final class WSClient: Sendable {
  let socket: TestSocket
  let inbox: Inbox
  let reply: HTTPReply

  private init(socket: TestSocket, inbox: Inbox, reply: HTTPReply) {
    self.socket = socket
    self.inbox = inbox
    self.reply = reply
  }

  static func connect(
    port: Int, path: String, host: String, origin: String? = nil, protocols: [String] = [],
    headers: [(String, String)] = []
  ) async throws -> WSClient {
    let (socket, inbox) = try await TestSocket.open(port)
    var head =
      "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    head += "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
    if let origin { head += "Origin: \(origin)\r\n" }
    if !protocols.isEmpty {
      head += "Sec-WebSocket-Protocol: \(protocols.joined(separator: ", "))\r\n"
    }
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    try await socket.write(head + "\r\n")
    let headBytes = try #require(await inbox.until(Array("\r\n\r\n".utf8)))
    let lines = String(decoding: headBytes, as: UTF8.self).components(separatedBy: "\r\n")
    let status = Int(lines[0].split(separator: " ")[1]) ?? 0
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where line.contains(":") {
      let parts = line.split(separator: ":", maxSplits: 1)
      headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    var body: [UInt8] = []
    if status != 101, let length = headers["content-length"].flatMap(Int.init) {
      body = await inbox.take(length) ?? []
    }
    return WSClient(
      socket: socket, inbox: inbox, reply: HTTPReply(status: status, headers: headers, body: body))
  }

  static func tunnel(
    _ harness: Harness, origin: String? = hostedOrigin,
    protocols: [String] = [KernelProtocol.tunnelProtocol, KernelProtocol.keyProtocol + testKey],
    host: String? = nil, path: String = KernelProtocol.tunnelPath
  ) async throws -> WSClient {
    try await connect(
      port: harness.proxyPort, path: path, host: host ?? "127.0.0.1:\(harness.proxyPort)",
      origin: origin, protocols: protocols)
  }

  func send(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true) async throws {
    var frame: [UInt8] = [(fin ? 0x80 : 0) | opcode]
    let mask: [UInt8] = [1, 2, 3, 4]
    if payload.count < 126 {
      frame.append(0x80 | UInt8(payload.count))
    } else if payload.count < 65536 {
      frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
    } else {
      frame.append(0x80 | 127)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((payload.count >> shift) & 0xff))
      }
    }
    frame += mask
    frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
    try await socket.write(frame)
  }

  func sendTunnel(_ type: UInt8, _ id: UInt32, _ payload: [UInt8] = []) async throws {
    let header: [UInt8] = [
      type, UInt8(id >> 24), UInt8((id >> 16) & 0xff), UInt8((id >> 8) & 0xff), UInt8(id & 0xff),
    ]
    try await send(2, header + payload)
  }

  func receive() async -> WSFrame? {
    guard let first = await inbox.take(2) else { return nil }
    var length = Int(first[1] & 0x7f)
    if length == 126 {
      guard let more = await inbox.take(2) else { return nil }
      length = Int(more[0]) << 8 | Int(more[1])
    } else if length == 127 {
      guard let more = await inbox.take(8) else { return nil }
      length = more.reduce(0) { $0 << 8 | Int($1) }
    }
    guard let payload = await inbox.take(length) else { return nil }
    return WSFrame(opcode: first[0] & 0x0f, payload: payload)
  }

  func closeCode() async -> Int? {
    while let frame = await receive() {
      if frame.opcode == 8 { return frame.closeCode }
    }
    return nil
  }

  func close() { socket.close() }
}

actor PageSeen {
  var opens: [Int] = []
  var ids: [UInt32] = []
  var received: [UInt32: Int] = [:]
  var sent: [UInt32: Int] = [:]
  var credited: [UInt32: Int] = [:]
  var resets: [UInt32: String] = [:]
  var closeCode: Int?

  func open(_ id: UInt32, _ port: Int) {
    opens.append(port)
    ids.append(id)
  }

  enum Counter { case received, sent, credited }

  func add(_ counter: Counter, _ id: UInt32, _ count: Int) {
    switch counter {
    case .received: received[id, default: 0] += count
    case .sent: sent[id, default: 0] += count
    case .credited: credited[id, default: 0] += count
    }
  }

  func reset(_ id: UInt32, _ reason: String) { resets[id] = reason }

  func closed(_ code: Int?) { closeCode = code }

  func waitFor<T: Sendable>(_ probe: @Sendable (isolated PageSeen) -> T?) async throws -> T {
    for _ in 0..<1000 {
      if let value = probe(self) { return value }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw CancellationError()
  }
}

enum PagePort: Sendable {
  case upstream(Int)
  case hang
}

final class TestPage: Sendable {
  let ws: WSClient
  let seen = PageSeen()
  private let streams = NIOLockedValueBox<[UInt32: PageStream]>([:])

  struct Flow {
    var window = KernelProtocol.window
    var pending: [UInt8] = []
    var ended = false
    var endSent = false
  }

  final class PageStream: Sendable {
    let socket: TestSocket
    let state = NIOLockedValueBox(Flow())

    init(socket: TestSocket) { self.socket = socket }
  }

  private init(ws: WSClient) { self.ws = ws }

  static func connect(
    _ harness: Harness, ports: [Int: PagePort] = [:], reason: String = "ECONNREFUSED",
    credit: Bool = true, greedy: Bool = false
  ) async throws -> TestPage {
    let ws = try await WSClient.tunnel(harness)
    #expect(ws.reply.status == 101)
    let page = TestPage(ws: ws)
    Task { await page.loop(ports: ports, reason: reason, credit: credit, greedy: greedy) }
    return page
  }

  func send(_ type: UInt8, _ id: UInt32, _ payload: [UInt8] = []) async throws {
    try await ws.sendTunnel(type, id, payload)
  }

  private func loop(ports: [Int: PagePort], reason: String, credit: Bool, greedy: Bool) async {
    while let frame = await ws.receive() {
      if frame.opcode == 9 {
        try? await ws.send(10, frame.payload)
        continue
      }
      guard frame.opcode == 2, frame.payload.count >= 5 else {
        if frame.opcode == 8 {
          await seen.closed(frame.closeCode)
          break
        }
        continue
      }
      let type = frame.payload[0]
      let id = frame.payload[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      let payload = Array(frame.payload[5...])
      if type == 1 {
        let port = Int(payload[0]) << 8 | Int(payload[1])
        await seen.open(id, port)
        await open(id, ports[port], reason: reason, greedy: greedy)
        continue
      }
      if type == 5 { await seen.reset(id, String(decoding: payload, as: UTF8.self)) }
      guard let stream = streams.withLockedValue({ $0[id] }) else { continue }
      switch type {
      case 3:
        await seen.add(.received, id, payload.count)
        try? await stream.socket.write(payload)
        if credit {
          let count = payload.count
          try? await send(
            6, id,
            [
              UInt8(count >> 24), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff),
              UInt8(count & 0xff),
            ])
        }
      case 6:
        let bytes = payload.reduce(0) { $0 << 8 | Int($1) }
        await seen.add(.credited, id, bytes)
        stream.state.withLockedValue { $0.window += bytes }
        await flush(id, stream, greedy: greedy)
      case 4:
        stream.socket.shutdownOutput()
      case 5:
        stream.socket.close()
      default:
        break
      }
    }
    for stream in streams.withLockedValue({ Array($0.values) }) { stream.socket.close() }
  }

  private func open(_ id: UInt32, _ port: PagePort?, reason: String, greedy: Bool) async {
    guard let port else {
      try? await send(5, id, Array(reason.utf8))
      return
    }
    guard case .upstream(let upstream) = port else { return }
    guard let socket = try? await TestSocket.connect(upstream) else {
      try? await send(5, id, Array("ECONNREFUSED".utf8))
      return
    }
    let stream = PageStream(socket: socket)
    streams.withLockedValue { $0[id] = stream }
    try? await send(2, id)
    Task {
      for await event in socket.events {
        switch event {
        case .data(let chunk):
          stream.state.withLockedValue { $0.pending += chunk }
          await flush(id, stream, greedy: greedy)
        case .eof, .closed:
          stream.state.withLockedValue { $0.ended = true }
          await flush(id, stream, greedy: greedy)
        }
      }
    }
  }

  private func flush(_ id: UInt32, _ stream: PageStream, greedy: Bool) async {
    while true {
      let (piece, end): ([UInt8], Bool) = stream.state.withLockedValue { state in
        let size = min(state.pending.count, KernelProtocol.chunk, greedy ? Int.max : state.window)
        if size > 0 {
          let piece = Array(state.pending[..<size])
          state.pending.removeFirst(size)
          state.window -= size
          return (piece, false)
        }
        if state.pending.isEmpty && state.ended && !state.endSent {
          state.endSent = true
          return ([], true)
        }
        return ([], false)
      }
      if end {
        try? await send(4, id)
        return
      }
      guard !piece.isEmpty else {
        let blocked = stream.state.withLockedValue { !$0.pending.isEmpty }
        if blocked { try? await stream.socket.pause() } else { try? await stream.socket.resume() }
        return
      }
      await seen.add(.sent, id, piece.count)
      try? await send(3, id, piece)
    }
  }

  func close() async {
    ws.close()
    try? await Task.sleep(for: .milliseconds(50))
  }
}
