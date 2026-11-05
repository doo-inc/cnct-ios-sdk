#if canImport(Security)
  import Foundation
  import Security

  /// Keeps the visitor's chat session token in the Keychain — the store to use in an app.
  ///
  /// The token is a thirty-day bearer secret scoped to one conversation, which makes it exactly the
  /// kind of thing the Keychain is for: it survives a relaunch and an app update, and it is encrypted
  /// at rest. It is a generic password under ``service``, one item per storage key, readable whenever
  /// the device has been unlocked once since it started — so a chat that reconnects in the background
  /// while the phone is locked still finds it, and one that runs before the first unlock fails with
  /// ``CnctErrorCode/storageFailed`` rather than quietly starting the visitor over as a stranger.
  ///
  /// ```swift
  /// let chat = Cnct().chat(try CnctChatPublicKey(key), tokenStore: CnctKeychainTokenStore())
  /// try await chat.resume() // false simply means they have not been here before
  /// ```
  ///
  /// Nothing here prints the token: a failure names the operation and the Keychain's status, never
  /// the value.
  public struct CnctKeychainTokenStore: CnctTokenStore {
    /// The service the tokens are filed under, unless you name another.
    public static let defaultService = "ooo.doo.cnct.chat"

    /// The Keychain service the items are filed under. Name your own to keep two chat integrations in
    /// one app apart, or to find the items again in a migration.
    public let service: String

    /// A Keychain access group to share the token with an app extension or another app of yours —
    /// a notification service extension that wants to know which conversation a push belongs to,
    /// say. Nil keeps it to this app.
    public let accessGroup: String?

    public init(service: String = CnctKeychainTokenStore.defaultService, accessGroup: String? = nil) {
      self.service = service
      self.accessGroup = accessGroup
    }

    public func read(_ key: String) async throws -> String? {
      var query = item(key)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      switch status {
      case errSecSuccess:
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
      case errSecItemNotFound:
        return nil
      default:
        throw failure("read", status)
      }
    }

    public func write(_ key: String, value: String) async throws {
      let attributes: [String: Any] = [
        kSecValueData as String: Data(value.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      ]
      // Update first: a visitor coming back is the common case, and an add over an existing item is
      // a duplicate-item failure rather than an overwrite.
      let updated = SecItemUpdate(item(key) as CFDictionary, attributes as CFDictionary)
      switch updated {
      case errSecSuccess:
        return
      case errSecItemNotFound:
        let added = SecItemAdd(item(key).merging(attributes) { _, new in new } as CFDictionary, nil)
        if added != errSecSuccess { throw failure("store", added) }
      default:
        throw failure("store", updated)
      }
    }

    public func clear(_ key: String) async throws {
      let status = SecItemDelete(item(key) as CFDictionary)
      // Already gone is what clearing asks for.
      if status != errSecSuccess && status != errSecItemNotFound { throw failure("clear", status) }
    }

    private func item(_ key: String) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
      ]
      if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
      return query
    }

    private func failure(_ operation: String, _ status: OSStatus) -> CnctError {
      let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
      return CnctError(
        "The Keychain could not \(operation) the chat session token: \(reason) (\(status)).",
        code: .storageFailed
      )
    }
  }
#endif
