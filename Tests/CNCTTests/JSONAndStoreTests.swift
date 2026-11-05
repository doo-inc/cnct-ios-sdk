import Foundation
import Testing

@testable import CNCT

@Suite("CnctJSON and the token store")
struct JSONAndStoreTests {
  @Test("keeps booleans and numbers apart")
  func boolsAndNumbers() throws {
    let value = try JSONDecoder().decode(CnctJSON.self, from: Data(#"{"t":true,"one":1,"zero":0,"f":1.5}"#.utf8))
    #expect(value["t"] == .bool(true))
    #expect(value["one"] == .number(1))
    #expect(value["zero"] == .number(0))
    #expect(value["f"]?.intValue == nil)
    #expect(value["f"]?.doubleValue == 1.5)
  }

  @Test("decodes a typed model")
  func typed() throws {
    struct Inbox: Decodable, Equatable {
      let name: String
      let active: Bool
    }
    let value: CnctJSON = ["name": "Website chat", "active": true, "extra": [1, 2]]
    #expect(try value.decode(Inbox.self) == Inbox(name: "Website chat", active: true))
  }

  @Test("the memory store keeps, reads and clears")
  func memoryStore() async throws {
    let store = CnctMemoryTokenStore()
    #expect(try await store.read("k") == nil)
    try await store.write("k", value: "token")
    #expect(try await store.read("k") == "token")
    try await store.clear("k")
    #expect(try await store.read("k") == nil)
  }
}
