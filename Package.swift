// swift-tools-version:6.0
import PackageDescription

// The official CNCT SDK for iOS (and macOS, where the tests run without a simulator).
//
// Two libraries, no dependencies. `CNCT` is the headless client: everything rides on Foundation —
// URLSession for HTTP and URLSessionWebSocketTask for the chat socket — so adding it to an app adds
// nothing else to it. `CNCTUI` is the ready-made chat screen on top of it, SwiftUI and UIKit only,
// for an app that wants a branded chat rather than a chat of its own. Someone who wants only the
// headless client installs only that.
let package = Package(
  name: "CNCT",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "CNCT", targets: ["CNCT"]),
    .library(name: "CNCTUI", targets: ["CNCTUI"]),
  ],
  targets: [
    .target(name: "CNCT"),
    // The screen itself is iOS only; its theme, words and text direction are not, so they build and
    // are tested everywhere the headless client is.
    .target(name: "CNCTUI", dependencies: ["CNCT"], resources: [.process("Resources")]),
    .testTarget(name: "CNCTTests", dependencies: ["CNCT"]),
    .testTarget(name: "CNCTUITests", dependencies: ["CNCTUI"]),
  ]
)
