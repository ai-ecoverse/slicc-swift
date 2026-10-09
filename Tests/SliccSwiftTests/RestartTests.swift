import AsyncHTTPClient
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import SliccSwift

final class BundleMarker {}

struct LaunchFailure: Error, CustomStringConvertible {
  let status: Int32
  let stderr: String

  var description: String { "exited with \(status): \(stderr)" }
}

final class Launched: Sendable {
  let process: Process
  let url: String
  let key: String
  private let errors: NIOLockedValueBox<String>

  init(process: Process, url: String, key: String, errors: NIOLockedValueBox<String>) {
    self.process = process
    self.url = url
    self.key = key
    self.errors = errors
  }

  var stderr: String { errors.withLockedValue { $0 } }
  var port: Int { Int(url.split(separator: ":").last ?? "") ?? 0 }

  func stop() async {
    process.terminate()
    while process.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
  }
}

func launch(_ arguments: [String], config: String?) async throws -> Launched {
  let binary = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("slicc-swift")
  let process = Process()
  process.executableURL = binary
  let kernel = arguments.contains { $0.hasPrefix("--kernel") } ? [] : ["--no-kernel"]
  let identity = config == nil ? ["--ephemeral"] : []
  process.arguments = ["--no-open"] + kernel + identity + arguments
  var environment = ProcessInfo.processInfo.environment
  if let config { environment["XDG_CONFIG_HOME"] = config }
  process.environment = environment
  let output = Pipe()
  let error = Pipe()
  process.standardOutput = output
  process.standardError = error
  let lines = NIOLockedValueBox("")
  let errors = NIOLockedValueBox("")
  for (pipe, sink) in [(output, lines), (error, errors)] {
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      sink.withLockedValue { $0 += String(decoding: data, as: UTF8.self) }
    }
  }
  try process.run()
  for _ in 0..<1000 {
    let printed = lines.withLockedValue { $0 }.split(separator: "\n")
    if printed.count >= 2, let key = printed[1].components(separatedBy: "&key=").last {
      let url = String(printed[0].dropFirst("slicc-swift proxy on ".count))
      return Launched(process: process, url: url, key: key, errors: errors)
    }
    if !process.isRunning {
      try await Task.sleep(for: .milliseconds(50))
      throw LaunchFailure(status: process.terminationStatus, stderr: errors.withLockedValue { $0 })
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  process.terminate()
  throw LaunchFailure(status: -1, stderr: errors.withLockedValue { $0 })
}

func freePort() async throws -> Int {
  let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .bind(host: "127.0.0.1", port: 0).get()
  let port = channel.localAddress?.port ?? 0
  try await channel.close()
  return port
}

func temporaryDirectory() throws -> String {
  var bytes = Array((NSTemporaryDirectory() + "slicc-restart-XXXXXX").utf8CString)
  guard let made = mkdtemp(&bytes) else { throw HostfsError.posix(errno) }
  return try HostfsFileSystem.realPath(String(cString: made))
}

func permissions(_ path: String) throws -> Int {
  (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
}

func readText(_ path: String) throws -> String {
  try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite(.serialized) struct RestartTests {
  func call(
    _ client: HTTPClient, _ url: String, _ path: String, headers: [(String, String)],
    body: String? = nil
  ) async throws -> (Int, [UInt8]) {
    var request = HTTPClientRequest(url: url + path)
    request.method = .POST
    request.headers.add(name: "Origin", value: hostedOrigin)
    for (name, value) in headers { request.headers.add(name: name, value: value) }
    if let body { request.body = .bytes(ByteBuffer(string: body)) }
    let response = try await client.execute(request, timeout: .seconds(10))
    let bytes = try await response.body.collect(upTo: 1 << 20)
    return (Int(response.status.code), Array(bytes.readableBytesView))
  }

  func fetched(_ harness: Harness, _ url: String, _ key: String) async throws -> String {
    let head = rawHead(harness.upstream + "/hello")
    let (status, bytes) = try await call(
      harness.client, url, RawFetchProtocol.path,
      headers: [(ProxySecurity.keyHeader, key), (RawFetchProtocol.requestHeader, head)])
    guard status == 200 else { return String(status) }
    return try decodeFrame(bytes).text
  }

  func grant(_ harness: Harness, _ url: String, _ key: String) async throws -> (Int, String?) {
    let (status, bytes) = try await call(
      harness.client, url, HostfsProtocol.grantPath, headers: [(ProxySecurity.keyHeader, key)],
      body: "{\"mount\":\"project\"}")
    let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    return (status, object?["token"] as? String)
  }

  func stat(_ harness: Harness, _ url: String, _ token: String) async throws -> Int {
    try await call(
      harness.client, url, HostfsProtocol.path, headers: [(HostfsProtocol.tokenHeader, token)],
      body: "{\"op\":\"stat\",\"path\":\"hello.txt\"}"
    ).0
  }

  @Test func aRestartedProxyKeepsItsKeyAndPortSoThePageReconnects() async throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: base) }
    let config = base + "/config"
    let folder = base + "/project"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
    try Data("hello".utf8).write(to: URL(fileURLWithPath: folder + "/hello.txt"))
    try await withHarness { harness in
      let arguments = ["--port", String(try await freePort()), "--mount", folder + ":project"]
      let first = try await launch(arguments, config: config)
      #expect(try await fetched(harness, first.url, first.key) == "hello")
      let (granted, token) = try await grant(harness, first.url, first.key)
      #expect(granted == 200)
      let old = try #require(token)
      #expect(try await stat(harness, first.url, old) == 200)
      await first.stop()

      let second = try await launch(arguments, config: config)
      #expect(second.url == first.url)
      #expect(second.key == first.key)
      #expect(try await fetched(harness, first.url, first.key) == "hello")
      #expect(try await stat(harness, first.url, old) == 403)
      let (regranted, fresh) = try await grant(harness, first.url, first.key)
      #expect(regranted == 200)
      #expect(try await stat(harness, first.url, try #require(fresh)) == 200)
      await second.stop()

      let directory = config + "/slicc-swift"
      #expect(try readText(directory + "/key") == first.key)
      #expect(try permissions(directory + "/key") == 0o600)
      #expect(try permissions(directory) == 0o700)
    }
  }

  @Test func rotateKeyReplacesTheKeyAndEphemeralLeavesItAlone() async throws {
    let config = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: config) }
    let port = String(try await freePort())
    let kept = try await launch(["--port", port], config: config)
    await kept.stop()
    let rotated = try await launch(["--port", port, "--rotate-key"], config: config)
    await rotated.stop()
    #expect(rotated.key != kept.key)
    #expect(ProxyIdentity.isKey(rotated.key))
    let file = config + "/slicc-swift/key"
    #expect(try readText(file) == rotated.key)
    let ephemeral = try await launch(["--ephemeral"], config: config)
    await ephemeral.stop()
    #expect(ephemeral.key != rotated.key)
    #expect(ephemeral.port != ProxyIdentity.defaultPort)
    #expect(try readText(file) == rotated.key)
  }

  @Test func aBrokenOrLooseKeyFileIsRepaired() async throws {
    let config = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: config) }
    let directory = config + "/slicc-swift"
    let file = directory + "/key"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try Data("not a key\n".utf8).write(to: URL(fileURLWithPath: file))
    let port = String(try await freePort())
    let fresh = try await launch(["--port", port], config: config)
    await fresh.stop()
    #expect(fresh.stderr.contains("does not hold a proxy key; minting a new one"))
    #expect(try readText(file) == fresh.key)
    chmod(file, 0o644)
    chmod(directory, 0o777)
    let tightened = try await launch(["--port", port], config: config)
    await tightened.stop()
    #expect(tightened.key == fresh.key)
    #expect(tightened.stderr.contains("\(file) was readable by others; it is 0600 now"))
    #expect(tightened.stderr.contains("\(directory) was open to others; it is 0700 now"))
    #expect(try permissions(file) == 0o600)
    #expect(try permissions(directory) == 0o700)
    chmod(directory, 0o500)
    let owner = try await launch(["--port", port], config: config)
    await owner.stop()
    #expect(owner.key == fresh.key)
    #expect(!owner.stderr.contains("was open to others"))
    #expect(try permissions(directory) == 0o700)
  }

  @Test func theDefaultPortIsFixedWithAFreePortAsFallback() async throws {
    let config = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: config) }
    let blocker = try? await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .bind(host: "127.0.0.1", port: ProxyIdentity.defaultPort).get()
    let fallback = try await launch([], config: config)
    await fallback.stop()
    #expect(fallback.port != ProxyIdentity.defaultPort)
    #expect(
      fallback.stderr.contains(
        "port \(ProxyIdentity.defaultPort) is taken; using a free port, so pages from an earlier launch cannot reconnect"
      ))
    guard let blocker else { return }
    try await blocker.close()
    let fixed = try await launch([], config: config)
    await fixed.stop()
    #expect(fixed.port == ProxyIdentity.defaultPort)
  }

  @Test func anExplicitPortThatIsTakenStopsTheLauncher() async throws {
    let config = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: config) }
    let blocker = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .bind(host: "127.0.0.1", port: 0).get()
    let taken = try #require(blocker.localAddress?.port)
    do {
      _ = try await launch(["--port", String(taken)], config: config)
      Issue.record("a taken --port should stop the launcher")
    } catch let failure as LaunchFailure {
      #expect(failure.status == 1)
      #expect(failure.stderr.contains("EADDRINUSE"))
    }
    do {
      _ = try await launch(["--ephemeral", "--rotate-key"], config: config)
      Issue.record("--ephemeral with --rotate-key should stop the launcher")
    } catch let failure as LaunchFailure {
      #expect(failure.status == 2)
    }
    try await blocker.close()
  }

  @Test func twoFirstStartsAtOnceAgreeOnOneStoredKey() async throws {
    let config = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(atPath: config) }
    let ports = [try await freePort(), try await freePort()]
    async let one = launch(["--port", String(ports[0])], config: config)
    async let two = launch(["--port", String(ports[1])], config: config)
    let (first, second) = try await (one, two)
    await first.stop()
    await second.stop()
    #expect(first.key == second.key)
    #expect(try readText(config + "/slicc-swift/key") == first.key)
    #expect(try FileManager.default.contentsOfDirectory(atPath: config + "/slicc-swift") == ["key"])
  }

  @Test func theConfigDirectoryFollowsXDGAndThePlatform() {
    #expect(
      ProxyIdentity.configDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path
        == "/tmp/xdg/slicc-swift")
    #expect(
      ProxyIdentity.configDirectory(environment: [:]).path.hasSuffix(
        "Library/Application Support/slicc-swift"))
  }
}
