import NIOConcurrencyHelpers
import NIOCore

final class KernelState: Sendable {
  private let box = NIOLockedValueBox<Int?>(nil)
  private let waiters = NIOLockedValueBox<(done: Bool, list: [CheckedContinuation<Int?, Never>])>(
    (false, []))

  var port: Int? { box.withLockedValue { $0 } }

  func settle(_ port: Int?) {
    box.withLockedValue { $0 = port }
    let list = waiters.withLockedValue { state in
      state.done = true
      defer { state.list = [] }
      return state.list
    }
    for waiter in list { waiter.resume(returning: port) }
  }

  func settled() async -> Int? {
    await withCheckedContinuation { continuation in
      let done = waiters.withLockedValue { state in
        if !state.done { state.list.append(continuation) }
        return state.done
      }
      if done { continuation.resume(returning: port) }
    }
  }
}

struct TunnelGate: Sendable {
  let key: String
  let extraOrigins: Set<String>
  let port: BoundPort
  let kernel: KernelState
  let cdp: Bool
}

struct KernelStreamError: Error {
  let code: String
}

enum KernelEvent: Sendable {
  case data(ByteBuffer)
  case end
}

enum KernelDial: Sendable {
  case noPage
  case failed(String)
  case opened(UInt32, AsyncStream<KernelEvent>)
}

actor KernelTunnels {
  private struct Tunnel {
    let id: Int
    let origin: String
    let send: @Sendable (ByteBuffer) -> Void
    let close: @Sendable () -> Void
  }

  private final class Stream {
    let tunnel: Int
    let events: AsyncStream<KernelEvent>.Continuation
    let abort: @Sendable () -> Void
    var window = KernelProtocol.window
    var outstanding = 0
    var isOpen = false
    var sentEnd = false
    var gotEnd = false
    var opened: CheckedContinuation<Void, any Error>?
    var writable: CheckedContinuation<Void, any Error>?
    var timer: Task<Void, Never>?

    init(
      tunnel: Int, events: AsyncStream<KernelEvent>.Continuation,
      abort: @escaping @Sendable () -> Void
    ) {
      self.tunnel = tunnel
      self.events = events
      self.abort = abort
    }
  }

  private let log: @Sendable (String) -> Void
  private let openTimeout: Duration
  private var live: [Tunnel] = []
  private var streams: [UInt32: Stream] = [:]
  private var nextStream: UInt32 = 0
  private var nextTunnel = 0

  init(log: @escaping @Sendable (String) -> Void, openTimeout: Duration) {
    self.log = log
    self.openTimeout = openTimeout
  }

  func register(
    origin: String, send: @escaping @Sendable (ByteBuffer) -> Void,
    close: @escaping @Sendable () -> Void
  ) -> Int {
    nextTunnel += 1
    live.append(Tunnel(id: nextTunnel, origin: origin, send: send, close: close))
    log("kernel tunnel from \(origin) (\(live.count) open)")
    return nextTunnel
  }

  func unregister(_ id: Int) {
    guard let index = live.firstIndex(where: { $0.id == id }) else { return }
    let tunnel = live.remove(at: index)
    for (streamID, stream) in streams where stream.tunnel == id {
      destroy(streamID, code: "ECONNRESET", quiet: true)
    }
    log("kernel tunnel from \(tunnel.origin) closed (\(live.count) open)")
  }

  func shutdown() {
    for tunnel in live { tunnel.close() }
    for id in Array(streams.keys) { destroy(id, code: "ECONNRESET", quiet: true) }
  }

  private func send(
    _ stream: Stream, _ type: KernelProtocol.Frame, _ id: UInt32, _ payload: ByteBuffer
  ) {
    live.first(where: { $0.id == stream.tunnel })?.send(KernelProtocol.encode(type, id, payload))
  }

  func dial(port: Int, abort: @escaping @Sendable () -> Void) async -> KernelDial {
    guard let tunnel = live.last else { return .noPage }
    nextStream &+= 1
    let id = nextStream
    let (events, continuation) = AsyncStream<KernelEvent>.makeStream()
    let stream = Stream(tunnel: tunnel.id, events: continuation, abort: abort)
    streams[id] = stream
    let timeout = openTimeout
    stream.timer = Task { [weak self] in
      guard (try? await Task.sleep(for: timeout)) != nil else { return }
      await self?.destroy(id, code: "ETIMEDOUT")
    }
    tunnel.send(KernelProtocol.encode(.open, id, KernelProtocol.u16(port)))
    do {
      try await withCheckedThrowingContinuation { stream.opened = $0 }
      return .opened(id, events)
    } catch {
      return .failed((error as? KernelStreamError)?.code ?? "closed")
    }
  }

  func send(_ id: UInt32, _ buffer: ByteBuffer) async throws {
    var rest = buffer
    while rest.readableBytes > 0 {
      guard let stream = streams[id] else { throw KernelStreamError(code: "closed") }
      if stream.window == 0 {
        try await withCheckedThrowingContinuation { stream.writable = $0 }
        continue
      }
      let size = min(rest.readableBytes, stream.window, KernelProtocol.chunk)
      let slice = rest.readSlice(length: size)!
      stream.window -= size
      send(stream, .data, id, slice)
    }
  }

  func end(_ id: UInt32) {
    guard let stream = streams[id], !stream.sentEnd else { return }
    stream.sentEnd = true
    send(stream, .end, id, ByteBuffer())
  }

  func credit(_ id: UInt32, _ bytes: Int) {
    guard let stream = streams[id] else { return }
    stream.outstanding -= bytes
    send(stream, .credit, id, KernelProtocol.u32(bytes))
  }

  func close(_ id: UInt32) {
    destroy(id, code: nil)
  }

  func receive(_ tunnel: Int, _ frame: KernelProtocol.Decoded) {
    guard let stream = streams[frame.id], stream.tunnel == tunnel,
      let type = KernelProtocol.Frame(rawValue: frame.type)
    else { return }
    switch type {
    case .opened:
      stream.timer?.cancel()
      stream.isOpen = true
      stream.opened?.resume()
      stream.opened = nil
    case .data:
      let size = frame.payload.readableBytes
      guard stream.isOpen, !stream.gotEnd, size > 0 else {
        return destroy(frame.id, code: "EPROTO")
      }
      stream.outstanding += size
      guard stream.outstanding <= KernelProtocol.window else {
        return destroy(frame.id, code: "EPROTO")
      }
      stream.events.yield(.data(frame.payload))
    case .end:
      guard stream.isOpen, !stream.gotEnd else { return destroy(frame.id, code: "EPROTO") }
      stream.gotEnd = true
      stream.events.yield(.end)
      stream.events.finish()
    case .reset:
      destroy(frame.id, code: KernelProtocol.reason(frame.payload), quiet: true)
    case .credit:
      let bytes = Int(frame.payload.getInteger(at: frame.payload.readerIndex, as: UInt32.self) ?? 0)
      stream.window += bytes
      guard stream.window <= KernelProtocol.window else { return destroy(frame.id, code: "EPROTO") }
      stream.writable?.resume()
      stream.writable = nil
    case .open:
      return
    }
  }

  private func destroy(_ id: UInt32, code: String?, quiet: Bool = false) {
    guard let stream = streams.removeValue(forKey: id) else { return }
    stream.timer?.cancel()
    if !quiet && !(stream.sentEnd && stream.gotEnd) {
      send(stream, .reset, id, ByteBuffer(string: code ?? "closed"))
    }
    let failure = KernelStreamError(code: code ?? "closed")
    stream.opened?.resume(throwing: failure)
    stream.writable?.resume(throwing: failure)
    stream.events.finish()
    if code != nil && stream.isOpen { stream.abort() }
  }
}
