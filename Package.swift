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
    .package(url: "https://github.com/swift-server/async-http-client", from: "1.36.2"),
    .package(url: "https://github.com/apple/swift-log", from: "1.15.1"),
    .package(url: "https://github.com/apple/swift-nio", from: "2.80.0"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.8.0"),
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
      ]
    ),
    .executableTarget(name: "slicc-swift", dependencies: ["SliccSwift"]),
    .testTarget(
      name: "SliccSwiftTests",
      dependencies: [
        "SliccSwift",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]
    ),
  ]
)
