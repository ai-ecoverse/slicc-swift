import Foundation
import NIOConcurrencyHelpers

#if os(macOS)
  import CoreServices
#endif

enum HostfsChange: Sendable, Equatable {
  case paths([String])
  case all
}

final class HostfsWatchers: Sendable {
  static let debounce: DispatchTimeInterval = .milliseconds(50)
  static let maxPaths = 256
  static let restart: DispatchTimeInterval = .seconds(1)

  private let folders = NIOLockedValueBox<[String: FolderWatch]>([:])

  static func relativeName(root: String, path: String) -> String? {
    if path.utf8.elementsEqual(root.utf8) { return "" }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.utf8.starts(with: prefix.utf8) else { return nil }
    var rel = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    while rel.hasSuffix("/") { rel.removeLast() }
    return rel
  }

  static func changedPaths(_ rel: String) -> [String] {
    guard let slash = rel.lastIndex(of: "/") else { return [rel, ""] }
    return [rel, String(rel[..<slash])]
  }

  func subscribe(_ root: String, _ listener: @escaping @Sendable (HostfsChange) -> Void)
    -> @Sendable () -> Void
  {
    let (watch, id) = folders.withLockedValue { folders in
      let watch = folders[root] ?? FolderWatch(root: root)
      folders[root] = watch
      return (watch, watch.add(listener))
    }
    return { [self] in
      folders.withLockedValue { folders in
        if watch.remove(id) == 0, folders[root] === watch {
          folders.removeValue(forKey: root)
          watch.stop()
        }
      }
    }
  }

  func close() {
    let all = folders.withLockedValue { folders in
      defer { folders.removeAll() }
      return Array(folders.values)
    }
    for watch in all { watch.stop() }
  }
}

final class FolderWatch: @unchecked Sendable {
  let root: String
  private let queue = DispatchQueue(label: "slicc-swift.hostfs.watch")
  private var listeners: [Int: @Sendable (HostfsChange) -> Void] = [:]
  private var nextListener = 0
  private var pending = Set<String>()
  private var everything = false
  private var flushing = false
  private var lost = false
  private var stopped = false
  #if os(macOS)
    private var stream: FSEventStreamRef?
  #endif

  init(root: String) {
    self.root = root
    queue.async { self.start() }
  }

  func add(_ listener: @escaping @Sendable (HostfsChange) -> Void) -> Int {
    queue.sync {
      nextListener += 1
      listeners[nextListener] = listener
      return nextListener
    }
  }

  func remove(_ id: Int) -> Int {
    queue.sync {
      listeners.removeValue(forKey: id)
      return listeners.count
    }
  }

  func stop() {
    queue.sync {
      stopped = true
      listeners.removeAll()
      halt()
    }
  }

  private func emit(_ change: HostfsChange) {
    for listener in listeners.values { listener(change) }
  }

  private func flush() {
    flushing = false
    let paths = pending
    let overflow = everything || paths.count > HostfsWatchers.maxPaths
    pending.removeAll()
    everything = false
    if overflow { emit(.all) } else if !paths.isEmpty { emit(.paths(paths.sorted())) }
  }

  private func note(_ rel: String?) {
    if let rel {
      for path in HostfsWatchers.changedPaths(rel) { pending.insert(path) }
      if pending.count > HostfsWatchers.maxPaths { everything = true }
    } else {
      everything = true
    }
    guard !flushing else { return }
    flushing = true
    queue.asyncAfter(deadline: .now() + HostfsWatchers.debounce) { self.flush() }
  }

  private func lose() {
    halt()
    if !lost { note(nil) }
    lost = true
    queue.asyncAfter(deadline: .now() + HostfsWatchers.restart) {
      if !self.stopped { self.start() }
    }
  }

  fileprivate func event(_ path: String, dropped: Bool) {
    guard !stopped else { return }
    note(dropped ? nil : HostfsWatchers.relativeName(root: root, path: path))
  }

  private func halt() {
    #if os(macOS)
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
      }
    #endif
  }

  private func start() {
    guard !stopped else { return }
    #if os(macOS)
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
        copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let dropped = FSEventStreamEventFlags(
          kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        for index in 0..<min(count, list.count) {
          watch.event(list[index], dropped: flags[index] & dropped != 0)
        }
      }
      let options = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
      guard
        let created = FSEventStreamCreate(
          nil, callback, &context, [root] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.01, options)
      else {
        lose()
        return
      }
      FSEventStreamSetDispatchQueue(created, queue)
      guard FSEventStreamStart(created) else {
        FSEventStreamInvalidate(created)
        FSEventStreamRelease(created)
        lose()
        return
      }
      stream = created
      if lost { note(nil) }
      lost = false
    #endif
  }
}
