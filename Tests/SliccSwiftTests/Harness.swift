import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import NIOHTTP1
import ServiceLifecycle
import Testing
import zlib

@testable import SliccSwift

let testKey = "integration-test-key"
let hostedOrigin = "https://seven.sliccy.ai"

struct RawReply {
  let status: Int
  let statusText: String
  let headers: [(String, String)]
  let url: String
  let body: [UInt8]

  func values(_ name: String) -> [String] {
    headers.filter { $0.0 == name }.map(\.1)
  }

  var text: String { String(decoding: body, as: UTF8.self) }
}

func decodeFrame(_ bytes: [UInt8]) throws -> RawReply {
  try #require(bytes.count >= 4)
  let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
  try #require(bytes.count >= 4 + length)
  let json = Data(bytes[4..<(4 + length)])
  let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
  let pairs = try #require(object["headers"] as? [[String]])
  return RawReply(
    status: try #require(object["status"] as? Int),
    statusText: try #require(object["statusText"] as? String),
    headers: pairs.map { ($0[0], $0[1]) },
    url: try #require(object["url"] as? String),
    body: Array(bytes[(4 + length)...])
  )
}

func rawHead(_ url: String, method: String = "GET", headers: [(String, String)] = []) -> String {
  let pairs = headers.map { [$0.0, $0.1] }
  let object: [String: Any] = ["url": url, "method": method, "headers": pairs]
  let data = try! JSONSerialization.data(withJSONObject: object)
  return String(decoding: data, as: UTF8.self)
}

func compress(_ input: [UInt8], windowBits: Int32) -> [UInt8] {
  var stream = z_stream()
  deflateInit2_(
    &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, zlibVersion(),
    Int32(MemoryLayout<z_stream>.size))
  var output = [UInt8](repeating: 0, count: input.count + 1024)
  var source = input
  let produced = source.withUnsafeMutableBufferPointer { inBuf in
    output.withUnsafeMutableBufferPointer { outBuf in
      stream.next_in = inBuf.baseAddress
      stream.avail_in = uInt(inBuf.count)
      stream.next_out = outBuf.baseAddress
      stream.avail_out = uInt(outBuf.count)
      deflate(&stream, Z_FINISH)
      return outBuf.count - Int(stream.avail_out)
    }
  }
  deflateEnd(&stream)
  return Array(output[0..<produced])
}

func gzip(_ input: [UInt8]) -> [UInt8] { compress(input, windowBits: 31) }

let gzippedText = gzip(Array("compressed hello".utf8))
let brotliText: [UInt8] = [
  139, 5, 128, 98, 114, 111, 116, 108, 105, 32, 104, 101, 108, 108, 111, 3,
]
let stackedText: [UInt8] = [
  11, 16, 128, 31, 139, 8, 0, 0, 0, 0, 0, 0, 19, 43, 46, 73, 76, 206, 78, 77, 81, 200, 72, 205, 201,
  201, 7, 0, 53, 151, 214, 74, 13, 0, 0, 0, 3,
]

func encoded(_ coding: String, _ bytes: [UInt8], status: HTTPResponse.Status = .ok) -> Response {
  Response(
    status: status,
    headers: [.contentType: "text/plain", .contentEncoding: coding],
    body: .init(byteBuffer: ByteBuffer(bytes: bytes))
  )
}

func upstreamRouter() -> Router<BasicRequestContext> {
  let router = Router()
  router.get("hello") { _, _ in
    var headers = HTTPFields()
    headers[.contentType] = "text/plain; charset=utf-8"
    headers.append(HTTPField(name: .setCookie, value: "a=1; Path=/"))
    headers.append(HTTPField(name: .setCookie, value: "b=2; Path=/"))
    headers[HTTPField.Name("X-Custom")!] = "custom"
    return Response(
      status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: "hello")))
  }
  router.head("hello") { _, _ in
    Response(status: .ok, headers: [.contentType: "text/plain", .contentLength: "5"])
  }
  router.get("redirect") { _, _ in
    Response(status: .found, headers: [.location: "/hello"])
  }
  router.get("empty") { _, _ in
    Response(status: .noContent)
  }
  router.get("gzip") { _, _ in encoded("gzip", gzippedText) }
  router.head("gzip") { _, _ in
    Response(status: .ok, headers: [.contentEncoding: "gzip", .contentLength: "42"])
  }
  router.get("large") { _, _ in
    let chunks = AsyncStream<ByteBuffer> { continuation in
      for index in 0..<256 {
        continuation.yield(ByteBuffer(repeating: UInt8(index), count: 128 * 1024))
      }
      continuation.finish()
    }
    return Response(
      status: .ok,
      headers: [.contentType: "application/octet-stream"],
      body: ResponseBody(asyncSequence: chunks)
    )
  }
  router.get("bomb") { _, _ in encoded("gzip", gzip([UInt8](repeating: 0, count: 64 * 1024 * 1024)))
  }
  router.get("padded") { _, _ in encoded("gzip", gzippedText + [0, 0, 0]) }
  router.get("garbage") { _, _ in encoded("gzip", gzippedText + Array("junk".utf8)) }
  router.get("x-gzip") { _, _ in encoded("x-gzip", gzippedText) }
  router.get("members") { _, _ in
    encoded("gzip", gzippedText + gzip(Array(" and more".utf8)))
  }
  router.get("deflate") { _, _ in
    encoded("deflate", compress(Array("zlib hello".utf8), windowBits: 15))
  }
  router.get("raw-deflate") { _, _ in
    encoded("deflate", compress(Array("raw hello".utf8), windowBits: -15))
  }
  router.get("br") { _, _ in encoded("br", brotliText) }
  router.get("stacked") { _, _ in encoded("gzip, br", stackedText) }
  router.get("unknown") { _, _ in encoded("zstd", gzippedText) }
  router.get("partial") { _, _ in encoded("gzip", gzippedText, status: .partialContent) }
  router.get("sniff") { _, _ in
    Response(
      status: .ok,
      headers: [.contentType: "text/javascript"],
      body: .init(byteBuffer: ByteBuffer(bytes: gzippedText))
    )
  }
  router.get("headers") { request, _ in
    var seen: [String: String] = [:]
    for field in request.headers {
      let name = field.name.canonicalName
      seen[name] = seen[name].map { $0 + "|" + field.value } ?? field.value
    }
    let data = try JSONSerialization.data(withJSONObject: seen, options: .sortedKeys)
    return Response(
      status: .ok,
      headers: [.contentType: "application/octet-stream"],
      body: .init(byteBuffer: ByteBuffer(data: data))
    )
  }
  router.on("echo", method: .put) { request, _ in
    let body = try await request.body.collect(upTo: 64 * 1024 * 1024)
    return Response(
      status: .ok,
      headers: [
        .contentType: "application/octet-stream",
        HTTPField.Name("X-Received-Bytes")!: String(body.readableBytes),
        HTTPField.Name("X-Received-Chunked")!: request.headers[HTTPField.Name("Transfer-Encoding")!]
          ?? "no",
      ],
      body: .init(byteBuffer: body)
    )
  }
  router.post("echo") { request, _ in
    let body = try await request.body.collect(upTo: 64 * 1024 * 1024)
    return Response(
      status: .created,
      headers: [.contentType: "application/octet-stream"],
      body: .init(byteBuffer: body)
    )
  }
  return router
}

struct Harness {
  let upstream: String
  let proxy: String
  let client: HTTPClient

  func post(
    origin: String? = hostedOrigin,
    key: String? = testKey,
    headers extra: [(String, String)] = [],
    body: HTTPClientRequest.Body? = nil,
    method: NIOHTTP1.HTTPMethod = .POST,
    path: String = RawFetchProtocol.path
  ) async throws -> (HTTPClientResponse, [UInt8]) {
    var request = HTTPClientRequest(url: proxy + path)
    request.method = method
    if let origin { request.headers.add(name: "Origin", value: origin) }
    if let key { request.headers.add(name: ProxySecurity.keyHeader, value: key) }
    for (name, value) in extra { request.headers.add(name: name, value: value) }
    if let body { request.body = body }
    let response = try await client.execute(request, timeout: .seconds(30))
    let bytes = try await response.body.collect(upTo: 64 * 1024 * 1024)
    return (response, Array(bytes.readableBytesView))
  }

  func fetch(
    _ path: String,
    method: String = "GET",
    headers: [(String, String)] = [],
    body: HTTPClientRequest.Body? = nil
  ) async throws -> RawReply {
    let (response, bytes) = try await post(
      headers: [
        (RawFetchProtocol.requestHeader, rawHead(upstream + path, method: method, headers: headers))
      ],
      body: body
    )
    #expect(response.status == .ok)
    #expect(response.headers.first(name: "content-type") == RawFetchProtocol.contentType)
    return try decodeFrame(bytes)
  }
}

actor PortBox {
  private var port: Int?
  private var waiters: [CheckedContinuation<Int, Never>] = []

  func set(_ value: Int) {
    port = value
    for waiter in waiters { waiter.resume(returning: value) }
    waiters.removeAll()
  }

  func wait() async -> Int {
    if let port { return port }
    return await withCheckedContinuation { waiters.append($0) }
  }
}

func withHarness(extraOrigins: Set<String> = [], _ body: @Sendable (Harness) async throws -> Void)
  async throws
{
  let upstreamPort = PortBox()
  let proxyPort = PortBox()
  let upstream = Application(
    router: upstreamRouter(),
    server: LocalProxy.server,
    configuration: .init(address: .hostname("127.0.0.1", port: 0)),
    onServerRunning: { await upstreamPort.set($0.localAddress?.port ?? 0) },
    logger: quietLogger
  )
  let proxyClient = RawFetchProxy.makeHTTPClient()
  let proxy = LocalProxy(port: 0, key: testKey, extraOrigins: extraOrigins)
  let app = proxy.makeApplication(httpClient: proxyClient, logLevel: .critical) { url in
    await proxyPort.set(Int(url.split(separator: ":").last ?? "") ?? 0)
  }
  let client = HTTPClient(eventLoopGroupProvider: .singleton)
  let services = ServiceGroup(
    configuration: .init(
      services: [upstream, app], gracefulShutdownSignals: [], logger: quietLogger)
  )
  let outcome = try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await services.run() }
    let harness = Harness(
      upstream: "http://127.0.0.1:\(await upstreamPort.wait())",
      proxy: "http://127.0.0.1:\(await proxyPort.wait())",
      client: client
    )
    let result: Result<Void, any Error>
    do {
      try await body(harness)
      result = .success(())
    } catch {
      result = .failure(error)
    }
    await services.triggerGracefulShutdown()
    try await group.waitForAll()
    return result
  }
  try await client.shutdown()
  try await proxyClient.shutdown()
  try outcome.get()
}

let quietLogger: Logger = {
  var logger = Logger(label: "slicc-swift-tests")
  logger.logLevel = .critical
  return logger
}()
