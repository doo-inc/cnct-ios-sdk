import Foundation

/// A part of CNCT a credential can open.
///
/// Not decoration: the two credentials are genuinely different keys to different doors, and an app
/// that asks ``Cnct/modules(for:)`` what it holds can hide the tabs it cannot serve instead of
/// finding out with a 401 in front of a customer.
public enum CnctModule: String, Sendable, Hashable, CaseIterable {
  /// Live chat with an inbox, as a visitor.
  case chat
  /// The calendar: availability, bookings, reschedules, cancellations.
  case bookings
  /// Tickets raised for work somebody has to pick up.
  case tickets
}

/// The entry point. Holds the ``CnctConfig`` and hands out the clients a credential opens.
///
/// You do not have to use it — every client can be constructed directly — but it is the shortest
/// path from "here is our host and here is our key" to something working, and it is the one place
/// the host lives.
///
/// ```swift
/// let cnct = Cnct()                                    // https://app.doo.ooo
/// let chat = cnct.chat(try CnctChatPublicKey("inbox-public-key"))
/// let local = try Cnct(host: "http://localhost:3001")
/// ```
///
/// **Swapping hosts** is ``withBaseURL(_:)``. Clients already made keep the host they were made
/// with — they hold open sockets and in-flight requests, and silently re-pointing those
/// mid-conversation would be worse than making a new client and saying so.
public struct Cnct: Sendable {
  public let config: CnctConfig

  /// Production, `https://app.doo.ooo`, unless `config` says otherwise.
  public init(config: CnctConfig = CnctConfig()) {
    self.config = config
  }

  /// The short form, for the common case of a host and nothing else.
  public init(host: String) throws {
    self.config = try CnctConfig(baseURL: host)
  }

  /// The same SDK pointed somewhere else. Everything but the host is carried over.
  public func withBaseURL(_ baseURL: String) throws -> Cnct {
    Cnct(config: try config.withBaseURL(baseURL))
  }

  /// What a credential opens. Tickets also need the account to hold ticketing — ask
  /// ``CnctAgentClient/catalogue()`` for what a particular account actually offers.
  public static func modules(for credentials: any CnctCredentials) -> Set<CnctModule> {
    credentials.modules
  }

  /// Live chat, as a visitor. The credential is an inbox's public key — the one credential in this
  /// SDK that is meant to be inside your app.
  ///
  /// Pass a `tokenStore` to keep the visitor's session across restarts. The default keeps it in
  /// memory, which means a returning customer arrives as a stranger.
  public func chat(
    _ credentials: CnctChatPublicKey,
    tokenStore: (any CnctTokenStore)? = nil,
    storageKey: String? = nil
  ) -> CnctChatClient {
    CnctChatClient(config: config, credentials: credentials, tokenStore: tokenStore, storageKey: storageKey)
  }

  /// Bookings and tickets, on an account-wide API key. **Server-side only** — see ``CnctApiKey``.
  public func agent(_ credentials: CnctApiKey) -> CnctAgentClient {
    CnctAgentClient(config: config, credentials: credentials)
  }

  /// The client for a credential, whatever kind it is.
  ///
  /// For an app that is handed one of the two and has to work out what it can do — a settings
  /// screen where somebody pastes whatever CNCT gave them, say. Throws
  /// ``CnctErrorCode/missingCredential`` for a credential this returns nothing for: one of your own
  /// conforming to ``CnctCredentials``.
  public func client(for credentials: any CnctCredentials) throws -> CnctClient {
    switch credentials {
    case let key as CnctChatPublicKey: return .chat(chat(key))
    case let key as CnctApiKey: return .agent(agent(key))
    default:
      throw CnctError(
        "No CNCT client opens \(credentials.redacted). Use a CnctChatPublicKey or a CnctApiKey.",
        code: .missingCredential
      )
    }
  }
}

/// What ``Cnct/client(for:)`` hands back: the one client a credential opens.
public enum CnctClient: Sendable {
  /// From a ``CnctChatPublicKey``.
  case chat(CnctChatClient)
  /// From a ``CnctApiKey``.
  case agent(CnctAgentClient)

  /// What this client can do — the same answer as ``Cnct/modules(for:)`` for its credential.
  public var modules: Set<CnctModule> {
    switch self {
    case .chat: return [.chat]
    case .agent: return [.bookings, .tickets]
    }
  }
}
