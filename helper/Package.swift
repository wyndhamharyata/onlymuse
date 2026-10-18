// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "onlymuse-helper",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "onlymuse-helper")
  ]
)
