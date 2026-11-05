import Foundation
import Testing

@testable import CNCT

@Suite("Credentials")
struct CredentialsTests {
  @Test("a public key opens chat and travels on no header")
  func publicKey() throws {
    let key = try CnctChatPublicKey("inbox-public-key-1234")
    #expect(key.headers.isEmpty)
    #expect(Cnct.modules(for: key) == [.chat])
    #expect(throws: CnctError.self) { try CnctChatPublicKey("  ") }
  }

  @Test("an API key opens bookings and tickets, on a bearer header")
  func apiKey() throws {
    let key = try CnctApiKey("kaer_sk_live_abcdef")
    #expect(key.headers == ["authorization": "Bearer kaer_sk_live_abcdef"])
    #expect(Cnct.modules(for: key) == [.bookings, .tickets])
  }

  @Test("the prefix decides the mode", arguments: [
    ("kaer_sk_test_abc", CnctKeyMode.sandbox),
    ("kaer_sk_live_abc", CnctKeyMode.production),
    ("kaer_sk_abc", CnctKeyMode.production),
  ])
  func mode(raw: String, expected: CnctKeyMode) throws {
    let key = try CnctApiKey(raw)
    #expect(key.mode == expected)
    #expect(key.isSandbox == (expected == .sandbox))
  }

  @Test("refuses something that is not an API key")
  func refusesWrongShape() {
    #expect(throws: CnctError.self) { try CnctApiKey("") }
    #expect(throws: CnctError.self) { try CnctApiKey("inbox-public-key") }
  }

  @Test("printing a credential never prints the secret")
  func redacts() throws {
    let api = try CnctApiKey("kaer_sk_live_supersecretWXYZ")
    let chat = try CnctChatPublicKey("publickeyvalueABCD")
    #expect(api.redacted == "apiKey:…WXYZ")
    #expect(chat.redacted == "publicKey:…ABCD")
    #expect(!"\(api)".contains("supersecret"))
    #expect(!String(reflecting: api).contains("supersecret"))
    var dumped = ""
    dump(api, to: &dumped)
    #expect(!dumped.contains("supersecret"))
    #expect(try CnctChatPublicKey("abc").redacted == "publicKey:****")
  }
}
