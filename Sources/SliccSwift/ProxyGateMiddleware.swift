import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore

final class BoundPort: Sendable {
  private let box = NIOLockedValueBox(0)

  var value: Int {
    get { box.withLockedValue { $0 } }
    set { box.withLockedValue { $0 = newValue } }
  }
}

struct ProxyGateMiddleware<Context: RequestContext>: RouterMiddleware {
  let key: String
  let extraOrigins: Set<String>
  let port: BoundPort

  private static var keyHeader: HTTPField.Name { HTTPField.Name(ProxySecurity.keyHeader)! }
  private static var privateNetworkHeader: HTTPField.Name {
    HTTPField.Name("Access-Control-Request-Private-Network")!
  }

  func handle(
    _ request: Request,
    context: Context,
    next: (Request, Context) async throws -> Response
  ) async throws -> Response {
    guard ProxySecurity.isLoopbackHost(request.head.authority, port: port.value) else {
      return try rawProxyError(status: .forbidden, message: "host not allowed")
    }
    guard request.uri.path == RawFetchProtocol.path else {
      return try rawProxyError(status: .notFound, message: "not found")
    }
    guard let origin = request.headers[.origin],
      ProxySecurity.isAllowedOrigin(origin, extraOrigins: extraOrigins)
    else {
      return try rawProxyError(status: .forbidden, message: "origin not allowed")
    }
    if request.method == .options {
      let privateNetwork = request.headers[Self.privateNetworkHeader] == "true"
      return Response(
        status: .noContent,
        headers: ProxySecurity.preflightHeaders(origin: origin, privateNetwork: privateNetwork)
      )
    }
    let cors = ProxySecurity.corsHeaders(origin: origin)
    var response: Response
    if request.method != .post {
      response = try rawProxyError(status: .methodNotAllowed, message: "method not allowed")
      response.headers[.allow] = ProxySecurity.allowMethods
    } else if !ProxySecurity.validateKey(request.headers[Self.keyHeader], key) {
      response = try rawProxyError(status: .forbidden, message: "proxy key missing or wrong")
    } else {
      response = try await next(request, context)
    }
    for field in cors { response.headers[field.name] = field.value }
    return response
  }
}
