import Foundation

public enum ProxyIdentity {
  public static let defaultPort = 17117
  static let name = "slicc-swift"

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

  public static func removeStoredKey(
    directory: URL = configDirectory(), warn: (String) -> Void = { _ in }
  ) {
    let file = directory.appendingPathComponent("key").path
    guard unlink(file) != 0 else { return }
    let code = errno
    guard code != ENOENT else { return }
    warn("cannot remove \(file): \(String(cString: strerror(code)))")
  }

  static func isKey(_ text: String) -> Bool {
    text.utf8.count == 43
      && text.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      }
  }
}
