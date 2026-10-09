import Foundation

public struct HostFolder: Sendable, Equatable {
  public let name: String
  public let root: String
  public let readonly: Bool
  public let caseInsensitive: Bool

  public struct Spec: Equatable, Sendable {
    public let path: String
    public let name: String?
    public let readonly: Bool
  }

  public static func parse(_ spec: String) -> Spec {
    var rest = Substring(spec)
    var readonly = false
    if rest.hasSuffix(":ro") {
      readonly = true
      rest = rest.dropLast(3)
    }
    var name: String?
    if let colon = rest.lastIndex(of: ":"), colon > rest.startIndex {
      let tail = rest[rest.index(after: colon)...]
      if !tail.isEmpty, !tail.contains("/"), !tail.contains("\\") {
        name = String(tail)
        rest = rest[..<colon]
      }
    }
    return Spec(path: String(rest), name: name, readonly: readonly)
  }

  public static func load(_ specs: [String], warn: (String) -> Void = { _ in }) -> [HostFolder] {
    var folders: [HostFolder] = []
    for spec in specs {
      let parsed = parse(spec)
      guard let root = try? HostfsFileSystem.realPath(parsed.path),
        let stats = try? HostfsFileSystem.look(root), stats.isDirectory
      else {
        warn("--mount \(spec): not an existing folder, skipping")
        continue
      }
      let name = parsed.name ?? (root as NSString).lastPathComponent
      guard !name.isEmpty, name != ".", name != "..",
        !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" })
      else {
        warn("--mount \(spec): invalid name, skipping")
        continue
      }
      guard !folders.contains(where: { $0.name == name }) else {
        warn("--mount \(spec): the name \(name) is taken, skipping")
        continue
      }
      folders.append(
        HostFolder(
          name: name, root: root, readonly: parsed.readonly,
          caseInsensitive: HostfsFileSystem.probeCase(root)))
    }
    return folders
  }

  var capabilities: JSONValue {
    .object([
      ("maxIo", .int(HostfsProtocol.maxIo)),
      ("symlinks", .bool(true)),
      ("chmod", .bool(true)),
      ("caseInsensitive", .bool(caseInsensitive)),
      ("normalization", .string(HostfsProtocol.normalization)),
      ("ranges", .bool(true)),
    ])
  }
}
