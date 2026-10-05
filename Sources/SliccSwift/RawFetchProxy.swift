import AsyncHTTPClient
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import NIOHTTP1

struct RawFetchProxy: Sendable {
  let httpClient: HTTPClient
  var maxRequestBodyBytes = RawFetchProtocol.requestBodyCap

  private static let requestHeader = HTTPField.Name(RawFetchProtocol.requestHeader)!
  private static let probeHeader = HTTPField.Name(RawFetchProtocol.probeHeader)!
  private static let transferEncoding = HTTPField.Name("Transfer-Encoding")!
  private static let upstreamTimeout: TimeAmount = .hours(24)

  static func makeHTTPClient() -> HTTPClient {
    var configuration = HTTPClient.Configuration()
    configuration.decompression = .enabled(limit: .none)
    configuration.redirectConfiguration = .disallow
    configuration.connectionPool.retryConnectionEstablishment = false
    configuration.networkFrameworkWaitForConnectivity = false
    return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  }

  func respond(to request: Request) async throws -> Response {
    guard let encodedHead = request.headers[Self.requestHeader] else {
      if request.headers[Self.probeHeader] != nil { return try probeResponse() }
      return try rawProxyError(
        status: .badRequest,
        message: "missing \(RawFetchProtocol.requestHeader) header"
      )
    }
    return try await relay(request, encodedHead: encodedHead)
  }

  private func probeResponse() throws -> Response {
    let json = RawFetchProtocol.probeReplyJSON(maxRequestBodyBytes: maxRequestBodyBytes)
    return Response(
      status: .ok,
      headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
      body: .init(byteBuffer: ByteBuffer(string: json))
    )
  }

  private enum Upload {
    case buffered(ByteBuffer)
    case streamed(RequestBody, declaredLength: Int?)
  }

  private struct Refusal: Error {
    let status: HTTPResponse.Status
    let message: String
  }

  private func relay(_ request: Request, encodedHead: String) async throws -> Response {
    do {
      guard let head = RawFetchProtocol.decodeRequestHead(encodedHead) else {
        throw Refusal(
          status: .badRequest, message: "Malformed \(RawFetchProtocol.requestHeader) header")
      }
      let upstreamRequest = try await prepareUpstream(request, head: head)
      let upstream: HTTPClientResponse
      do {
        upstream = try await httpClient.execute(upstreamRequest, timeout: Self.upstreamTimeout)
      } catch {
        throw Refusal(status: .badGateway, message: "Proxy fetch failed: \(error)")
      }
      return try frame(upstream, for: head)
    } catch let refusal as Refusal {
      var response = try rawProxyError(status: refusal.status, message: refusal.message)
      if refusal.status == .contentTooLarge { response.headers[.connection] = "close" }
      return response
    }
  }

  private func prepareUpstream(_ request: Request, head: RawFetchRequestHead) async throws
    -> HTTPClientRequest
  {
    guard var target = URLComponents(string: head.url), let scheme = target.scheme?.lowercased(),
      scheme == "http" || scheme == "https", target.host?.isEmpty == false
    else {
      throw Refusal(status: .badRequest, message: "Unsupported URL \"\(head.url)\"")
    }
    let credentials = target.user.map { user in "\(user):\(target.password ?? "")" }
    target.user = nil
    target.password = nil
    let folded = RawFetchProtocol.foldRequestHeaders(
      RawFetchProtocol.stripRequestHeaders(head.headers))
    var headers = HTTPHeaders()
    for pair in folded {
      guard HTTPField.Name(pair.name) != nil else {
        throw Refusal(status: .badRequest, message: "Invalid header name \"\(pair.name)\"")
      }
      headers.add(name: pair.name, value: pair.value)
    }
    headers.replaceOrAdd(
      name: "accept-encoding", value: RawFetchProtocol.acceptEncoding(for: folded))

    if let credentials, !headers.contains(name: "authorization") {
      headers.add(
        name: "authorization", value: "Basic " + Data(credentials.utf8).base64EncodedString())
    }

    var upstream = HTTPClientRequest(url: target.string ?? head.url)
    upstream.method = HTTPMethod(rawValue: head.method)
    upstream.headers = headers
    switch try await readUpload(request, head: head) {
    case .streamed(let body, let declaredLength):
      upstream.body = .stream(body, length: declaredLength.map { .known(Int64($0)) } ?? .unknown)
    case .buffered(let body):
      let method = head.method.uppercased()
      if method != "GET", method != "HEAD", body.readableBytes > 0 { upstream.body = .bytes(body) }
    }
    return upstream
  }

  private func readUpload(_ request: Request, head: RawFetchRequestHead) async throws -> Upload {
    let method = head.method.uppercased()
    let chunked =
      request.headers[.contentLength] == nil && request.headers[Self.transferEncoding] != nil
    if chunked, method != "GET", method != "HEAD" {
      return .streamed(request.body, declaredLength: declaredLength(head))
    }
    let tooLarge = Refusal(
      status: .contentTooLarge,
      message: "Request body exceeds the \(maxRequestBodyBytes) byte limit of this proxy"
    )
    if let declared = request.headers[.contentLength].flatMap(Int.init),
      declared > maxRequestBodyBytes
    {
      throw tooLarge
    }
    do {
      return .buffered(try await request.body.collect(upTo: maxRequestBodyBytes))
    } catch let error as HTTPError where error.status == .contentTooLarge {
      throw tooLarge
    }
  }

  private func declaredLength(_ head: RawFetchRequestHead) -> Int? {
    head.headers.first { $0.name.lowercased() == "content-length" }
      .flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) }
      .flatMap { $0 >= 0 ? $0 : nil }
  }

  private func frame(_ upstream: HTTPClientResponse, for head: RawFetchRequestHead) throws
    -> Response
  {
    let status = Int(upstream.status.code)
    let upstreamHeaders = upstream.headers.map { RawHeaderPair($0.name.lowercased(), $0.value) }
    let hasBody = RawFetchProtocol.responseHasBody(method: head.method, status: status)
    let decoding = RawFetchProtocol.upstreamDecoding(upstreamHeaders)
    let decodedCodings = decoding == .decoded ? RawFetchProtocol.decodedCodings : []
    if hasBody, decoding == .partiallyDecoded {
      throw Refusal(
        status: .badGateway, message: "Upstream stacked a content coding this proxy cannot undo")
    }
    if RawFetchProtocol.isDecodedPartialResponse(
      status: status, headers: upstreamHeaders, decodedCodings: decodedCodings)
    {
      throw Refusal(
        status: .badGateway,
        message: "Upstream answered a range request with an encoded partial body")
    }
    let contentType = upstreamHeaders.first { $0.name == "content-type" }?.value ?? ""
    let isText = isTextContentType(contentType)
    let headers = RawFetchProtocol.responseHeaders(
      method: head.method,
      status: status,
      headers: upstreamHeaders,
      bodyRewritten: isText,
      decodedCodings: decodedCodings
    )
    let frame = RawFetchProtocol.encodeResponseFrame(
      RawFetchResponseHead(
        status: status, statusText: upstream.status.reasonPhrase, headers: headers, url: head.url)
    )
    let body = hasBody ? GunzipSniffingBody(upstream: upstream.body, sniff: isText) : nil
    return Response(
      status: .ok,
      headers: [.contentType: RawFetchProtocol.contentType, .cacheControl: "no-store, no-cache"],
      body: ResponseBody(asyncSequence: FramedBody(frame: ByteBuffer(bytes: frame), body: body))
    )
  }
}

struct GunzipSniffingBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let upstream: HTTPClientResponse.Body
  let sniff: Bool

  struct AsyncIterator: AsyncIteratorProtocol {
    var inner: HTTPClientResponse.Body.AsyncIterator
    var gzip: MaybeGunzipState<HTTPClientResponse.Body.AsyncIterator>

    mutating func next() async throws -> ByteBuffer? {
      try await gzip.next(from: &inner)
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(inner: upstream.makeAsyncIterator(), gzip: MaybeGunzipState(enabled: sniff))
  }
}

struct FramedBody: AsyncSequence, Sendable {
  typealias Element = ByteBuffer
  let frame: ByteBuffer
  let body: GunzipSniffingBody?

  struct AsyncIterator: AsyncIteratorProtocol {
    var frame: ByteBuffer?
    var body: GunzipSniffingBody.AsyncIterator?

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
      .contentType: "application/json; charset=utf-8",
      HTTPField.Name(RawFetchProtocol.errorHeader)!: "1",
    ],
    body: .init(byteBuffer: ByteBuffer(data: data))
  )
}
