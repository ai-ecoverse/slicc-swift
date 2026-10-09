import Foundation

public enum ProxyIdentity {
  public static let defaultPort = 17117
  static let name = "slicc-swift"

  public struct Failure: Error, CustomStringConvertible {
    public let description: String
  }

  public static func configDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg).appendingPathComponent(name)
    }
    #if os(macOS)
      let home = FileManager.default.homeDirectoryForCurrentUser
      return home.appendingPathComponent("Library/Application Support").appendingPathComponent(name)
    #elseif os(iOS)
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      return support[0].appendingPathComponent(name)
    #else
      let home = FileManager.default.homeDirectoryForCurrentUser
      return home.appendingPathComponent(".config").appendingPathComponent(name)
    #endif
  }

  public static func persistentKey(
    directory: URL = configDirectory(), rotate: Bool = false,
    warn: (String) -> Void = { _ in }
  ) throws -> String {
    try keepPrivate(directory.path, warn: warn)
    let file = directory.appendingPathComponent("key").path
    if rotate { return try replaceKey(file) }
    if let created = try createKey(file) { return created }
    return try readKey(file, warn: warn) ?? replaceKey(file)
  }

  static func isKey(_ text: String) -> Bool {
    text.utf8.count == 43
      && text.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      }
  }

  private static func check(_ result: Int32, _ action: String, _ path: String) throws {
    guard result != 0 else { return }
    throw failure(errno, action, path)
  }

  private static func failure(_ code: Int32, _ action: String, _ path: String) -> Failure {
    Failure(description: "cannot \(action) \(path): \(String(cString: strerror(code)))")
  }

  private static func mode(_ path: String) throws -> mode_t {
    var info = stat()
    try check(stat(path, &info), "stat", path)
    return info.st_mode
  }

  private static func keepPrivate(_ directory: String, warn: (String) -> Void) throws {
    do {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw Failure(description: "cannot create \(directory): \(error.localizedDescription)")
    }
    guard try mode(directory) & 0o077 != 0 else { return }
    try check(chmod(directory, 0o700), "chmod", directory)
    warn("\(directory) was open to others; it is 0700 now")
  }

  private static func readKey(_ file: String, warn: (String) -> Void) throws -> String? {
    guard let data = FileManager.default.contents(atPath: file) else {
      throw failure(errno, "read", file)
    }
    let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard isKey(key) else {
      warn("\(file) does not hold a proxy key; minting a new one")
      return nil
    }
    if try mode(file) & 0o077 != 0 {
      try check(chmod(file, 0o600), "chmod", file)
      warn("\(file) was readable by others; it is 0600 now")
    }
    return key
  }

  private static func staged(_ file: String) throws -> (key: String, temporary: String) {
    let key = ProxySecurity.mintKey()
    let suffix = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    let temporary = "\(file).\(suffix).tmp"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else { throw failure(errno, "create", temporary) }
    defer { close(descriptor) }
    let bytes = Array("\(key)\n".utf8)
    let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == bytes.count else {
      let code = errno
      unlink(temporary)
      throw failure(code, "write", temporary)
    }
    return (key, temporary)
  }

  private static func createKey(_ file: String) throws -> String? {
    let (key, temporary) = try staged(file)
    defer { unlink(temporary) }
    guard link(temporary, file) == 0 else {
      guard errno == EEXIST else { throw failure(errno, "link", file) }
      return nil
    }
    return key
  }

  private static func replaceKey(_ file: String) throws -> String {
    let (key, temporary) = try staged(file)
    guard rename(temporary, file) == 0 else {
      let code = errno
      unlink(temporary)
      throw failure(code, "rename", file)
    }
    return key
  }
}
