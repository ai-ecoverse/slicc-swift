import Foundation

public enum CDPProtocol {
  public static let path = "/cdp"
  public static let cdpProtocol = "slicc.cdp.v1"
  public static let protocolVersion = 1
  public static let supersededCloseCode: UInt16 = 4001
  public static let supersededCloseReason = "superseded-by-new-cdp-client"
  public static let upstreamResetCloseCode: UInt16 = 4002
  public static let upstreamResetCloseReason = "upstream-reset"
  public static let upstreamResetFailureThreshold = 3
  public static let reconnectDelay: Duration = .seconds(1)
  static let maxMessage = 100 * 1024 * 1024
  static let hardFrameCap = 64 * 1024 * 1024
  static let inspectBytes = 256 * 1024
  static let bufferLimit = 1_000
  static let loopEventPrefixes = [
    "{\"method\":\"Network.webSocketFrameReceived\"",
    "{\"method\":\"Network.webSocketFrameSent\"",
  ]

  static func offeredKey(_ header: String?) -> String? {
    let offered = (header ?? "").split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard offered.contains(cdpProtocol) else { return nil }
    guard let key = offered.first(where: { $0.hasPrefix(KernelProtocol.keyProtocol) }) else {
      return ""
    }
    return String(key.dropFirst(KernelProtocol.keyProtocol.count))
  }

  public static func browserEndpoint(_ value: String?) throws -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host != nil
    else {
      throw CDPError.discoveryFailed("browser debugging URL must be http or https")
    }
    return url.absoluteString
  }

  static func versionURL(_ browser: String) -> String {
    guard let base = URL(string: browser) else { return browser }
    return URL(string: "/json/version", relativeTo: base)?.absoluteString ?? browser
  }

  static func refusal(origin: String?, protocols: String?, gate: TunnelGate) -> (
    status: Int, message: String
  )? {
    guard gate.cdp else { return (404, "not found") }
    guard ProxySecurity.isAllowedOrigin(origin, extraOrigins: gate.extraOrigins) else {
      return (403, "origin not allowed")
    }
    guard let key = offeredKey(protocols) else {
      return (400, "subprotocol \(cdpProtocol) missing")
    }
    guard ProxySecurity.validateKey(key, gate.key) else {
      return (403, "proxy key missing or wrong")
    }
    return nil
  }

  static func debuggerURL(_ body: Data) throws -> String {
    guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
      let url = json["webSocketDebuggerUrl"] as? String,
      url.hasPrefix("ws://") || url.hasPrefix("wss://")
    else {
      throw CDPError.discoveryFailed("no browser webSocketDebuggerUrl from CDP")
    }
    return url
  }

  static func endpoint(_ url: String) throws -> DebuggerEndpoint {
    guard let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
      scheme == "ws" || scheme == "wss", let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil
    else { throw CDPError.discoveryFailed("no browser webSocketDebuggerUrl from CDP") }
    var name = host
    if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
    let port = parts.port ?? (scheme == "wss" ? 443 : 80)
    guard (1...65535).contains(port) else {
      throw CDPError.discoveryFailed("no browser webSocketDebuggerUrl from CDP")
    }
    var uri = parts.percentEncodedPath
    if uri.isEmpty { uri = "/" }
    if let query = parts.percentEncodedQuery { uri += "?\(query)" }
    return DebuggerEndpoint(host: name, port: port, uri: uri, tls: scheme == "wss")
  }

  static func dropsChromeText(_ text: String) -> Bool {
    if text.utf8.count > hardFrameCap { return true }
    let head =
      text.utf8.count > inspectBytes
      ? String(decoding: text.utf8.prefix(inspectBytes), as: UTF8.self) : text
    return loopEventPrefixes.contains { head.hasPrefix($0) }
  }
}

struct DebuggerEndpoint: Equatable, Sendable {
  let host: String
  let port: Int
  let uri: String
  let tls: Bool
}

public enum CDPError: Error, Equatable, CustomStringConvertible {
  case discoveryFailed(String)

  public var description: String {
    switch self {
    case .discoveryFailed(let message): message
    }
  }
}

struct ClientFrameBufferGeneration: Equatable, Sendable {
  let chromeConnectionID: UUID?
  let clientID: UUID?
}

struct ClientFrameBuffer: Sendable {
  let generation: ClientFrameBufferGeneration
  var messages: [String] = []
}

enum ClientFrameBufferDropReason: String, Sendable {
  case chromeLegReset = "chrome-leg-reset"
  case clientSuperseded = "client-superseded"
  case clientDisconnected = "client-disconnected"
  case upstreamReset = "upstream-reset"
  case noClient = "no-client"
}

extension ClientFrameBuffer {
  static func dropReason(
    generation: ClientFrameBufferGeneration, chromeConnectionID: UUID?, clientID: UUID?
  ) -> ClientFrameBufferDropReason? {
    if let bufferedFor = generation.chromeConnectionID, bufferedFor != chromeConnectionID {
      return .chromeLegReset
    }
    guard let clientID else { return .noClient }
    if generation.clientID != clientID { return .clientSuperseded }
    return nil
  }
}
