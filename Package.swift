// swift-tools-version:6.0
import PackageDescription

// The official CNCT SDK for iOS (and macOS, where the tests run without a simulator).
//
// One library, no dependencies. Everything rides on Foundation — URLSession for HTTP and
// URLSessionWebSocketTask for the chat socket — so adding this to an app adds nothing else to it.
let package = Package(
  name: "CNCT",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "CNCT", targets: ["CNCT"])
  ],
  targets: [
    .target(name: "CNCT"),
    .testTarget(name: "CNCTTests", dependencies: ["CNCT"]),
  ]
)
