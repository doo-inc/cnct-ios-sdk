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

  /// Bookings and tickets, on an account-wide API key. **Server-side only** — see ``CnctApiKey``.
  public func agent(_ credentials: CnctApiKey) -> CnctAgentClient {
    CnctAgentClient(config: config, credentials: credentials)
  }
}
