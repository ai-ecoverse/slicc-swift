import Foundation
import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ServiceLifecycle

final class Hostfs: Sendable {
  static let streamBacklog = 4096
  static let readChunk = 256 * 1024

  let folders: [HostFolder]
  let grants: HostfsGrants
  let watchers = HostfsWatchers()
  let pingInterval: Duration
  private let lock = HostfsLock()
  private let log: @Sendable (String) -> Void

  private static let tokenHeader = HTTPField.Name(HostfsProtocol.tokenHeader)!
  private static let requestHeader = HTTPField.Name(HostfsProtocol.requestHeader)!
  private static let errnoHeader = HTTPField.Name(HostfsProtocol.errnoHeader)!

  init(
    folders: [HostFolder],
    idle: Duration = HostfsProtocol.grantIdle,
    pingInterval: Duration = HostfsProtocol.pingInterval,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.folders = folders
    grants = HostfsGrants(idle: idle)
    self.pingInterval = pingInterval
    self.log = log
  }

  private static func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T)
    async throws -> T
  {
    try await NIOThreadPool.singleton.runIfActive(body)
  }

  static func json(_ value: JSONValue, status: HTTPResponse.Status = .ok) -> Response {
    Response(
      status: status,
      headers: [.contentType: "application/json", .cacheControl: "no-store"],
      body: .init(byteBuffer: ByteBuffer(string: value.serialized))
    )
  }

  static func failure(_ error: any Error) -> Response {
    let failure = HostfsError.from(error)
    var response = json(
      .object([("errno", .string(failure.errno)), ("message", .string(failure.message))]),
      status: HTTPResponse.Status(code: failure.status))
    response.headers[errnoHeader] = failure.errno
    return response
  }

  private static func readJSON(_ request: Request, limit: Int) async -> JSONValue? {
    if let declared = request.headers[.contentLength].flatMap(Int.init), declared > limit {
      return nil
    }
    var request = request
    guard let buffer = try? await request.collectBody(upTo: limit),
      let value = JSONValue.parse(Data(buffer.readableBytesView)),
      case .object = value
    else { return nil }
    return value
  }

  func grant(_ request: Request) async -> Response {
    let body = await Self.readJSON(request, limit: HostfsProtocol.maxGrantBody)
    if request.method == .delete {
      if grants.revoke(body?["token"]?.string) { log("hostfs revoke") }
      return Response(status: .noContent, headers: [.cacheControl: "no-store"])
    }
    guard let name = body?["mount"]?.string, let folder = folders.first(where: { $0.name == name })
    else { return Self.failure(HostfsError("ENOENT", "no such folder")) }
    let readonly = body?["readonly"]
    if let readonly, readonly != .bool(true), readonly != .bool(false) {
      return Self.failure(HostfsError("EINVAL"))
    }
    let minted = grants.grant(
      folder, readonly: readonly == .bool(true), origin: request.headers[.origin])
    log("hostfs grant \(folder.name) \(minted.grant.readonly ? "ro" : "rw")")
    return Self.json(
      .object([
        ("token", .string(minted.token)),
        ("mount", .string(folder.name)),
        ("readonly", .bool(minted.grant.readonly)),
        ("capabilities", folder.capabilities),
      ]))
  }

  func mounts() -> Response {
    Self.json(
      .array(
        folders.map { .object([("name", .string($0.name)), ("readonly", .bool($0.readonly))]) }))
  }

  func tokens(_ request: Request) -> [HostfsGrant?] {
    let header = request.headers[values: Self.tokenHeader].joined(separator: ",")
    guard !header.isEmpty || request.headers[Self.tokenHeader] != nil else { return [] }
    let origin = request.headers[.origin]
    return header.split(separator: ",", omittingEmptySubsequences: false).map {
      grants.find($0.trimmingCharacters(in: .whitespaces), origin: origin)
    }
  }

  func handle(_ request: Request, path: String) async throws -> Response {
    let found = tokens(request)
    let live = found.compactMap { $0 }
    guard !live.isEmpty, live.count == found.count,
      path == HostfsProtocol.watchPath || live.count == 1
    else {
      return try rawProxyError(
        status: .forbidden, message: "hostfs token missing, unknown or revoked")
    }
    if path == HostfsProtocol.watchPath { return watch(live) }
    do {
      if path == HostfsProtocol.writePath { return try await write(live[0], request) }
      return try await operate(live[0], request)
    } catch {
      return Self.failure(error)
    }
  }

  private func operate(_ grant: HostfsGrant, _ request: Request) async throws -> Response {
    guard let body = await Self.readJSON(request, limit: HostfsProtocol.maxOpBody),
      let op = body["op"]?.string
    else { throw HostfsError("EINVAL") }
    let writes =
      HostfsFileSystem.writingOps.contains(op)
      || (op == "open" && HostfsFileSystem.wantsWrite(body))
    if writes && grant.readonly { throw HostfsError("EROFS") }
    switch op {
    case "read": return try await read(grant, body)
    case "open": return Self.json(try await open(grant, body))
    case "release": return Self.json(try await release(grant, body["fh"]))
    default:
      let root = grant.folder.root
      let work: @Sendable () async throws -> JSONValue = {
        try await Self.blocking { try HostfsFileSystem.pathOp(root, body) }
      }
      let answer = writes ? try await lock.exclusive(work) : try await lock.shared(work)
      if writes {
        let named = body["path"]?.string ?? body["from"]?.string ?? ""
        log("hostfs \(op) \(grant.folder.name)/\(named)")
      }
      return Self.json(answer)
    }
  }

  private func open(_ grant: HostfsGrant, _ body: JSONValue) async throws -> JSONValue {
    let writing = HostfsFileSystem.wantsWrite(body)
    let root = grant.folder.root
    let work: @Sendable () async throws -> (Int32, HostfsAttr) = {
      try await Self.blocking { try HostfsFileSystem.openFile(root, body) }
    }
    let (fd, attr) = writing ? try await lock.exclusive(work) : try await lock.shared(work)
    if !writing { Darwin.close(fd) }
    let fh = try grant.add(
      HostfsHandle(
        path: HostfsFileSystem.pathField(body), file: writing ? HostfsFile(fd: fd) : nil),
      limit: grants.maxHandles)
    if writing { log("hostfs open \(grant.folder.name)/\(body["path"]?.string ?? "")") }
    return .object([("fh", .int(fh)), ("attr", attr.json)])
  }

  private func release(_ grant: HostfsGrant, _ fh: JSONValue?) async throws -> JSONValue {
    let entry = try grant.remove(fh)
    guard let file = entry.file else { return .object([]) }
    defer { file.close() }
    let pinned = try PinnedFile(shared: file)
    let attr = try await Self.blocking { try HostfsFileSystem.fileAttr(pinned.fd) }
    return .object([("attr", attr.json)])
  }

  private func read(_ grant: HostfsGrant, _ body: JSONValue) async throws -> Response {
    guard let offset = body["offset"]?.safeInteger, offset >= 0,
      let size = body["size"]?.safeInteger, size >= 0, size <= HostfsProtocol.maxIo
    else { throw HostfsError("EINVAL") }
    let entry = try grant.handle(body["fh"])
    let pinned: PinnedFile
    if let file = entry.file {
      pinned = try PinnedFile(shared: file)
    } else {
      let root = grant.folder.root
      let path = entry.path
      pinned = try await lock.shared {
        try await Self.blocking {
          PinnedFile(owned: try HostfsFileSystem.openLeaf(root, path, flags: O_RDONLY))
        }
      }
    }
    let attr = try await Self.blocking { try HostfsFileSystem.fileAttr(pinned.fd) }
    let etag = attr.etag
    if entry.file == nil, let ifMatch = body["ifMatch"], ifMatch != .string(etag) {
      throw HostfsError("ESTALE")
    }
    let total = Int(attr.size)
    let end = min(offset + size, total)
    let length = max(0, end - offset)
    let headers: HTTPFields = [
      .contentType: "application/octet-stream",
      .cacheControl: "no-store",
      .eTag: etag,
      .contentRange: length > 0 ? "bytes \(offset)-\(end - 1)/\(total)" : "bytes */\(total)",
    ]
    let body = ResponseBody(contentLength: length) { writer in
      var position = offset
      while position < end {
        let count = min(Self.readChunk, end - position)
        let at = position
        let bytes = try await Self.blocking {
          try HostfsFileSystem.read(pinned.fd, at: at, count: count)
        }
        guard bytes.count == count else { throw HostfsError("EIO") }
        try await writer.write(ByteBuffer(bytes: bytes))
        position += count
      }
      try await writer.finish(nil)
    }
    return Response(status: .ok, headers: headers, body: body)
  }

  private func write(_ grant: HostfsGrant, _ request: Request) async throws -> Response {
    if grant.readonly { throw HostfsError("EROFS") }
    guard let encoded = request.headers[Self.requestHeader],
      let head = JSONValue.parse(Data(encoded.utf8)), case .object = head,
      let offset = head["offset"]?.safeInteger, offset >= 0
    else { throw HostfsError("EINVAL") }
    let entry = try grant.handle(head["fh"])
    guard let file = entry.file else { throw HostfsError("EBADF") }
    if let declared = request.headers[.contentLength].flatMap(Int.init),
      declared > HostfsProtocol.maxIo
    {
      throw HostfsError("EINVAL")
    }
    let pinned = try PinnedFile(shared: file)
    var position = offset
    for try await chunk in request.body {
      if position + chunk.readableBytes - offset > HostfsProtocol.maxIo {
        throw HostfsError("EINVAL")
      }
      let at = position
      try await Self.blocking {
        try chunk.withUnsafeReadableBytes { try HostfsFileSystem.writeAll(pinned.fd, $0, at: at) }
      }
      position += chunk.readableBytes
    }
    return Self.json(.object([]))
  }

  static func watchLine(mount: String, change: HostfsChange) -> String {
    switch change {
    case .all:
      return JSONValue.object([("mount", .string(mount)), ("all", .bool(true))]).serialized
    case .paths(let paths):
      return JSONValue.object([
        ("mount", .string(mount)), ("paths", .array(paths.map { .string($0) })),
      ])
      .serialized
    }
  }

  private func watch(_ found: [HostfsGrant]) -> Response {
    let headers: HTTPFields = [
      .contentType: "application/x-ndjson",
      .cacheControl: "no-store",
      HTTPField.Name("X-Content-Type-Options")!: "nosniff",
    ]
    let body = ResponseBody { [self] writer in
      let (lines, continuation) = AsyncStream.makeStream(
        of: ByteBuffer.self, bufferingPolicy: .bufferingOldest(Self.streamBacklog))
      let overflowed = NIOLockedValueBox(false)
      let line: @Sendable (String) -> Void = { text in
        if case .dropped = continuation.yield(ByteBuffer(string: text + "\n")) {
          overflowed.withLockedValue { $0 = true }
          continuation.finish()
        }
      }
      var cleanups: [@Sendable () -> Void] = []
      for grant in found {
        cleanups.append(grants.stream(grant) { continuation.finish() })
      }
      var seen = Set<String>()
      for grant in found where seen.insert(grant.folder.name).inserted {
        let mount = grant.folder.name
        cleanups.append(
          watchers.subscribe(grant.folder.root) { line(Self.watchLine(mount: mount, change: $0)) })
      }
      let interval = pingInterval
      let ping = Task {
        while !Task.isCancelled {
          try await Task.sleep(for: interval)
          line("{\"ping\":1}")
        }
      }
      defer {
        ping.cancel()
        continuation.finish()
        for cleanup in cleanups { cleanup() }
      }
      try await withGracefulShutdownHandler {
        for await buffer in lines { try await writer.write(buffer) }
      } onGracefulShutdown: {
        continuation.finish()
      }
      if overflowed.withLockedValue({ $0 }) { throw HostfsError("EIO") }
      try await writer.finish(nil)
    }
    return Response(status: .ok, headers: headers, body: body)
  }

  func close() {
    grants.clear()
    watchers.close()
  }
}

struct HostfsService: Service {
  let hostfs: Hostfs

  func run() async throws {
    try? await gracefulShutdown()
    hostfs.close()
  }
}
