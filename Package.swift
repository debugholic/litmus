// swift-tools-version:5.9

import PackageDescription

let package = Package(
  name: "litmus",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "litmus", targets: ["litmus"]),
  ],
  dependencies: [
    // 스키마타 주입에 쓴다. Swift 릴리스를 따라가야 하는 유일한 의존성이다.
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.1"),
    // 리포트용. Plot 은 HTML, Rainbow 는 터미널 색.
    .package(url: "https://github.com/johnsundell/plot.git", from: "0.14.0"),
    .package(url: "https://github.com/onevcat/Rainbow.git", from: "4.2.0"),
  ],
  targets: [
    .target(
      name: "LitmusCore",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "Plot", package: "plot"),
        "Rainbow",
      ]
    ),
    .executableTarget(
      name: "litmus",
      dependencies: [
        "LitmusCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "LitmusCoreTests",
      dependencies: ["LitmusCore"]
    ),
  ]
)
