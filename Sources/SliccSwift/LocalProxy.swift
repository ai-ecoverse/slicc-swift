import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore

public struct LocalProxy: Sendable {
  public static let defaultPage = "https://seven.sliccy.ai/"

  public static let host = "127.0.0.1"

  static var server: HTTPServerBuilder {
    .http1(
      configuration: .init(
        httpDecoderConfiguration: .init(
          maxHeaderFieldSize: RawFetchProtocol.maxHeaderBytes,
          maxHeaderListSize: RawFetchProtocol.maxHeaderBytes
        )
      )
    )
  }

  public let port: Int
  public let key: String
  public let extraOrigins: Set<String>

  public init(
    port: Int = 0,
    key: String = ProxySecurity.mintKey(),
    extraOrigins: Set<String> = ProxySecurity.parseOrigins(
      ProcessInfo.processInfo.environment[ProxySecurity.devOriginsEnvironment])
  ) {
    self.port = port
    self.key = key
    self.extraOrigins = extraOrigins
  }

  public static func launchURL(page: String = defaultPage, proxyURL: String, key: String) -> String
  {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "*-._")
    let encode = { (value: String) in
      value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    let base = page.split(separator: "#", maxSplits: 1).first.map(String.init) ?? page
    return "\(base)#proxy=\(encode(proxyURL))&key=\(encode(key))"
  }

  func makeRouter(httpClient: HTTPClient, port: BoundPort) -> Router<BasicRequestContext> {
    let router = Router()
    router.add(middleware: ProxyGateMiddleware(key: key, extraOrigins: extraOrigins, port: port))
    let proxy = RawFetchProxy(httpClient: httpClient)
    router.post(RouterPath(RawFetchProtocol.path)) { request, _ in
      try await proxy.respond(to: request)
    }
    return router
  }

  func makeApplication(
    httpClient: HTTPClient,
    logLevel: Logger.Level = .warning,
    onReady: @escaping @Sendable (_ proxyURL: String) async -> Void
  ) -> some ApplicationProtocol {
    let host = Self.host
    let boundPort = BoundPort()
    var logger = Logger(label: "slicc-swift")
    logger.logLevel = logLevel
    return Application(
      router: makeRouter(httpClient: httpClient, port: boundPort),
      server: Self.server,
      configuration: .init(address: .hostname(host, port: port)),
      onServerRunning: { channel in
        boundPort.value = channel.localAddress?.port ?? 0
        await onReady("http://\(host):\(boundPort.value)")
      },
      logger: logger
    )
  }

  public func run(onReady: @escaping @Sendable (_ proxyURL: String) async -> Void = { _ in })
    async throws
  {
    let httpClient = RawFetchProxy.makeHTTPClient()
    do {
      try await makeApplication(httpClient: httpClient, onReady: onReady).runService()
    } catch {
      try? await httpClient.shutdown()
      throw error
    }
    try await httpClient.shutdown()
  }
}
