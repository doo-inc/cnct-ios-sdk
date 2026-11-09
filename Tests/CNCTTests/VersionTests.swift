import Foundation
import Testing

@testable import CNCT

/// The repository's own files, read from the checkout the tests were built from.
private func repositoryFile(_ path: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

@Suite("Version")
struct VersionTests {
  /// What the SDK reports in its User-Agent is what the CHANGELOG describes and what the README tells
  /// people to install. A tag that disagreed with any of them would be a release nobody could
  /// describe.
  @Test("the version agrees everywhere the repository keeps one")
  func agrees() throws {
    let version = CnctConfig.sdkVersion
    #expect(version.split(separator: ".").count == 3)
    #expect(CnctConfig().userAgent == "cnct-ios-sdk/\(version)")

    let changelog = try repositoryFile("CHANGELOG.md")
    let heading = changelog.split(separator: "\n").first { $0.hasPrefix("## ") }.map(String.init) ?? ""
    #expect(heading.hasPrefix("## \(version)"), "the newest CHANGELOG entry is \"\(heading)\"")

    let readme = try repositoryFile("README.md")
    #expect(readme.contains(#"exact: "\#(version)""#), "the README does not pin \(version)")
  }
}
