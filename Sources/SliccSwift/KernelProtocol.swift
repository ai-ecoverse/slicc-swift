import Foundation
import NIOCore

public enum KernelProtocol {
  public static let tunnelPath = "/api/kernel-tunnel"
  public static let tunnelProtocol = "slicc.kernel-tunnel.v1"
  public static let keyProtocol = "slicc.key."
  public static let tunnelVersion = 1
  public static let defaultPort = 80
  public static let window = 256 * 1024
  public static let chunk = 64 * 1024
  public static let maxMessage = 5 + chunk
  static let headLimit = 64 * 1024
  static let headTimeout: Duration = .seconds(30)
  static let openTimeout: Duration = .seconds(10)
  static let pingInterval: Duration = .seconds(15)

  enum Frame: UInt8 {
    case open = 1
    case opened = 2
    case data = 3
    case end = 4
    case reset = 5
    case credit = 6
  }

  static let statusText = [
    400: "Bad Request",
    421: "Misdirected Request",
    431: "Request Header Fields Too Large",
    502: "Bad Gateway",
    504: "Gateway Timeout",
  ]

  static func encode(_ type: Frame, _ id: UInt32, _ payload: ByteBuffer = ByteBuffer())
    -> ByteBuffer
  {
    var frame = ByteBuffer()
    frame.reserveCapacity(5 + payload.readableBytes)
    frame.writeInteger(type.rawValue)
    frame.writeInteger(id)
    frame.writeImmutableBuffer(payload)
    return frame
  }

  static func u16(_ value: Int) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt16(value))
    return buffer
  }

  static func u32(_ value: Int) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeInteger(UInt32(value))
    return buffer
  }

  struct Decoded {
    let type: UInt8
    let id: UInt32
    let payload: ByteBuffer
  }

  static func decode(_ message: ByteBuffer) -> Decoded? {
    var message = message
    guard let type = message.readInteger(as: UInt8.self),
      let id = message.readInteger(as: UInt32.self)
    else { return nil }
    return Decoded(type: type, id: id, payload: message)
  }

  static func valid(_ frame: Decoded) -> Bool {
    switch Frame(rawValue: frame.type) {
    case .opened, .end: return frame.payload.readableBytes == 0
    case .data: return frame.payload.readableBytes <= chunk
    case .reset: return true
    case .credit:
      return frame.payload.readableBytes == 4
        && (frame.payload.getInteger(at: frame.payload.readerIndex, as: UInt32.self) ?? 0) > 0
    default: return false
    }
  }

  static func reason(_ payload: ByteBuffer) -> String {
    let text = String(decoding: payload.readableBytesView, as: UTF8.self)
    let kept = String(
      String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7e).contains($0.value) }))
    return kept.isEmpty ? "reset" : String(kept.prefix(200))
  }

  static func offeredKey(_ header: String?) -> String? {
    let offered = (header ?? "").split(separator: ",", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard offered.contains(tunnelProtocol) else { return nil }
    guard let key = offered.first(where: { $0.hasPrefix(keyProtocol) }) else { return "" }
    return String(key.dropFirst(keyProtocol.count))
  }

  static func refusal(
    host: String?, path: String, origin: String?, protocols: String?, gate: TunnelGate
  ) -> (status: Int, message: String)? {
    guard ProxySecurity.isLoopbackHost(host, port: gate.port.value) else {
      return (403, "host not allowed")
    }
    guard path == tunnelPath, gate.kernel.port != nil else { return (404, "not found") }
    guard ProxySecurity.isAllowedOrigin(origin, extraOrigins: gate.extraOrigins) else {
      return (403, "origin not allowed")
    }
    guard let key = offeredKey(protocols) else {
      return (400, "subprotocol \(tunnelProtocol) missing")
    }
    guard ProxySecurity.validateKey(key, gate.key) else {
      return (403, "proxy key missing or wrong")
    }
    return nil
  }

  struct Head {
    let method: String
    let host: String
  }

  private static let tokenCharacters = Set(
    "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
  private static let trimmed = Set<Unicode.Scalar>([
    "\t", "\n", "\u{0B}", "\u{0C}", "\r", " ", "\u{A0}",
  ])

  static func parseHead(_ bytes: [UInt8]) -> Head? {
    let text = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
    let lines = text.components(separatedBy: "\r\n")
    guard let line = lines.first, let method = requestMethod(line) else { return nil }
    let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
    guard hosts.count == 1, let field = hosts.first else { return nil }
    var host = Array(field.unicodeScalars.dropFirst(5))
    while let first = host.first, trimmed.contains(first) { host.removeFirst() }
    while let last = host.last, trimmed.contains(last) { host.removeLast() }
    return Head(method: method, host: String(String.UnicodeScalarView(host)))
  }

  private static func requestMethod(_ line: String) -> String? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
      parts[0].unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
      !parts[1].unicodeScalars.contains(where: { trimmed.contains($0) }),
      parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1"
    else { return nil }
    return String(parts[0])
  }

  static func kernelPort(_ host: String, listenPort: Int) -> Int? {
    let lower = host.lowercased()
    let suffix = ".kernel.localhost"
    guard let range = lower.range(of: suffix) else { return nil }
    let digits = lower[..<range.lowerBound]
    let rest = lower[range.upperBound...]
    guard (1...5).contains(digits.count), digits.allSatisfy(\.isASCII),
      digits.allSatisfy(\.isNumber),
      digits.first != "0", let port = Int(digits), port <= 65535
    else { return nil }
    if rest.isEmpty { return port }
    guard rest.first == ":", rest.count > 1,
      rest.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
    else { return nil }
    return rest.dropFirst() == Substring(String(listenPort)) ? port : nil
  }

  static func failure(_ code: String, port: Int) -> (status: Int, message: String) {
    switch code {
    case "ETIMEDOUT": return (504, "kernel port \(port) did not answer")
    case "ECONNREFUSED": return (502, "nothing listening on kernel port \(port)")
    case "ECONNRESET": return (502, "no seven page connected")
    default: return (502, "kernel port \(port): \(code)")
    }
  }

  static func answer(status: Int, message: String) -> ByteBuffer {
    let body = "\(message)\n"
    let head = [
      "HTTP/1.1 \(status) \(statusText[status] ?? "")",
      "Content-Type: text/plain; charset=utf-8",
      "Content-Length: \(body.utf8.count)",
      "Cache-Control: no-store",
      "\(RawFetchProtocol.errorHeader): 1",
      "Connection: close",
      "",
      body,
    ]
    return ByteBuffer(string: head.joined(separator: "\r\n"))
  }
}
