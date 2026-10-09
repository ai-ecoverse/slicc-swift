import Foundation
import SliccSwift

struct LauncherOptions {
  var port = 0
  var page = LocalProxy.defaultPage
  var open = true
  var quiet = false
  var mounts: [String] = []
  var kernelPort = KernelProtocol.defaultPort
  var kernel = true

  static let usage = """
    usage: slicc-swift [--port PORT] [--page URL] [--mount PATH[:NAME][:ro]]...
                       [--kernel-port PORT] [--no-kernel] [--no-open] [--quiet]
    """

  init(_ arguments: [String]) throws {
    var rest = arguments[...]
    while let argument = rest.popFirst() {
      switch argument {
      case "--port":
        guard let parsed = Int(try Self.value(argument, &rest)), (0...65535).contains(parsed) else {
          throw LauncherError.usage("--port needs a number from 0 to 65535")
        }
        port = parsed
      case "--page": page = try Self.value(argument, &rest)
      case "--mount": mounts.append(try Self.value(argument, &rest))
      case "--kernel-port":
        guard let parsed = Int(try Self.value(argument, &rest)), (0...65535).contains(parsed) else {
          throw LauncherError.usage("--kernel-port needs a number from 0 to 65535")
        }
        kernelPort = parsed
      case "--no-kernel": kernel = false
      case "--no-open": open = false
      case "--quiet": quiet = true
      case "--help", "-h": throw LauncherError.help
      default: throw LauncherError.usage("unknown argument \(argument)")
      }
    }
  }

  private static func value(_ flag: String, _ rest: inout ArraySlice<String>) throws -> String {
    guard let value = rest.popFirst() else { throw LauncherError.usage("\(flag) needs a value") }
    return value
  }
}

enum LauncherError: Error {
  case help
  case usage(String)
}

func openInBrowser(_ url: String) {
  #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    try? process.run()
  #endif
}

let options: LauncherOptions
do {
  options = try LauncherOptions(Array(CommandLine.arguments.dropFirst()))
} catch LauncherError.help {
  print(LauncherOptions.usage)
  exit(0)
} catch LauncherError.usage(let message) {
  FileHandle.standardError.write(Data("slicc-swift: \(message)\n\(LauncherOptions.usage)\n".utf8))
  exit(2)
}

@Sendable func logLine(_ line: String) {
  FileHandle.standardError.write(Data("\(line)\n".utf8))
}

@Sendable func quietLine(_ line: String) {}

let folders = HostFolder.load(options.mounts, warn: logLine)
let proxy = LocalProxy(
  port: options.port, folders: folders, kernelPort: options.kernel ? options.kernelPort : nil,
  log: options.quiet ? quietLine : logLine, warn: logLine)
try await proxy.run { proxyURL, kernelPort in
  let launch = LocalProxy.launchURL(page: options.page, proxyURL: proxyURL, key: proxy.key)
  print("slicc-swift proxy on \(proxyURL)")
  print(launch)
  fflush(stdout)
  if let kernelPort {
    let suffix = kernelPort == 80 ? "" : ":\(kernelPort)"
    logLine("kernel services on http://<port>.kernel.localhost\(suffix)/")
  }
  if options.open { openInBrowser(launch) }
}
