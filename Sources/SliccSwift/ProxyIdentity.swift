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

  @available(*, deprecated, message: "every launch mints a fresh key; nothing is stored")
  public static func persistentKey(
    directory: URL = configDirectory(), rotate: Bool = false,
    warn: (String) -> Void = { _ in }
  ) throws -> String {
    removeStoredKey(directory: directory, warn: warn)
    return ProxySecurity.mintKey()
  }

  public static func removeStoredKey(
    directory: URL = configDirectory(), warn: (String) -> Void = { _ in }
  ) {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let stale = entries.filter { $0 == "key" || ($0.hasPrefix("key.") && $0.hasSuffix(".tmp")) }
    for entry in stale {
      let file = directory.appendingPathComponent(entry).path
      guard unlink(file) != 0 else { continue }
      let code = errno
      guard code != ENOENT else { continue }
      warn("cannot remove \(file): \(String(cString: strerror(code)))")
    }
    guard !stale.isEmpty,
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true
    else { return }
    rmdir(directory.path)
  }

  static func isKey(_ text: String) -> Bool {
    text.utf8.count == 43
      && text.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      }
  }
}
