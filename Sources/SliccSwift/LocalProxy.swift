import AsyncHTTPClient
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import ServiceLifecycle

public struct LocalProxy: Sendable {
  public static let defaultPage = "https://seven.sliccy.ai/"

  public static let host = "127.0.0.1"

  public var port: Int
  public let portFallback: Bool
  public let key: String
  public let extraOrigins: Set<String>
  public let folders: [HostFolder]
  public let kernelPort: Int?
  public let cdp: String?
  public let log: @Sendable (String) -> Void
  public let warn: @Sendable (String) -> Void
  var hostfsIdle = HostfsProtocol.grantIdle
  var hostfsPing = HostfsProtocol.pingInterval
  var kernelOpenTimeout = KernelProtocol.openTimeout
  var tunnelPing = KernelProtocol.pingInterval
  var cdpReconnectDelay = CDPProtocol.reconnectDelay

  public init(
    port: Int = 0,
    portFallback: Bool = false,
    key: String = ProxySecurity.mintKey(),
    extraOrigins: Set<String> = ProxySecurity.parseOrigins(
      ProcessInfo.processInfo.environment[ProxySecurity.devOriginsEnvironment]),
    folders: [HostFolder] = [],
    kernelPort: Int? = KernelProtocol.defaultPort,
    cdp: String? = nil,
    log: @escaping @Sendable (String) -> Void = { _ in },
    warn: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.port = port
    self.portFallback = portFallback
    self.key = key
    self.extraOrigins = extraOrigins
    self.folders = folders
    self.kernelPort = kernelPort
    self.cdp = cdp
    self.log = log
    self.warn = warn
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

  func makeRouter(httpClient: HTTPClient, gate: TunnelGate, hostfs: Hostfs) -> Router<
    BasicRequestContext
  > {
    let router = Router()
    router.add(
      middleware: ProxyGateMiddleware(key: key, extraOrigins: extraOrigins, port: gate.port))
    var proxy = RawFetchProxy(httpClient: httpClient, kernel: gate.kernel)
    proxy.hostfs = !hostfs.folders.isEmpty
    proxy.cdp = cdp != nil
    router.post(RouterPath(RawFetchProtocol.path)) { [proxy] request, _ in
      try await proxy.respond(to: request)
    }
    router.post(RouterPath(HostfsProtocol.grantPath)) { request, _ in await hostfs.grant(request) }
    router.delete(RouterPath(HostfsProtocol.grantPath)) { request, _ in
      await hostfs.grant(request)
    }
    router.post(RouterPath(HostfsProtocol.mountsPath)) { _, _ in hostfs.mounts() }
    router.post(RouterPath(HostfsProtocol.path)) { request, _ in
      try await hostfs.handle(request, path: HostfsProtocol.path)
    }
    router.put(RouterPath(HostfsProtocol.writePath)) { request, _ in
      try await hostfs.handle(request, path: HostfsProtocol.writePath)
    }
    router.post(RouterPath(HostfsProtocol.watchPath)) { request, _ in
      try await hostfs.handle(request, path: HostfsProtocol.watchPath)
    }
    return router
  }

  func makeApplication(
    httpClient: HTTPClient,
    logLevel: Logger.Level = .warning,
    onReady: @escaping @Sendable (_ proxyURL: String, _ kernelPort: Int?) async -> Void
  ) -> some ApplicationProtocol {
    let host = Self.host
    let boundPort = BoundPort()
    var logger = Logger(label: "slicc-swift")
    logger.logLevel = logLevel
    let hostfs = Hostfs(folders: folders, idle: hostfsIdle, pingInterval: hostfsPing, log: log)
    let kernel = KernelState()
    let gate = TunnelGate(
      key: key, extraOrigins: extraOrigins, port: boundPort, kernel: kernel, cdp: cdp != nil)
    let tunnels = KernelTunnels(log: log, openTimeout: kernelOpenTimeout)
    let listener = KernelListener(
      port: kernelPort, tunnels: tunnels, state: kernel, log: log, warn: warn)
    let browser = cdp.map {
      CDPProxy(httpClient: httpClient, browser: $0, reconnectDelay: cdpReconnectDelay, log: log)
    }
    var services: [any Service] = [HostfsService(hostfs: hostfs), listener]
    if let browser { services.append(CDPService(proxy: browser)) }
    return Application(
      router: makeRouter(httpClient: httpClient, gate: gate, hostfs: hostfs),
      server: KernelTunnelChannel.builder(
        gate: gate, tunnels: tunnels, ping: tunnelPing, cdp: browser),
      configuration: .init(address: .hostname(host, port: port)),
      services: services,
      onServerRunning: { channel in
        boundPort.value = channel.localAddress?.port ?? 0
        await onReady("http://\(host):\(boundPort.value)", await kernel.settled())
      },
      logger: logger
    )
  }

  public func run(onReady: @escaping @Sendable (_ proxyURL: String) async -> Void = { _ in })
    async throws
  {
    try await run(onListening: { proxyURL, _ in await onReady(proxyURL) })
  }

  public func run(
    onListening: @escaping @Sendable (_ proxyURL: String, _ kernelPort: Int?) async -> Void
  ) async throws {
    let httpClient = RawFetchProxy.makeHTTPClient()
    do {
      do {
        try await makeApplication(httpClient: httpClient, onReady: onListening).runService()
      } catch  where portFallback && port != 0 && Self.addressInUse(error) {
        warn(
          "port \(port) is taken; using a free port, so pages from an earlier launch cannot reconnect"
        )
        var fallback = self
        fallback.port = 0
        try await fallback.makeApplication(httpClient: httpClient, onReady: onListening)
          .runService()
      }
    } catch {
      try? await httpClient.shutdown()
      throw error
    }
    try await httpClient.shutdown()
  }

  public static func addressInUse(_ error: any Error) -> Bool {
    (error as? IOError)?.errnoCode == EADDRINUSE
  }
}
