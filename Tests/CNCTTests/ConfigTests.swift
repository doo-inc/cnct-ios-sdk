import Foundation
import Testing

@testable import CNCT

@Suite("CnctConfig")
struct ConfigTests {
  @Test("defaults to production")
  func defaultsToProduction() {
    #expect(CnctConfig().baseURL.absoluteString == "https://app.doo.ooo")
    #expect(Cnct().config.baseURL == CnctHosts.production)
  }

  @Test("reports its version in the user agent")
  func userAgent() {
    #expect(CnctConfig().userAgent == "cnct-ios-sdk/\(CnctConfig.sdkVersion)")
  }

  @Test("refuses an empty host rather than treating it as left out")
  func refusesEmpty() {
    #expect(throws: CnctError.self) { try CnctConfig(baseURL: "") }
    #expect(throws: CnctError.self) { try CnctConfig(baseURL: "   ") }
    do {
      _ = try CnctConfig(baseURL: "")
    } catch let error as CnctError {
      #expect(error.code == .invalid)
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  @Test("refuses anything that is not absolute http(s)", arguments: ["app.doo.ooo", "ftp://x.test", "/relative", "wss://x.test"])
  func refusesNonHTTP(raw: String) {
    #expect(throws: CnctError.self) { try CnctConfig(baseURL: raw) }
  }

  @Test("strips trailing slashes, query and fragment once")
  func normalises() throws {
    #expect(try CnctConfig(baseURL: "https://x.test/").baseURL.absoluteString == "https://x.test")
    #expect(try CnctConfig(baseURL: " https://x.test/support// ").baseURL.absoluteString == "https://x.test/support")
    #expect(try CnctConfig(baseURL: "https://x.test/a?b=c#d").baseURL.absoluteString == "https://x.test/a")
  }

  @Test("derives the socket origin and keeps the prefix")
  func socketOrigin() throws {
    #expect(CnctConfig().socketBaseURL.absoluteString == "wss://app.doo.ooo")
    #expect(try CnctConfig(baseURL: "http://localhost:3001/p").socketBaseURL.absoluteString == "ws://localhost:3001/p")
  }

  @Test("resolves paths under the prefix")
  func resolvesUnderPrefix() throws {
    let config = try CnctConfig(baseURL: "https://x.test/support")
    #expect(config.resolve("/api/tools").absoluteString == "https://x.test/support/api/tools")
    #expect(config.resolve("api/tools").absoluteString == "https://x.test/support/api/tools")
    #expect(CnctConfig().resolve("/api/tools").absoluteString == "https://app.doo.ooo/api/tools")
  }

  @Test("encodes a plus in a query value rather than letting it become a space")
  func encodesPlus() {
    let url = CnctConfig().resolve("/api/x", query: ["phone": "+97312345678"])
    #expect(url.absoluteString == "https://app.doo.ooo/api/x?phone=%2B97312345678")
  }

  @Test("drops nil and empty query values, repeats arrays, sorts keys")
  func queryShape() {
    let url = CnctConfig().resolve(
      "/api/x",
      query: ["z": "1", "a": nil, "e": "", "tags": ["one", "", "two"], "n": 3, "b": true]
    )
    #expect(url.query == "b=true&n=3&tags=one&tags=two&z=1")
  }

  @Test("encodes an id as a single path segment")
  func pathSegment() {
    let id = CnctConfig.pathSegment("a/b c")
    #expect(id == "a%2Fb%20c")
    #expect(CnctConfig().resolve("/api/files/\(id)").absoluteString == "https://app.doo.ooo/api/files/a%2Fb%20c")
  }

  @Test("withBaseURL carries everything but the host")
  func withBaseURL() throws {
    var config = CnctConfig()
    config.headers = ["x-trace": "1"]
    config.connectTimeout = 5
    let moved = try config.withBaseURL("https://staging.example.com")
    #expect(moved.baseURL.absoluteString == "https://staging.example.com")
    #expect(moved.headers == ["x-trace": "1"])
    #expect(moved.connectTimeout == 5)
    #expect(try Cnct().withBaseURL("http://localhost:3001").config.baseURL.absoluteString == "http://localhost:3001")
  }
}
