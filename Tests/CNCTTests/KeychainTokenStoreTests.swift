#if canImport(Security)
  import Foundation
  import Security
  import Testing

  @testable import CNCT

  /// Whether this test process may use the Keychain at all.
  ///
  /// It often may not: a package's tests on an iOS Simulator run without a host app, and so without
  /// the entitlement the Keychain checks for (`errSecMissingEntitlement`). That is a property of the
  /// test runner rather than of the store, so the suite is skipped rather than failed — a Keychain
  /// that is not there must not block every other test.
  private enum Keychain {
    static let isAvailable: Bool = {
      let probe: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ooo.doo.cnct.tests.probe.\(UUID().uuidString)",
        kSecAttrAccount as String: "probe",
      ]
      var add = probe
      add[kSecValueData as String] = Data("probe".utf8)
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
      SecItemDelete(probe as CFDictionary)
      return true
    }()
  }

  @Suite(
    "CnctKeychainTokenStore",
    .enabled(if: Keychain.isAvailable, "The Keychain is not available to this test process.")
  )
  struct KeychainTokenStoreTests {
    /// A service of its own per test, so parallel tests and earlier runs cannot see each other's
    /// items.
    private func store() -> CnctKeychainTokenStore {
      CnctKeychainTokenStore(service: "ooo.doo.cnct.tests.\(UUID().uuidString)")
    }

    @Test("keeps, reads and clears")
    func roundTrip() async throws {
      let store = store()
      #expect(try await store.read("k") == nil)
      try await store.write("k", value: "token")
      #expect(try await store.read("k") == "token")
      try await store.clear("k")
      #expect(try await store.read("k") == nil)
    }

    @Test("writing again replaces the token rather than failing as a duplicate")
    func overwrite() async throws {
      let store = store()
      try await store.write("k", value: "first")
      try await store.write("k", value: "second")
      #expect(try await store.read("k") == "second")
      try await store.clear("k")
    }

    @Test("clearing what is not there is not an error")
    func clearMissing() async throws {
      try await store().clear("never-written")
    }

    @Test("keys and services keep their tokens apart")
    func separation() async throws {
      let one = store()
      let other = store()
      try await one.write("a", value: "token-a")
      try await one.write("b", value: "token-b")
      #expect(try await one.read("a") == "token-a")
      #expect(try await one.read("b") == "token-b")
      #expect(try await other.read("a") == nil)
      try await one.clear("a")
      try await one.clear("b")
    }

    @Test("a chat client comes back to its visitor from the Keychain")
    func resumesFromTheKeychain() async throws {
      let store = store()
      try await store.write("cnct_chat_inbox-key", value: "visitor-token-1")
      let server = FakeServer { request in
        guard request.url.path == "/api/chat/public/session" else { return (404, ["error": "not found"]) }
        return (
          200,
          [
            "conversation": ["status": "OPEN", "startedAt": "2026-09-08T09:59:00.000Z"],
            "messages": [["id": "m1", "speaker": "AI", "body": "Welcome back.", "createdAt": "2026-09-08T10:00:00.000Z"]],
          ]
        )
      }
      let chat = CnctChatClient(
        config: server.config,
        credentials: try CnctChatPublicKey("inbox-key"),
        tokenStore: store,
        transport: server.transport(),
        socketFactory: FakeSocketFactory().make
      )

      #expect(try await chat.resume())
      #expect(chat.state.messages.first?.body == "Welcome back.")
      #expect(server.requests.first?.header("x-chat-token") == "visitor-token-1")
      await chat.dispose()
      try await store.clear("cnct_chat_inbox-key")
    }
  }
#endif
