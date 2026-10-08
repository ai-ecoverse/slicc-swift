import CryptoKit
import Foundation
import NIOConcurrencyHelpers

final class HostfsFile: Sendable {
  private struct State {
    var fd: Int32
    var users = 0
    var closing = false
  }

  private let state: NIOLockedValueBox<State>

  init(fd: Int32) {
    state = NIOLockedValueBox(State(fd: fd))
  }

  func retain() throws -> Int32 {
    try state.withLockedValue { state in
      guard !state.closing else { throw HostfsError("EBADF") }
      state.users += 1
      return state.fd
    }
  }

  func unretain() {
    let fd = state.withLockedValue { state -> Int32? in
      state.users -= 1
      return state.closing && state.users == 0 ? state.fd : nil
    }
    if let fd { Darwin.close(fd) }
  }

  func close() {
    let fd = state.withLockedValue { state -> Int32? in
      guard !state.closing else { return nil }
      state.closing = true
      return state.users == 0 ? state.fd : nil
    }
    if let fd { Darwin.close(fd) }
  }
}

final class PinnedFile: Sendable {
  let fd: Int32
  private let file: HostfsFile?

  init(owned fd: Int32) {
    self.fd = fd
    file = nil
  }

  init(shared file: HostfsFile) throws {
    fd = try file.retain()
    self.file = file
  }

  deinit {
    if let file { file.unretain() } else { Darwin.close(fd) }
  }
}

struct HostfsHandle: Sendable {
  let path: JSONValue
  let file: HostfsFile?
}

final class HostfsGrant: Sendable {
  let id: String
  let folder: HostFolder
  let readonly: Bool
  let origin: String?

  struct State {
    var handles: [Int: HostfsHandle] = [:]
    var nextFh = 1
    var streams: [Int: @Sendable () -> Void] = [:]
    var nextStream = 0
    var deadline: ContinuousClock.Instant
    var alive = true
  }

  let state: NIOLockedValueBox<State>

  init(
    id: String, folder: HostFolder, readonly: Bool, origin: String?,
    deadline: ContinuousClock.Instant
  ) {
    self.id = id
    self.folder = folder
    self.readonly = readonly
    self.origin = origin
    state = NIOLockedValueBox(State(deadline: deadline))
  }

  func handle(_ fh: JSONValue?) throws -> HostfsHandle {
    guard let fh = fh?.safeInteger,
      let entry = state.withLockedValue({ $0.handles[fh] })
    else { throw HostfsError("EBADF") }
    return entry
  }

  func add(_ entry: HostfsHandle, limit: Int) throws -> Int {
    let fh = state.withLockedValue { state -> Int? in
      guard state.alive else { return -1 }
      guard state.handles.count < limit else { return nil }
      let fh = state.nextFh
      state.nextFh += 1
      state.handles[fh] = entry
      return fh
    }
    guard let fh else {
      entry.file?.close()
      throw HostfsError("EMFILE", "too many open files")
    }
    guard fh > 0 else {
      entry.file?.close()
      throw HostfsError("EBADF")
    }
    return fh
  }

  func remove(_ fh: JSONValue?) throws -> HostfsHandle {
    guard let fh = fh?.safeInteger,
      let entry = state.withLockedValue({ $0.handles.removeValue(forKey: fh) })
    else { throw HostfsError("EBADF") }
    return entry
  }
}

final class HostfsGrants: Sendable {
  let idle: Duration
  let maxHandles: Int
  private let grants = NIOLockedValueBox<[String: HostfsGrant]>([:])
  private let clock = ContinuousClock()

  init(idle: Duration = HostfsProtocol.grantIdle, maxHandles: Int = HostfsProtocol.maxHandles) {
    self.idle = idle
    self.maxHandles = maxHandles
  }

  static func digest(_ token: String) -> String {
    Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  func grant(_ folder: HostFolder, readonly: Bool, origin: String?) -> (
    token: String, grant: HostfsGrant
  ) {
    let token = ProxySecurity.mintKey()
    let grant = HostfsGrant(
      id: Self.digest(token), folder: folder, readonly: readonly || folder.readonly,
      origin: origin, deadline: clock.now.advanced(by: idle))
    grants.withLockedValue { $0[grant.id] = grant }
    Task { [weak self] in await self?.expire(grant) }
    return (token, grant)
  }

  private func expire(_ grant: HostfsGrant) async {
    while true {
      let (deadline, streaming, alive) = grant.state.withLockedValue {
        ($0.deadline, !$0.streams.isEmpty, $0.alive)
      }
      guard alive else { return }
      if !streaming, clock.now >= deadline {
        drop(grant.id)
        return
      }
      try? await Task.sleep(
        until: streaming ? clock.now.advanced(by: idle) : deadline, clock: clock)
    }
  }

  private func arm(_ grant: HostfsGrant) {
    let deadline = clock.now.advanced(by: idle)
    grant.state.withLockedValue { $0.deadline = deadline }
  }

  func find(_ token: String, origin: String?) -> HostfsGrant? {
    guard !token.isEmpty, let grant = grants.withLockedValue({ $0[Self.digest(token)] }),
      grant.origin == origin
    else { return nil }
    arm(grant)
    return grant
  }

  @discardableResult
  func revoke(_ token: String?) -> Bool {
    guard let token else { return false }
    return drop(Self.digest(token))
  }

  @discardableResult
  private func drop(_ id: String) -> Bool {
    guard let grant = grants.withLockedValue({ $0.removeValue(forKey: id) }) else { return false }
    let (handles, ends) = grant.state.withLockedValue { state in
      state.alive = false
      defer {
        state.handles.removeAll()
        state.streams.removeAll()
      }
      return (Array(state.handles.values), Array(state.streams.values))
    }
    for handle in handles { handle.file?.close() }
    for end in ends { end() }
    return true
  }

  func stream(_ grant: HostfsGrant, end: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    let key = grant.state.withLockedValue { state -> Int? in
      guard state.alive else { return nil }
      state.nextStream += 1
      state.streams[state.nextStream] = end
      return state.nextStream
    }
    guard let key else {
      end()
      return {}
    }
    return { [self] in
      let idle = grant.state.withLockedValue { state in
        state.streams.removeValue(forKey: key)
        return state.alive && state.streams.isEmpty
      }
      if idle { arm(grant) }
    }
  }

  func clear() {
    for id in grants.withLockedValue({ Array($0.keys) }) { drop(id) }
  }
}

final class HostfsLock: Sendable {
  private struct Waiter {
    let exclusive: Bool
    let continuation: CheckedContinuation<Void, Never>
  }

  private struct State {
    var readers = 0
    var writing = false
    var waiting: [Waiter] = []

    mutating func admit() -> [CheckedContinuation<Void, Never>] {
      var started: [CheckedContinuation<Void, Never>] = []
      while let head = waiting.first, !writing {
        if head.exclusive && readers > 0 { break }
        waiting.removeFirst()
        if head.exclusive { writing = true } else { readers += 1 }
        started.append(head.continuation)
      }
      return started
    }
  }

  private let state = NIOLockedValueBox(State())

  func shared<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    try await run(exclusive: false, body)
  }

  func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    try await run(exclusive: true, body)
  }

  private func run<T: Sendable>(exclusive: Bool, _ body: @Sendable () async throws -> T)
    async throws -> T
  {
    await withCheckedContinuation { continuation in
      let started = state.withLockedValue { state in
        state.waiting.append(Waiter(exclusive: exclusive, continuation: continuation))
        return state.admit()
      }
      for waiter in started { waiter.resume() }
    }
    defer {
      let started = state.withLockedValue { state in
        if exclusive { state.writing = false } else { state.readers -= 1 }
        return state.admit()
      }
      for waiter in started { waiter.resume() }
    }
    return try await body()
  }
}
