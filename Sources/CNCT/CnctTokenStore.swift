import Foundation

/// Where a visitor's chat session token is kept between app launches.
///
/// The token is a thirty-day bearer secret scoped to one conversation. Held, the same person comes
/// back to the same thread with their history intact; lost, they are a stranger who has to start
/// again — which is not a failure, just a worse experience.
///
/// Conform anything — the Keychain, an app group container, your own storage — with three
/// methods. ``CnctMemoryTokenStore`` keeps nothing across a restart: correct for a test and a
/// kiosk, wrong for anything a person comes back to.
public protocol CnctTokenStore: Sendable {
  func read(_ key: String) async throws -> String?
  func write(_ key: String, value: String) async throws
  func clear(_ key: String) async throws
}

/// Keeps nothing across a restart.
public actor CnctMemoryTokenStore: CnctTokenStore {
  private var held: [String: String] = [:]

  public init() {}

  public func read(_ key: String) async throws -> String? { held[key] }

  public func write(_ key: String, value: String) async throws { held[key] = value }

  public func clear(_ key: String) async throws { held[key] = nil }
}
