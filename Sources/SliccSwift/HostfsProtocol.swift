import Foundation

public enum HostfsProtocol {
  public static let path = "/api/hostfs"
  public static let grantPath = "/api/hostfs/grant"
  public static let mountsPath = "/api/hostfs/mounts"
  public static let writePath = "/api/hostfs/write"
  public static let watchPath = "/api/hostfs/watch"
  public static let tokenHeader = "X-Hostfs-Token"
  public static let requestHeader = "X-Hostfs-Request"
  public static let errnoHeader = "X-Hostfs-Errno"
  public static let protocolVersion = 1
  public static let maxIo = 16 * 1024 * 1024
  public static let maxOpBody = 1024 * 1024
  public static let maxGrantBody = 4096
  public static let maxHandles = 4096
  public static let grantIdle: Duration = .seconds(5 * 60)
  public static let pingInterval: Duration = .seconds(15)
  public static let normalization = "nfd-insensitive"

  static let keyPaths: [String: [String]] = [
    grantPath: ["POST", "DELETE"],
    mountsPath: ["POST"],
  ]
  static let tokenPaths: [String: [String]] = [
    path: ["POST"],
    writePath: ["PUT"],
    watchPath: ["POST"],
  ]
}

struct HostfsError: Error {
  let errno: String
  let message: String

  init(_ errno: String, _ message: String? = nil) {
    self.errno = errno
    self.message = message ?? Self.messages[errno] ?? "input/output error"
  }

  static func posix(_ code: Int32) -> HostfsError {
    guard let name = names[code] else { return HostfsError("EIO") }
    let text = String(cString: strerror(code))
    return HostfsError(name, text.prefix(1).lowercased() + text.dropFirst())
  }

  static func from(_ error: any Error) -> HostfsError {
    error as? HostfsError ?? HostfsError("EIO")
  }

  var status: Int { Self.statuses[errno] ?? 500 }

  private static let messages = [
    "EACCES": "path escapes the folder",
    "EBADF": "bad file handle",
    "EBUSY": "the folder root cannot be moved or removed",
    "EINVAL": "invalid argument",
    "EISDIR": "is a directory",
    "ENOTDIR": "not a directory",
    "ENOTEMPTY": "directory not empty",
    "EROFS": "read-only folder",
    "ESTALE": "file changed since it was opened",
  ]

  private static let statuses = [
    "ENOENT": 404,
    "EACCES": 403, "EPERM": 403, "EROFS": 403,
    "EEXIST": 409, "ENOTEMPTY": 409, "EISDIR": 409, "ENOTDIR": 409, "EBUSY": 409, "ESTALE": 409,
    "EINVAL": 400, "ENAMETOOLONG": 400, "ELOOP": 400,
    "EBADF": 410,
    "ENOSPC": 507, "EFBIG": 507,
  ]

  private static let names: [Int32: String] = [
    EPERM: "EPERM", ENOENT: "ENOENT", EIO: "EIO", ENXIO: "ENXIO", EBADF: "EBADF",
    EAGAIN: "EAGAIN", ENOMEM: "ENOMEM", EACCES: "EACCES", EFAULT: "EFAULT", EBUSY: "EBUSY",
    EEXIST: "EEXIST", EXDEV: "EXDEV", ENODEV: "ENODEV", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR",
    EINVAL: "EINVAL", ENFILE: "ENFILE", EMFILE: "EMFILE", ETXTBSY: "ETXTBSY", EFBIG: "EFBIG",
    ENOSPC: "ENOSPC", ESPIPE: "ESPIPE", EROFS: "EROFS", EMLINK: "EMLINK", ELOOP: "ELOOP",
    ENAMETOOLONG: "ENAMETOOLONG", ENOTEMPTY: "ENOTEMPTY", EDQUOT: "EDQUOT", ESTALE: "ESTALE",
    ENOTSUP: "ENOTSUP", EOPNOTSUPP: "EOPNOTSUPP", EINTR: "EINTR", ETIMEDOUT: "ETIMEDOUT",
    EILSEQ: "EILSEQ", EOVERFLOW: "EOVERFLOW", ENOTCONN: "ENOTCONN",
  ]
}

indirect enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([(String, JSONValue)])

  static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    lhs.serialized == rhs.serialized
  }

  static func parse(_ data: Data) -> JSONValue? {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    else { return nil }
    return from(object)
  }

  private static func from(_ value: Any) -> JSONValue? {
    switch value {
    case is NSNull: return .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      return .number(number.doubleValue)
    case let string as String: return .string(string)
    case let array as [Any]:
      var items: [JSONValue] = []
      for item in array {
        guard let parsed = from(item) else { return nil }
        items.append(parsed)
      }
      return .array(items)
    case let dictionary as [String: Any]:
      var pairs: [(String, JSONValue)] = []
      for (key, item) in dictionary {
        guard let parsed = from(item) else { return nil }
        pairs.append((key, parsed))
      }
      return .object(pairs)
    default: return nil
    }
  }

  subscript(key: String) -> JSONValue? {
    guard case .object(let pairs) = self else { return nil }
    return pairs.first { $0.0 == key }?.1
  }

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var safeInteger: Int? {
    guard case .number(let value) = self, value.rounded() == value,
      abs(value) <= 9_007_199_254_740_991
    else { return nil }
    return Int(value)
  }

  var finite: Double? {
    guard case .number(let value) = self, value.isFinite else { return nil }
    return value
  }

  var truthy: Bool {
    switch self {
    case .null: return false
    case .bool(let value): return value
    case .number(let value): return value != 0 && !value.isNaN
    case .string(let value): return !value.isEmpty
    case .array, .object: return true
    }
  }

  var serialized: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let value):
      if value.rounded() == value, abs(value) <= 9_007_199_254_740_991 {
        return String(Int64(value))
      }
      return String(value)
    case .string(let value): return RawFetchProtocol.jsonLiteral(value)
    case .array(let items): return "[" + items.map(\.serialized).joined(separator: ",") + "]"
    case .object(let pairs):
      let body = pairs.map { RawFetchProtocol.jsonLiteral($0.0) + ":" + $0.1.serialized }
      return "{" + body.joined(separator: ",") + "}"
    }
  }
}

extension JSONValue {
  static func int<T: BinaryInteger>(_ value: T) -> JSONValue { .number(Double(value)) }
}
