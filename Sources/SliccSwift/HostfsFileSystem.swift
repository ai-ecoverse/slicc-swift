import Foundation

struct HostfsTarget {
  let path: String
  let isRoot: Bool
}

struct HostfsAttr {
  let stats: stat

  var isDirectory: Bool { stats.st_mode & S_IFMT == S_IFDIR }
  var isSymlink: Bool { stats.st_mode & S_IFMT == S_IFLNK }
  var isFile: Bool { stats.st_mode & S_IFMT == S_IFREG }
  var size: Int64 { Int64(stats.st_size) }
  var mtimeNs: Int64 {
    Int64(stats.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(stats.st_mtimespec.tv_nsec)
  }
  var etag: String { "\"\(size)-\(mtimeNs)-\(stats.st_ino)\"" }

  var json: JSONValue {
    let kind = isDirectory ? "directory" : isSymlink ? "symlink" : "file"
    return .object([
      ("kind", .string(kind)),
      ("size", .int(size)),
      ("mtime", .number(Double(mtimeNs) / 1e6)),
      ("mode", .int(Int(stats.st_mode) & 0o7777)),
      ("ino", .int(stats.st_ino)),
      ("etag", .string(etag)),
    ])
  }
}

enum HostfsFileSystem {
  static let writingOps: Set<String> = ["mkdir", "rmdir", "unlink", "rename", "symlink", "setattr"]
  private static let slash = UInt8(ascii: "/")
  private static let dot = Array(".".utf8)
  private static let dotDot = Array("..".utf8)

  static func check(_ result: Int32) throws {
    if result == -1 { throw HostfsError.posix(errno) }
  }

  static func segments(_ value: JSONValue?) throws -> [String] {
    guard let rel = value?.string, !rel.utf8.contains(0) else { throw HostfsError("EINVAL") }
    if rel.utf8.first == slash { throw HostfsError("EACCES", "absolute path") }
    let parts = rel.utf8.split(separator: slash).map(Array.init).filter { $0 != dot }
    if parts.contains(dotDot) { throw HostfsError("EACCES") }
    return parts.map { String(decoding: $0, as: UTF8.self) }
  }

  static func join(_ root: String, _ parts: some Collection<String>) -> String {
    guard !parts.isEmpty else { return root }
    return (root.hasSuffix("/") ? root : root + "/") + parts.joined(separator: "/")
  }

  static func within(_ root: String, _ path: String) -> Bool {
    if path.utf8.elementsEqual(root.utf8) { return true }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return path.utf8.starts(with: prefix.utf8)
  }

  static func realPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { throw HostfsError.posix(errno) }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func resolve(_ root: String, _ rel: JSONValue?) throws -> HostfsTarget {
    let parts = try segments(rel)
    guard let leaf = parts.last else { return HostfsTarget(path: root, isRoot: true) }
    let parent = try realPath(join(root, parts.dropLast()))
    guard within(root, parent) else { throw HostfsError("EACCES") }
    return HostfsTarget(path: join(parent, [leaf]), isRoot: false)
  }

  static func look(_ path: String) throws -> HostfsAttr {
    var stats = stat()
    try check(lstat(path, &stats))
    return HostfsAttr(stats: stats)
  }

  static func fileAttr(_ fd: Int32) throws -> HostfsAttr {
    var stats = stat()
    try check(fstat(fd, &stats))
    return HostfsAttr(stats: stats)
  }

  static func pathField(_ body: JSONValue) -> JSONValue {
    guard let path = body["path"], path != .null else { return .string("") }
    return path
  }

  static func validMode(_ value: JSONValue?) -> Int? {
    guard let mode = value?.safeInteger, (0...0o7777).contains(mode) else { return nil }
    return mode
  }

  static func pathOp(_ root: String, _ body: JSONValue) throws -> JSONValue {
    let target = { try resolve(root, pathField(body)) }
    switch body["op"]?.string {
    case "stat":
      return try look(target().path).json
    case "list":
      return try list(target().path)
    case "mkdir":
      try check(mkdir(target().path, 0o777))
      return .object([])
    case "rmdir":
      let directory = try target()
      if directory.isRoot { throw HostfsError("EBUSY") }
      try check(rmdir(directory.path))
      return .object([])
    case "unlink":
      let file = try target()
      if file.isRoot { throw HostfsError("EBUSY") }
      if try look(file.path).isDirectory { throw HostfsError("EISDIR") }
      try check(unlink(file.path))
      return .object([])
    case "rename":
      return try move(resolve(root, body["from"]), resolve(root, body["to"]))
    case "symlink":
      guard let destination = body["target"]?.string, !destination.utf8.contains(0) else {
        throw HostfsError("EINVAL")
      }
      try check(symlink(destination, target().path))
      return .object([])
    case "readlink":
      return .object([("target", .string(try readLink(target().path)))])
    case "setattr":
      return try setattr(target().path, body)
    case "statfs":
      var info = statfs()
      try check(statfs(root, &info))
      return .object([
        ("bsize", .int(info.f_bsize)),
        ("blocks", .int(info.f_blocks)),
        ("bfree", .int(info.f_bfree)),
        ("bavail", .int(info.f_bavail)),
      ])
    default:
      throw HostfsError("EINVAL", "unknown op")
    }
  }

  private static func list(_ path: String) throws -> JSONValue {
    guard try look(path).isDirectory else { throw HostfsError("ENOTDIR") }
    guard let directory = opendir(path) else { throw HostfsError.posix(errno) }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
      }
      if name != "." && name != ".." { names.append(name) }
    }
    let entries = names.compactMap { name -> JSONValue? in
      guard let attr = try? look(join(path, [name])) else { return nil }
      return .object([("name", .string(name)), ("attr", attr.json)])
    }
    return .object([("entries", .array(entries))])
  }

  private static func move(_ from: HostfsTarget, _ to: HostfsTarget) throws -> JSONValue {
    if from.isRoot || to.isRoot { throw HostfsError("EBUSY") }
    if rename(from.path, to.path) == -1 {
      let code = errno
      throw code == EEXIST ? HostfsError("ENOTEMPTY") : HostfsError.posix(code)
    }
    return .object([])
  }

  private static func readLink(_ path: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = readlink(path, &buffer, buffer.count - 1)
    if count == -1 { throw HostfsError.posix(errno) }
    return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  private static func setattr(_ path: String, _ body: JSONValue) throws -> JSONValue {
    let mode = body["mode"]
    let mtime = body["mtime"]
    if mode != nil, validMode(mode) == nil { throw HostfsError("EINVAL") }
    if mtime != nil, mtime?.finite == nil { throw HostfsError("EINVAL") }
    let modified = try mtime?.finite.map { try timespecOf(milliseconds: $0) }
    let attr = try look(path)
    if let mode = validMode(mode) {
      if attr.isSymlink { throw HostfsError("EINVAL", "cannot chmod a symlink") }
      try check(chmod(path, mode_t(mode)))
    }
    if let modified {
      var times = [attr.stats.st_atimespec, modified]
      try check(utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW))
    }
    return .object([])
  }

  static func timespecOf(milliseconds: Double) throws -> timespec {
    var seconds = (milliseconds / 1000).rounded(.down)
    var nanoseconds = ((milliseconds - seconds * 1000) * 1_000_000).rounded()
    if nanoseconds >= 1_000_000_000 {
      seconds += 1
      nanoseconds -= 1_000_000_000
    }
    guard let whole = Int(exactly: seconds), let fraction = Int(exactly: nanoseconds),
      (0..<1_000_000_000).contains(fraction)
    else { throw HostfsError("EINVAL") }
    return timespec(tv_sec: whole, tv_nsec: fraction)
  }

  static func wantsWrite(_ body: JSONValue) -> Bool {
    ["write", "create", "truncate", "exclusive"].contains { body[$0]?.truthy == true }
  }

  static func openLeaf(_ root: String, _ rel: JSONValue?, flags: Int32, mode: Int = 0o666) throws
    -> Int32
  {
    let target = try resolve(root, rel)
    if (try? look(target.path))?.isSymlink == true { throw HostfsError("ELOOP", "is a symlink") }
    let fd = open(target.path, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(mode))
    if fd == -1 { throw HostfsError.posix(errno) }
    return fd
  }

  static func openFile(_ root: String, _ body: JSONValue) throws -> (fd: Int32, attr: HostfsAttr) {
    let writing = wantsWrite(body)
    let mode = body["mode"]
    if mode != nil, validMode(mode) == nil { throw HostfsError("EINVAL") }
    let create = body["create"]?.truthy == true
    var flags = writing ? O_RDWR : O_RDONLY
    if create { flags |= O_CREAT }
    if create, body["exclusive"]?.truthy == true { flags |= O_EXCL }
    if body["truncate"]?.truthy == true { flags |= O_TRUNC }
    let fd = try openLeaf(root, pathField(body), flags: flags, mode: validMode(mode) ?? 0o666)
    do {
      let attr = try fileAttr(fd)
      if attr.isDirectory { throw HostfsError("EISDIR") }
      if !attr.isFile { throw HostfsError("EINVAL", "not a regular file") }
      return (fd, attr)
    } catch {
      close(fd)
      throw error
    }
  }

  static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, at position: Int) throws {
    var done = 0
    while done < bytes.count {
      let written = pwrite(
        fd, bytes.baseAddress! + done, bytes.count - done, off_t(position + done))
      if written == -1 {
        if errno == EINTR { continue }
        throw HostfsError.posix(errno)
      }
      done += written
    }
  }

  static func read(_ fd: Int32, at position: Int, count: Int) throws -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: count)
    var done = 0
    while done < count {
      let got = buffer.withUnsafeMutableBytes {
        pread(fd, $0.baseAddress! + done, count - done, off_t(position + done))
      }
      if got == -1 {
        if errno == EINTR { continue }
        throw HostfsError.posix(errno)
      }
      if got == 0 { break }
      done += got
    }
    return done == count ? buffer : Array(buffer[..<done])
  }

  static func probeCase(_ root: String) -> Bool {
    let parts = root.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for index in stride(from: parts.count - 1, to: 0, by: -1) {
      let name = parts[index]
      let swapped = String(
        name.map { character -> String in
          let lower = character.lowercased()
          return lower == String(character) ? character.uppercased() : lower
        }.joined())
      if swapped == name { continue }
      var other = parts
      other[index] = swapped
      guard let mine = try? look(root), let theirs = try? look(other.joined(separator: "/")) else {
        return false
      }
      return mine.stats.st_ino == theirs.stats.st_ino && mine.stats.st_dev == theirs.stats.st_dev
    }
    return true
  }
}
