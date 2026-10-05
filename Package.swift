// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SliccSwift",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "SliccSwift", targets: ["SliccSwift"])
  ],
  targets: [
    .target(name: "SliccSwift"),
    .testTarget(name: "SliccSwiftTests", dependencies: ["SliccSwift"]),
  ]
)
