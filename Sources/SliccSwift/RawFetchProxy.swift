import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import NIOHTTP1

struct RawFetchProxy: Sendable {
  let httpClient: HTTPClient
  var maxRequestBodyBytes = RawFetchProtocol.requestBodyCap
  var hostfs = false
  var kernel: KernelState?

  private static let requestHeader = HTTPField.Name(RawFetchProtocol.requestHeader)!
  private static let probeHeader = HTTPField.Name(RawFetchProtocol.probeHeader)!
  private static let upstreamTimeout: TimeAmount = .hours(24)

  static func makeHTTPClient() -> HTTPClient {
    var configuration = HTTPClient.Configuration()
    configuration.decompression = .disabled
    configuration.redirectConfiguration = .disallow
    configuration.connectionPool.retryConnectionEstablishment = false
    configuration.networkFrameworkWaitForConnectivity = false
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  }

  func respond(to request: Request) async throws -> Response {
    guard let encodedHead = request.headers[Self.requestHeader] else {
      if request.headers[Self.probeHeader] != nil { return probeResponse() }
      return try rawProxyError(
        status: .badRequest, message: "missing \(RawFetchProtocol.requestHeader) header")
    }
    do {
      return try await relay(request, encodedHead: encodedHead)
    } catch let refusal as Refusal {
      var response = try rawProxyError(status: refusal.status, message: refusal.message)
      if refusal.status == .contentTooLarge { response.headers[.connection] = "close" }
      return response
    }
  }

  private func probeResponse() -> Response {
    let json = RawFetchProtocol.probeReplyJSON(
      maxRequestBodyBytes: maxRequestBodyBytes, hostfs: hostfs, kernelPort: kernel?.port)
    return Response(
      status: .ok,
      headers: [.contentType: "application/json", .cacheControl: "no-store"],
      body: .init(byteBuffer: ByteBuffer(string: json))
    )
  }

  private struct Refusal: Error {
    let status: HTTPResponse.Status
    let message: String
  }

  private func relay(_ request: Request, encodedHead: String) async throws -> Response {
    guard let head = RawFetchProtocol.decodeRequestHead(encodedHead), Self.isHTTPURL(head.url)
    else {
      throw Refusal(
        status: .badRequest, message: "malformed \(RawFetchProtocol.requestHeader) header")
    }
    let body = try await readBody(request)
    var upstreamRequest = HTTPClientRequest(url: head.url)
    upstreamRequest.method = HTTPMethod(rawValue: head.method)
    upstreamRequest.headers = try upstreamHeaders(head)
    let method = head.method.uppercased()
    if body.readableBytes > 0, method != "GET", method != "HEAD" {
      upstreamRequest.body = .bytes(body)
    }
    let upstream: HTTPClientResponse
    do {
      upstream = try await httpClient.execute(upstreamRequest, timeout: Self.upstreamTimeout)
    } catch {
      throw Refusal(status: .badGateway, message: "fetch failed: \(error)")
    }
    return try frame(upstream, for: head)
  }

  private static func isHTTPURL(_ url: String) -> Bool {
    guard let components = URLComponents(string: url),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      components.host?.isEmpty == false
    else { return false }
    return true
  }

  private func upstreamHeaders(_ head: RawFetchRequestHead) throws -> HTTPHeaders {
    let folded = RawFetchProtocol.foldRequestHeaders(
      RawFetchProtocol.stripRequestHeaders(head.headers))
    var headers = HTTPHeaders()
    for pair in folded {
      guard HTTPField.Name(pair.name) != nil, HTTPField.isValidValue(pair.value) else {
        throw Refusal(status: .badGateway, message: "fetch failed: invalid header \"\(pair.name)\"")
      }
      headers.add(name: pair.name, value: pair.value)
    }
    headers.add(name: "accept-encoding", value: RawFetchProtocol.acceptEncoding(for: folded))
    return headers
  }

  private func readBody(_ request: Request) async throws -> ByteBuffer {
    let tooLarge = Refusal(
      status: .contentTooLarge, message: "request body exceeds \(maxRequestBodyBytes) bytes")
    if let declared = request.headers[.contentLength].flatMap(Int.init),
      declared > maxRequestBodyBytes
    {
      throw tooLarge
    }
    do {
      return try await request.body.collect(upTo: maxRequestBodyBytes)
    } catch let error as HTTPError where error.status == .contentTooLarge {
      throw tooLarge
    }
  }

  private func frame(_ upstream: HTTPClientResponse, for head: RawFetchRequestHead) throws
    -> Response
  {
    let status = Int(upstream.status.code)
    let upstreamHeaders = upstream.headers.map { RawHeaderPair($0.name.lowercased(), $0.value) }
    if RawFetchProtocol.isDecodedPartial(status: status, headers: upstreamHeaders) {
      throw Refusal(
        status: .badGateway,
        message: "upstream answered a range request with an encoded partial body")
    }
    let hasBody = RawFetchProtocol.responseHasBody(method: head.method, status: status)
    let headers = RawFetchProtocol.responseHeaders(
      method: head.method, status: status, headers: upstreamHeaders)
    let frame = RawFetchProtocol.encodeResponseFrame(
      RawFetchResponseHead(
        status: status, statusText: upstream.status.reasonPhrase, headers: headers, url: head.url)
    )
    let codings =
      RawFetchProtocol.isDecoded(upstreamHeaders) ? RawFetchProtocol.codings(upstreamHeaders) : []
    let body = hasBody ? DecodedBody(upstream: upstream.body, codings: codings) : nil
    return Response(
      status: .ok,
      headers: [.contentType: RawFetchProtocol.contentType, .cacheControl: "no-store"],
      body: ResponseBody(asyncSequence: FramedBody(frame: ByteBuffer(bytes: frame), body: body))
    )
  }
}

struct FramedBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let frame: ByteBuffer
  let body: DecodedBody?

  struct AsyncIterator: AsyncIteratorProtocol {
    var frame: ByteBuffer?
    var body: DecodedBody.AsyncIterator?

    mutating func next() async throws -> ByteBuffer? {
      if let pending = frame {
        frame = nil
        return pending
      }
      return try await body?.next()
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(frame: frame, body: body?.makeAsyncIterator())
  }
}

func rawProxyError(status: HTTPResponse.Status, message: String) throws -> Response {
  let data = try JSONSerialization.data(withJSONObject: ["error": message])
  return Response(
    status: status,
    headers: [
      .contentType: "application/json",
      HTTPField.Name(RawFetchProtocol.errorHeader)!: "1",
    ],
    body: .init(byteBuffer: ByteBuffer(data: data))
  )
}
