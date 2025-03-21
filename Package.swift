// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "swift-concurrency-limiter",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "Limiter", targets: ["Limiter"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0")
  ],
  targets: [
    .target(
      name: "Limiter",
      dependencies: [.product(name: "OrderedCollections", package: "swift-collections")]
    ),
    .testTarget(
      name: "LimiterTests",
      dependencies: [
        "Limiter",
        .product(name: "Clocks", package: "swift-clocks"),
      ]
    )
  ]
)
