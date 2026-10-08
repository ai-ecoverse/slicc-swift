import Foundation
import HTTPTypes

public enum ProxySecurity {
  public static let keyHeader = "X-Bridge-Token"
  public static let devOriginsEnvironment = "SLICC_PROXY_ALLOWED_ORIGINS"

  static let allowHeaders = [
    "Content-Type", keyHeader, RawFetchProtocol.requestHeader, RawFetchProtocol.probeHeader,
    HostfsProtocol.tokenHeader, HostfsProtocol.requestHeader,
  ].joined(separator: ", ")
  static let exposeHeaders = [
    RawFetchProtocol.errorHeader, HostfsProtocol.errnoHeader, "ETag", "Content-Range",
  ].joined(separator: ", ")
  static let allowMethods = "GET, POST, PUT, DELETE, OPTIONS"
  static let gatedPaths = [RawFetchProtocol.path: ["POST"]]
    .merging(HostfsProtocol.keyPaths) { $1 }
    .merging(HostfsProtocol.tokenPaths) { $1 }
  static let preflightMaxAge = "600"

  private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]
  private static let labelCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

  public static func mintKey() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func parseOrigins(_ raw: String?) -> Set<String> {
    Set((raw ?? "").split(separator: ",").compactMap { normalizeOrigin(String($0)) })
  }

  static func normalizeOrigin(_ raw: String) -> String? {
    var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while candidate.hasSuffix("/") { candidate = String(candidate.dropLast()) }
    guard let components = URLComponents(string: candidate),
      let scheme = components.scheme, scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty,
      components.path.isEmpty, components.query == nil, components.fragment == nil,
      components.user == nil, components.password == nil
    else { return nil }
    return candidate
  }

  public static func isHostedOrigin(_ origin: String) -> Bool {
    let prefix = "https://"
    let suffix = ".sliccy.ai"
    guard origin.hasPrefix(prefix), origin.hasSuffix(suffix) else { return false }
    let label = origin.dropFirst(prefix.count).dropLast(suffix.count)
    guard (1...63).contains(label.count), label != "www",
      label.allSatisfy({ labelCharacters.contains($0) }),
      label.first != "-", label.last != "-"
    else { return false }
    return true
  }

  static func isAllowedOrigin(_ origin: String?, extraOrigins: Set<String>) -> Bool {
    guard let origin else { return false }
    if isHostedOrigin(origin) { return true }
    guard let normalized = normalizeOrigin(origin) else { return false }
    return extraOrigins.contains(normalized)
  }

  static func isLoopbackHost(_ host: String?, port: Int) -> Bool {
    guard let host, let colon = host.lastIndex(of: ":"), colon > host.startIndex else {
      return false
    }
    guard host[host.index(after: colon)...] == String(port) else { return false }
    return loopbackHosts.contains(host[..<colon].lowercased())
  }

  static func validateKey(_ presented: String?, _ expected: String) -> Bool {
    guard !expected.isEmpty, let presented, !presented.isEmpty else { return false }
    let a = Array(presented.utf8)
    let b = Array(expected.utf8)
    if a.count != b.count { return false }
    var diff: UInt8 = 0
    for index in a.indices { diff |= a[index] ^ b[index] }
    return diff == 0
  }

  static func corsHeaders(origin: String) -> HTTPFields {
    var fields = HTTPFields()
    fields[HTTPField.Name("Access-Control-Allow-Origin")!] = origin
    fields[HTTPField.Name("Access-Control-Expose-Headers")!] = exposeHeaders
    fields[HTTPField.Name("Vary")!] = "Origin"
    return fields
  }

  static func preflightHeaders(origin: String, privateNetwork: Bool) -> HTTPFields {
    var fields = corsHeaders(origin: origin)
    fields[HTTPField.Name("Access-Control-Allow-Methods")!] = allowMethods
    fields[HTTPField.Name("Access-Control-Allow-Headers")!] = allowHeaders
    fields[HTTPField.Name("Access-Control-Max-Age")!] = preflightMaxAge
    if privateNetwork { fields[HTTPField.Name("Access-Control-Allow-Private-Network")!] = "true" }
    return fields
  }
}
