import AsyncHTTPClient
import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import Testing

@testable import SliccSwift

struct Reply {
  let status: Int
  let headers: HTTPHeaders
  let body: [UInt8]

  var text: String { String(decoding: body, as: UTF8.self) }
  var json: Any? { try? JSONSerialization.jsonObject(with: Data(body), options: .fragmentsAllowed) }
  var object: [String: Any] { json as? [String: Any] ?? [:] }
  func header(_ name: String) -> String? { headers.first(name: name) }
}

struct Fixture: Sendable {
  let base: String
  let folder: String
  let outside: String
  let docs: String

  static func make() throws -> Fixture {
    let template = NSTemporaryDirectory() + "slicc-hostfs-XXXXXX"
    var bytes = Array(template.utf8CString)
    guard let made = mkdtemp(&bytes) else { throw HostfsError.posix(errno) }
    let base = try HostfsFileSystem.realPath(String(cString: made))
    let fixture = Fixture(
      base: base, folder: base + "/project", outside: base + "/secret", docs: base + "/docs")
    let files = FileManager.default
    for directory in [fixture.folder, fixture.outside, fixture.docs] {
      try files.createDirectory(atPath: directory, withIntermediateDirectories: false)
    }
    try fixture.write(fixture.outside + "/key.txt", "top secret")
    try fixture.write(fixture.folder + "/hello.txt", "hello")
    try files.createSymbolicLink(
      atPath: fixture.folder + "/escape", withDestinationPath: fixture.outside)
    try files.createSymbolicLink(
      atPath: fixture.folder + "/key-link", withDestinationPath: fixture.outside + "/key.txt")
    try files.createSymbolicLink(
      atPath: fixture.folder + "/inner-link", withDestinationPath: "hello.txt")
    return fixture
  }

  func write(_ path: String, _ text: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  func read(_ path: String) throws -> String {
    String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
  }

  var folders: [HostFolder] {
    HostFolder.load([folder, docs + ":docs:ro", base + "/missing"])
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: base)
  }
}

struct HostfsClient: Sendable {
  let harness: Harness
  let fixture: Fixture

  func send(
    _ path: String,
    method: HTTPMethod = .POST,
    headers: [(String, String)] = [],
    body: [UInt8]? = nil
  ) async throws -> Reply {
    var request = HTTPClientRequest(url: harness.proxy + path)
    request.method = method
    for (name, value) in headers { request.headers.add(name: name, value: value) }
    if let body { request.body = .bytes(ByteBuffer(bytes: body)) }
    let response = try await harness.client.execute(request, timeout: .seconds(60))
    let bytes = try await response.body.collect(upTo: 64 * 1024 * 1024)
    return Reply(
      status: Int(response.status.code), headers: response.headers,
      body: Array(bytes.readableBytesView))
  }

  static func encode(_ object: [String: Any]) -> [UInt8] {
    Array(try! JSONSerialization.data(withJSONObject: object))
  }

  func keyed(
    _ path: String, _ body: [String: Any], method: HTTPMethod = .POST,
    origin: String = hostedOrigin, key: String = testKey
  ) async throws -> Reply {
    try await send(
      path, method: method, headers: [("Origin", origin), (ProxySecurity.keyHeader, key)],
      body: Self.encode(body))
  }

  func grant(_ mount: String, readonly: Bool = false, origin: String = hostedOrigin) async throws
    -> [String: Any]
  {
    let reply = try await keyed(
      HostfsProtocol.grantPath, ["mount": mount, "readonly": readonly], origin: origin)
    #expect(reply.status == 200, "\(reply.text)")
    return reply.object
  }

  func token(_ mount: String, readonly: Bool = false) async throws -> String {
    try #require(try await grant(mount, readonly: readonly)["token"] as? String)
  }

  func op(_ token: String, _ body: [String: Any], origin: String = hostedOrigin) async throws
    -> Reply
  {
    try await send(
      HostfsProtocol.path, headers: [("Origin", origin), (HostfsProtocol.tokenHeader, token)],
      body: Self.encode(body))
  }

  @discardableResult
  func ok(_ token: String, _ body: [String: Any]) async throws -> [String: Any] {
    let reply = try await op(token, body)
    #expect(reply.status == 200, "\(body) \(reply.text)")
    return reply.object
  }

  @discardableResult
  func errno(
    _ token: String, _ body: [String: Any], _ expected: String, _ status: Int? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> Reply {
    let reply = try await op(token, body)
    #expect(
      reply.header(HostfsProtocol.errnoHeader) == expected, "\(body) \(reply.text)",
      sourceLocation: sourceLocation)
    if let status { #expect(reply.status == status, sourceLocation: sourceLocation) }
    #expect(reply.object["errno"] as? String == expected, sourceLocation: sourceLocation)
    #expect(
      !reply.text.contains(fixture.base), "no host paths in errors", sourceLocation: sourceLocation)
    return reply
  }

  func put(_ token: String, _ fh: Any?, _ offset: Int, _ bytes: [UInt8]) async throws -> Reply {
    let head = String(
      decoding: Self.encode(["fh": fh ?? NSNull(), "offset": offset]), as: UTF8.self)
    return try await send(
      HostfsProtocol.writePath, method: .PUT,
      headers: [
        ("Origin", hostedOrigin), (HostfsProtocol.tokenHeader, token),
        (HostfsProtocol.requestHeader, head),
      ],
      body: bytes)
  }

  func watch(_ tokens: [String]) async throws -> Watch {
    var request = HTTPClientRequest(url: harness.proxy + HostfsProtocol.watchPath)
    request.method = .POST
    request.headers.add(name: "Origin", value: hostedOrigin)
    request.headers.add(name: HostfsProtocol.tokenHeader, value: tokens.joined(separator: ", "))
    let response = try await harness.client.execute(request, timeout: .seconds(60))
    let lines = WatchLines()
    let reader = Task {
      var buffered = ""
      do {
        for try await chunk in response.body {
          buffered += String(buffer: chunk)
          while let newline = buffered.firstIndex(of: "\n") {
            await lines.add(String(buffered[..<newline]))
            buffered = String(buffered[buffered.index(after: newline)...])
          }
        }
      } catch {}
      await lines.add("end")
    }
    return Watch(
      status: Int(response.status.code), headers: response.headers, lines: lines, reader: reader)
  }
}

actor WatchLines {
  private(set) var lines: [String] = []

  func add(_ line: String) { lines.append(line) }
}

struct Watch: Sendable {
  let status: Int
  let headers: HTTPHeaders
  let lines: WatchLines
  let reader: Task<Void, Never>

  func until(_ match: @Sendable ([String: Any]?, String) -> Bool) async throws -> String {
    for _ in 0..<200 {
      for line in await lines.lines {
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        if match(object, line) { return line }
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("no matching line in \(await lines.lines)")
    return ""
  }

  func close() { reader.cancel() }
}

func withHostfs(
  idle: Duration = HostfsProtocol.grantIdle,
  _ body: @Sendable (HostfsClient) async throws -> Void
) async throws {
  let fixture = try Fixture.make()
  defer { fixture.remove() }
  try await withHarness(folders: fixture.folders, hostfsIdle: idle) { harness in
    try await body(HostfsClient(harness: harness, fixture: fixture))
  }
}

func names(_ listing: [String: Any]) -> [String] {
  (listing["entries"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
}

@Suite struct HostfsTests {
  @Test func probeAnnouncesHostfsAndMountsHideHostPaths() async throws {
    try await withHostfs { fs in
      let probe = try await fs.send(
        RawFetchProtocol.path,
        headers: [
          ("Origin", hostedOrigin), (ProxySecurity.keyHeader, testKey),
          (RawFetchProtocol.probeHeader, "1"),
        ])
      #expect(probe.object["hostfs"] as? Int == 1)
      let mounts = try await fs.keyed(HostfsProtocol.mountsPath, [:])
      #expect(
        mounts.text == #"[{"name":"project","readonly":false},{"name":"docs","readonly":true}]"#)
      #expect(!mounts.text.contains(fs.fixture.base))
      let preflight = try await fs.send(
        HostfsProtocol.writePath, method: .OPTIONS,
        headers: [("Origin", hostedOrigin), ("Access-Control-Request-Method", "PUT")])
      #expect(preflight.status == 204)
      #expect(preflight.header("access-control-allow-methods") == "GET, POST, PUT, DELETE, OPTIONS")
      #expect(
        preflight.header("access-control-allow-headers")?.contains(
          "X-Hostfs-Token, X-Hostfs-Request")
          == true)
      #expect(
        preflight.header("access-control-expose-headers")
          == "X-Proxy-Error, X-Hostfs-Errno, ETag, Content-Range")
    }
  }

  @Test func probeOmitsHostfsWithoutFolders() async throws {
    try await withHarness { harness in
      let (_, bytes) = try await harness.post(headers: [(RawFetchProtocol.probeHeader, "1")])
      let probe = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
      #expect(probe?["hostfs"] == nil)
    }
  }

  @Test func grantNeedsKeyOriginAndAnExportedFolder() async throws {
    try await withHostfs { fs in
      let granted = try await fs.grant("project")
      let token = try #require(granted["token"] as? String)
      #expect(token.count == 43)
      #expect(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
      #expect(granted["readonly"] as? Bool == false)
      let capabilities = try #require(granted["capabilities"] as? [String: Any])
      #expect(capabilities["maxIo"] as? Int == 16 * 1024 * 1024)
      #expect(capabilities["caseInsensitive"] is Bool)
      #expect(capabilities["normalization"] as? String == "nfd-insensitive")
      let noKey = try await fs.keyed(HostfsProtocol.grantPath, ["mount": "project"], key: "x")
      #expect(noKey.status == 403)
      #expect(noKey.header(RawFetchProtocol.errorHeader) == "1")
      let evil = try await fs.keyed(
        HostfsProtocol.grantPath, ["mount": "project"], origin: "https://evil.test")
      #expect(evil.status == 403)
      #expect(evil.header("access-control-allow-origin") == nil)
      let unknown = try await fs.keyed(HostfsProtocol.grantPath, ["mount": "missing"])
      #expect(unknown.status == 404)
      #expect(unknown.header(HostfsProtocol.errnoHeader) == "ENOENT")
      let bad = try await fs.keyed(
        HostfsProtocol.grantPath, ["mount": "project", "readonly": "yes"])
      #expect(bad.header(HostfsProtocol.errnoHeader) == "EINVAL")
      #expect(try await fs.grant("docs")["readonly"] as? Bool == true)
      let get = try await fs.keyed(HostfsProtocol.grantPath, [:], method: .PUT)
      #expect(get.status == 405)
      #expect(get.header("allow") == "POST, DELETE, OPTIONS")
    }
  }

  @Test func missingUnknownRevokedOrForeignTokensAreRefused() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      let stat: [String: Any] = ["op": "stat", "path": ""]
      let missing = try await fs.send(
        HostfsProtocol.path, headers: [("Origin", hostedOrigin)], body: HostfsClient.encode(stat))
      #expect(missing.status == 403)
      #expect(missing.header(RawFetchProtocol.errorHeader) == "1")
      #expect(try await fs.op(String(repeating: "x", count: 43), stat).status == 403)
      let branch = try await fs.op(token, stat, origin: "https://branch.sliccy.ai")
      #expect(branch.status == 403)
      #expect(branch.header(RawFetchProtocol.errorHeader) == "1")
      #expect(branch.header("access-control-allow-origin") == "https://branch.sliccy.ai")
      let evil = try await fs.op(token, stat, origin: "https://evil.test")
      #expect(evil.status == 403)
      #expect(evil.header("access-control-allow-origin") == nil)
      let query = try await fs.send(
        HostfsProtocol.path + "?token=" + token, headers: [("Origin", hostedOrigin)],
        body: HostfsClient.encode(stat))
      #expect(query.status == 403)
      let both = try await fs.op(token + ", " + token, stat)
      #expect(both.status == 403)
      try await fs.ok(token, stat)
      let revoked = try await fs.keyed(HostfsProtocol.grantPath, ["token": token], method: .DELETE)
      #expect(revoked.status == 204)
      let after = try await fs.op(token, stat)
      #expect(after.status == 403)
      #expect(after.header(RawFetchProtocol.errorHeader) == "1")
    }
  }

  @Test func tokensAreStoredHashed() {
    let grants = HostfsGrants()
    let folder = HostFolder(name: "x", root: "/", readonly: true, caseInsensitive: false)
    let (token, grant) = grants.grant(folder, readonly: false, origin: hostedOrigin)
    #expect(grant.id != token)
    #expect(!grant.id.contains(token))
    let digest = Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    #expect(grant.id == digest)
    #expect(grants.find(token, origin: hostedOrigin) === grant)
    #expect(grants.find(token, origin: "https://other.sliccy.ai") == nil)
    grants.clear()
  }

  @Test func idleTokensExpireButAWatchKeepsThemAlive() async throws {
    try await withHostfs(idle: .milliseconds(400)) { fs in
      let idle = try await fs.token("project")
      let opened = try await fs.ok(
        idle, ["op": "open", "path": "idle.txt", "create": true, "write": true])
      try await Task.sleep(for: .milliseconds(800))
      #expect(try await fs.op(idle, ["op": "release", "fh": opened["fh"] ?? 0]).status == 403)
      let watched = try await fs.token("project")
      let stream = try await fs.watch([watched])
      try await Task.sleep(for: .milliseconds(800))
      try await fs.ok(watched, ["op": "stat", "path": ""])
      stream.close()
    }
  }

  @Test func pathsCannotLeaveTheFolder() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      for path in ["..", "../secret/key.txt", "a/../../secret", "/etc/passwd", "/"] {
        try await fs.errno(token, ["op": "stat", "path": path], "EACCES", 403)
      }
      try await fs.errno(token, ["op": "stat", "path": "a\u{0}b"], "EINVAL", 400)
      try await fs.errno(token, ["op": "stat", "path": 7], "EINVAL", 400)
      try await fs.errno(token, ["op": "stat", "path": "escape/key.txt"], "EACCES", 403)
      try await fs.errno(token, ["op": "list", "path": "escape"], "ENOTDIR")
      try await fs.errno(token, ["op": "open", "path": "escape/key.txt"], "EACCES")
      try await fs.errno(token, ["op": "open", "path": "key-link"], "ELOOP", 400)
      try await fs.errno(
        token, ["op": "open", "path": "key-link", "write": true, "truncate": true], "ELOOP")
      try await fs.errno(token, ["op": "mkdir", "path": "escape/new"], "EACCES")
      try await fs.errno(
        token, ["op": "rename", "from": "hello.txt", "to": "../stolen.txt"], "EACCES")
      try await fs.errno(
        token, ["op": "rename", "from": "escape/key.txt", "to": "mine.txt"], "EACCES")
      try await fs.ok(token, ["op": "symlink", "target": "/", "path": "root-link"])
      try await fs.errno(token, ["op": "list", "path": "root-link/etc"], "EACCES")
      try await fs.errno(token, ["op": "setattr", "path": "key-link", "mode": 0o777], "EINVAL")
      #expect(
        try await fs.ok(token, ["op": "readlink", "path": "inner-link"])["target"] as? String
          == "hello.txt")
      #expect(
        try await fs.ok(token, ["op": "stat", "path": "inner-link"])["kind"] as? String == "symlink"
      )
      #expect(try fs.fixture.read(fs.fixture.outside + "/key.txt") == "top secret")
    }
  }

  @Test func readOnlyTokensCannotWrite() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project", readonly: true)
      try await fs.ok(token, ["op": "stat", "path": "hello.txt"])
      let writes: [[String: Any]] = [
        ["op": "mkdir", "path": "x"],
        ["op": "rmdir", "path": "x"],
        ["op": "unlink", "path": "hello.txt"],
        ["op": "rename", "from": "hello.txt", "to": "bye.txt"],
        ["op": "symlink", "target": "hello.txt", "path": "l"],
        ["op": "setattr", "path": "hello.txt", "mode": 0o600],
        ["op": "open", "path": "hello.txt", "write": true],
        ["op": "open", "path": "new.txt", "create": true],
        ["op": "open", "path": "hello.txt", "truncate": true],
      ]
      for body in writes { try await fs.errno(token, body, "EROFS", 403) }
      let opened = try await fs.ok(token, ["op": "open", "path": "hello.txt"])
      let put = try await fs.put(token, opened["fh"], 0, Array("x".utf8))
      #expect(put.status == 403)
      #expect(put.header(HostfsProtocol.errnoHeader) == "EROFS")
      #expect(try fs.fixture.read(fs.fixture.folder + "/hello.txt") == "hello")
      let docs = try await fs.token("docs")
      try await fs.errno(docs, ["op": "mkdir", "path": "x"], "EROFS")
    }
  }

  @Test func metadataOperationsAnswerWithPosixErrnos() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      try await fs.ok(token, ["op": "mkdir", "path": "dir"])
      try await fs.errno(token, ["op": "mkdir", "path": "dir"], "EEXIST", 409)
      try await fs.errno(token, ["op": "mkdir", "path": "no/such/dir"], "ENOENT", 404)
      try await fs.ok(token, ["op": "mkdir", "path": "dir/sub"])
      try await fs.errno(token, ["op": "rmdir", "path": "dir"], "ENOTEMPTY", 409)
      try await fs.errno(token, ["op": "unlink", "path": "dir"], "EISDIR", 409)
      try await fs.errno(token, ["op": "rmdir", "path": "hello.txt"], "ENOTDIR", 409)
      try await fs.errno(token, ["op": "unlink", "path": ""], "EBUSY", 409)
      try await fs.errno(token, ["op": "rename", "from": "", "to": "x"], "EBUSY", 409)
      try await fs.errno(token, ["op": "read", "fh": 9999, "offset": 0, "size": 1], "EBADF", 410)
      try await fs.errno(token, ["op": "nope"], "EINVAL", 400)
      try await fs.ok(token, ["op": "mkdir", "path": "full"])
      try await fs.ok(token, ["op": "mkdir", "path": "full/x"])
      try await fs.errno(token, ["op": "rename", "from": "dir", "to": "full"], "ENOTEMPTY", 409)
      try await fs.ok(token, ["op": "rmdir", "path": "dir/sub"])
      try await fs.ok(token, ["op": "rename", "from": "dir", "to": "moved"])
      let listing = try await fs.ok(token, ["op": "list", "path": ""])
      #expect(names(listing).contains("moved") && !names(listing).contains("dir"))
      let moved = (listing["entries"] as? [[String: Any]])?.first {
        $0["name"] as? String == "moved"
      }
      #expect((moved?["attr"] as? [String: Any])?["kind"] as? String == "directory")
      try await fs.ok(
        token, ["op": "setattr", "path": "hello.txt", "mode": 0o600, "mtime": 1_000_000_000_000])
      for mtime in [1e300, -1e300] {
        try await fs.errno(
          token, ["op": "setattr", "path": "hello.txt", "mtime": mtime], "EINVAL", 400)
      }
      let attr = try await fs.ok(token, ["op": "stat", "path": "hello.txt"])
      #expect(attr["mode"] as? Int == 0o600)
      #expect(attr["mtime"] as? Int == 1_000_000_000_000)
      #expect(attr["size"] as? Int == 5)
      let etag = try #require(attr["etag"] as? String)
      #expect(etag.hasPrefix("\"5-1000000000000000000-"))
      let statfs = try await fs.ok(token, ["op": "statfs"])
      #expect((statfs["bsize"] as? Int ?? 0) > 0 && (statfs["blocks"] as? Int ?? 0) > 0)
      let big = try await fs.op(
        token, ["op": "stat", "path": String(repeating: "x", count: 2 * 1024 * 1024)])
      #expect(big.header(HostfsProtocol.errnoHeader) == "EINVAL")
    }
  }

  @Test func caseOnlyRenameKeepsTheFile() async throws {
    try await withHostfs { fs in
      let granted = try await fs.grant("project")
      let token = try #require(granted["token"] as? String)
      let insensitive = (granted["capabilities"] as? [String: Any])?["caseInsensitive"] as? Bool
      try fs.fixture.write(fs.fixture.folder + "/Case.txt", "case")
      try await fs.ok(token, ["op": "rename", "from": "Case.txt", "to": "case.txt"])
      let listing = names(try await fs.ok(token, ["op": "list", "path": ""]))
      #expect(listing.contains("case.txt"))
      if insensitive == true { #expect(!listing.contains("Case.txt")) }
      #expect(try fs.fixture.read(fs.fixture.folder + "/case.txt") == "case")
    }
  }

  @Test func chunkedWritesLandInPlaceAndKeepHardLinks() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      let folder = fs.fixture.folder
      try fs.fixture.write(folder + "/linked.txt", "old content")
      #expect(link(folder + "/linked.txt", folder + "/other-name.txt") == 0)
      let opened = try await fs.ok(
        token, ["op": "open", "path": "linked.txt", "write": true, "truncate": true])
      #expect((opened["attr"] as? [String: Any])?["size"] as? Int == 0)
      #expect(try await fs.put(token, opened["fh"], 6, Array("world".utf8)).status == 200)
      #expect(try await fs.put(token, opened["fh"], 0, Array("hello ".utf8)).status == 200)
      let own = try await fs.op(
        token,
        ["op": "read", "fh": opened["fh"] ?? 0, "offset": 0, "size": 64, "ifMatch": "\"old\""])
      #expect(own.status == 200)
      #expect(own.text == "hello world")
      let released = try await fs.ok(token, ["op": "release", "fh": opened["fh"] ?? 0])
      #expect((released["attr"] as? [String: Any])?["size"] as? Int == 11)
      #expect(try fs.fixture.read(folder + "/other-name.txt") == "hello world")
      let stale = try await fs.put(token, opened["fh"], 0, Array("x".utf8))
      #expect(stale.status == 410)
      #expect(stale.header(HostfsProtocol.errnoHeader) == "EBADF")
      try await fs.errno(
        token, ["op": "open", "path": "linked.txt", "create": true, "exclusive": true], "EEXIST")
      try await fs.ok(token, ["op": "mkdir", "path": "moved"])
      try await fs.errno(token, ["op": "open", "path": "moved", "write": true], "EISDIR")
      try await fs.errno(token, ["op": "open", "path": "", "write": true], "EISDIR")
      try await fs.errno(
        token, ["op": "open", "path": "nope/x", "create": true, "write": true], "ENOENT")
      let created = try await fs.ok(
        token,
        ["op": "open", "path": "fresh.txt", "create": true, "exclusive": true, "mode": 0o600])
      #expect((created["attr"] as? [String: Any])?["mode"] as? Int == 0o600 & ~0o022)
      _ = try await fs.put(token, created["fh"], 4, Array("tail".utf8))
      try await fs.ok(token, ["op": "release", "fh": created["fh"] ?? 0])
      let fresh = try Data(contentsOf: URL(fileURLWithPath: folder + "/fresh.txt"))
      #expect(Array(fresh) == [0, 0, 0, 0] + Array("tail".utf8))
      let again = try await fs.ok(token, ["op": "open", "path": "fresh.txt", "write": true])
      let tooBig = try await fs.put(
        token, again["fh"], 0, [UInt8](repeating: 1, count: 16 * 1024 * 1024 + 1))
      #expect(tooBig.header(HostfsProtocol.errnoHeader) == "EINVAL")
      let badHead = try await fs.send(
        HostfsProtocol.writePath, method: .PUT,
        headers: [
          ("Origin", hostedOrigin), (HostfsProtocol.tokenHeader, token),
          (HostfsProtocol.requestHeader, "{\"fh\":1,\"offset\":-1}"),
        ], body: Array("x".utf8))
      #expect(badHead.header(HostfsProtocol.errnoHeader) == "EINVAL")
      try await fs.ok(token, ["op": "release", "fh": again["fh"] ?? 0])
    }
  }

  @Test func readsComeInWindowsCarryTheEtagAndRefuseAChangedFile() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      let path = fs.fixture.folder + "/data.bin"
      try fs.fixture.write(path, "abcdefghij")
      let opened = try await fs.ok(token, ["op": "open", "path": "data.bin"])
      let fh = opened["fh"] ?? 0
      let etag = try #require((opened["attr"] as? [String: Any])?["etag"] as? String)
      let window = try await fs.op(
        token, ["op": "read", "fh": fh, "offset": 2, "size": 4, "ifMatch": etag])
      #expect(window.status == 200)
      #expect(window.text == "cdef")
      #expect(window.header("etag") == etag)
      #expect(window.header("content-range") == "bytes 2-5/10")
      #expect(window.header("content-type") == "application/octet-stream")
      let tail = try await fs.op(
        token, ["op": "read", "fh": fh, "offset": 8, "size": 100, "ifMatch": etag])
      #expect(tail.text == "ij")
      let past = try await fs.op(
        token, ["op": "read", "fh": fh, "offset": 50, "size": 10, "ifMatch": etag])
      #expect(past.status == 200)
      #expect(past.body.isEmpty)
      #expect(past.header("content-range") == "bytes */10")
      try await fs.errno(
        token, ["op": "read", "fh": fh, "offset": 0, "size": 16 * 1024 * 1024 + 1], "EINVAL")
      try await fs.errno(token, ["op": "read", "fh": fh, "offset": -1, "size": 1], "EINVAL")
      try await fs.errno(token, ["op": "read", "fh": fh, "offset": 0.5, "size": 1], "EINVAL")
      try fs.fixture.write(path, "ABCDEFGHIJK")
      try await fs.errno(
        token, ["op": "read", "fh": fh, "offset": 0, "size": 4, "ifMatch": etag], "ESTALE", 409)
      #expect(try await fs.ok(token, ["op": "release", "fh": fh]).isEmpty)
    }
  }

  @Test func aLargeFileGoesUpAndDownInMaxIoChunks() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      let maxIo = HostfsProtocol.maxIo
      var generator = SystemRandomNumberGenerator()
      let data = (0..<(2 * maxIo + 12345)).map { _ in UInt8.random(in: 0...255, using: &generator) }
      let opened = try await fs.ok(
        token, ["op": "open", "path": "big.bin", "create": true, "truncate": true])
      for offset in stride(from: 0, to: data.count, by: maxIo) {
        let chunk = Array(data[offset..<min(offset + maxIo, data.count)])
        #expect(try await fs.put(token, opened["fh"], offset, chunk).status == 200)
      }
      try await fs.ok(token, ["op": "release", "fh": opened["fh"] ?? 0])
      let written = try Data(contentsOf: URL(fileURLWithPath: fs.fixture.folder + "/big.bin"))
      #expect(SHA256.hash(data: written) == SHA256.hash(data: Data(data)))
      let reading = try await fs.ok(token, ["op": "open", "path": "big.bin"])
      let attr = try #require(reading["attr"] as? [String: Any])
      var parts: [UInt8] = []
      for offset in stride(from: 0, to: attr["size"] as? Int ?? 0, by: maxIo) {
        let reply = try await fs.op(
          token,
          [
            "op": "read", "fh": reading["fh"] ?? 0, "offset": offset, "size": maxIo,
            "ifMatch": attr["etag"] ?? "",
          ])
        parts += reply.body
      }
      #expect(SHA256.hash(data: Data(parts)) == SHA256.hash(data: Data(data)))
    }
  }

  @Test func watchReportsHostChangesPerFolderAndEndsOnRevoke() async throws {
    try await withHostfs { fs in
      let project = try await fs.token("project")
      let docs = try await fs.token("docs")
      let stream = try await fs.watch([project, docs])
      #expect(stream.status == 200)
      #expect(stream.headers.first(name: "content-type") == "application/x-ndjson")
      #expect(stream.headers.first(name: "x-content-type-options") == "nosniff")
      try await Task.sleep(for: .milliseconds(300))
      try FileManager.default.createDirectory(
        atPath: fs.fixture.folder + "/watched", withIntermediateDirectories: true)
      try fs.fixture.write(fs.fixture.folder + "/watched/a.txt", "a")
      let line = try await stream.until { object, _ in
        guard object?["mount"] as? String == "project" else { return false }
        return object?["all"] as? Bool == true
          || (object?["paths"] as? [String])?.contains("watched/a.txt") == true
      }
      if line.contains("paths") { #expect(line.contains("\"watched\"")) }
      try fs.fixture.write(fs.fixture.docs + "/readme.md", "docs")
      _ = try await stream.until { object, _ in object?["mount"] as? String == "docs" }
      _ = try await fs.keyed(HostfsProtocol.grantPath, ["token": docs], method: .DELETE)
      _ = try await stream.until { _, line in line == "end" }
      let refused = try await fs.send(
        HostfsProtocol.watchPath,
        headers: [("Origin", hostedOrigin), (HostfsProtocol.tokenHeader, project + ", unknown")])
      #expect(refused.status == 403)
    }
  }

  @Test func shutdownEndsAnOpenWatch() async throws {
    try await withHostfs { fs in
      let token = try await fs.token("project")
      let stream = try await fs.watch([token])
      #expect(stream.status == 200)
    }
  }

  @Test func watchLinesCarryTheMountName() {
    #expect(Hostfs.watchLine(mount: "p", change: .all) == #"{"mount":"p","all":true}"#)
    #expect(
      Hostfs.watchLine(mount: "p", change: .paths(["a/b", "a"]))
        == #"{"mount":"p","paths":["a/b","a"]}"#)
    #expect(HostfsWatchers.changedPaths("a/b/c") == ["a/b/c", "a/b"])
    #expect(HostfsWatchers.changedPaths("top") == ["top", ""])
    #expect(HostfsWatchers.relativeName(root: "/r", path: "/r/x/y") == "x/y")
    #expect(HostfsWatchers.relativeName(root: "/r", path: "/r") == "")
    #expect(HostfsWatchers.relativeName(root: "/r", path: "/rx/y") == nil)
  }

  @Test func mountSpecsParseLikeSliccNode() throws {
    #expect(HostFolder.parse("/a/b") == .init(path: "/a/b", name: nil, readonly: false))
    #expect(HostFolder.parse("/a/b:work") == .init(path: "/a/b", name: "work", readonly: false))
    #expect(HostFolder.parse("/a/b:work:ro") == .init(path: "/a/b", name: "work", readonly: true))
    #expect(HostFolder.parse("/a/b:ro") == .init(path: "/a/b", name: nil, readonly: true))
    #expect(HostFolder.parse("C:/x") == .init(path: "C:/x", name: nil, readonly: false))
    let fixture = try Fixture.make()
    defer { fixture.remove() }
    var warnings: [String] = []
    let folders = HostFolder.load(
      [
        fixture.folder + ":work:ro", fixture.base + "/gone", fixture.docs + ":work",
        fixture.folder + "/hello.txt",
      ],
      warn: { warnings.append($0) })
    #expect(folders.map(\.name) == ["work"])
    #expect(folders.first?.readonly == true)
    #expect(folders.first?.root == fixture.folder)
    #expect(warnings.count == 3)
    #expect(warnings[0].hasSuffix("gone: not an existing folder, skipping"))
    #expect(warnings[1].hasSuffix("the name work is taken, skipping"))
  }
}
