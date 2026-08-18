// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "hex-god-screenshot-master",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "hex-god-screenshot-master",
      targets: ["HexGodScreenshotMaster"]
    )
  ],
  targets: [
    .executableTarget(name: "HexGodScreenshotMaster")
  ],
  swiftLanguageModes: [.v5]
)
