// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SliccSwift",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "SliccSwift", targets: ["SliccSwift"]),
    .executable(name: "slicc-swift", targets: ["slicc-swift"]),
  ],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.27.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket", from: "2.8.0"),
    .package(url: "https://github.com/swift-server/async-http-client", from: "1.36.2"),
    .package(url: "https://github.com/apple/swift-log", from: "1.15.1"),
    .package(url: "https://github.com/apple/swift-nio", from: "2.103.0"),
    .package(url: "https://github.com/apple/swift-nio-extras", from: "1.35.1"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.12.0"),
  ],
  targets: [
    .target(
      name: "SliccSwift",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdCore", package: "hummingbird"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(name: "NIOHTTPTypes", package: "swift-nio-extras"),
        .product(name: "NIOHTTPTypesHTTP1", package: "swift-nio-extras"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]
    ),
    .executableTarget(name: "slicc-swift", dependencies: ["SliccSwift"]),
    .testTarget(
      name: "SliccSwiftTests",
      dependencies: [
        "SliccSwift",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdCore", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]
    ),
  ]
)
