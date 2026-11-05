import Foundation

/// A credential CNCT issued you, and the only thing that decides which parts of this SDK you can
/// use.
///
/// There are two — ``CnctChatPublicKey`` and ``CnctApiKey`` — they are not interchangeable, and
/// the difference between them is not convenience: it is what happens when one leaks. Each says
/// what it opens and where it is safe to keep it.
///
/// Printing one never prints the secret. `description`, `debugDescription` and `dump` all show
/// ``redacted``, so a credential that ends up in a log line or a crash report is not a leak.
public protocol CnctCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  /// The headers this credential travels on. Different for each, deliberately.
  var headers: [String: String] { get }

  /// A redacted form, for logs and error messages. Never contains the secret.
  var redacted: String { get }

  /// What this credential opens.
  var modules: Set<CnctModule> { get }
}

extension CnctCredentials {
  public var description: String { redacted }
  public var debugDescription: String { redacted }
}

/// An inbox's public key — the credential a customer-facing app carries.
///
/// **This one is meant to be in your app binary.** It identifies an inbox, not a person and not an
/// account: everything it opens is the visitor's own conversation, and a visitor is anonymous until
/// they volunteer a phone number. It is the same key that sits in the URL of the hosted chat page,
/// so it was already public.
///
/// It grants chat and nothing else. It cannot read contacts, cannot list conversations, and cannot
/// see another visitor's thread.
public struct CnctChatPublicKey: CnctCredentials, Hashable {
  public let publicKey: String

  public init(_ publicKey: String) throws {
    if publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw CnctError("A chat public key cannot be empty.", code: .invalid)
    }
    self.publicKey = publicKey
  }

  /// The public key is part of the path rather than a header, so there is nothing to add here. The
  /// per-visitor session token is added by the chat client itself, on `x-chat-token` — never on
  /// `Authorization`, because the platform's rate limiter keys on `ip + authorization` and a
  /// visitor who invents that header would be minting themselves a fresh budget.
  public var headers: [String: String] { [:] }

  public var redacted: String { "publicKey:\(tail(publicKey))" }

  public var modules: Set<CnctModule> { [.chat] }
}

extension CnctChatPublicKey: CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: ["redacted": redacted]) }
}

/// Which kind of API key: one whose writes are real, or one whose writes are kept apart.
public enum CnctKeyMode: String, Sendable, Hashable {
  /// `kaer_sk_test_…`: reads the account as it really is, and writes nothing real.
  case sandbox
  /// `kaer_sk_live_…`, and every key minted before there were two kinds (plain `kaer_sk_…`).
  case production
}

/// A server-to-server API key, minted in the CNCT console under **Settings → Developers**. Starts
/// with `kaer_sk_`.
///
/// **There are two kinds, and the key says which** — see ``mode``. A sandbox key
/// (`kaer_sk_test_…`) reads the account as it really is — services, people, hours, ticket types,
/// what is free — but nothing it books, moves, cancels or raises is real: no customer is contacted
/// and nothing appears in the business's calendar or queue, and every answer carries
/// `sandbox: true`. A production key (`kaer_sk_live_…`) is real. Both go to the same host.
///
/// **Do not ship this in an app.** It is account-wide: it can read and write bookings and tickets
/// for every customer the account has, and a key inside an installed binary is a key anybody with
/// the binary has. It belongs on a server you control, with the app calling that server. It is in
/// this SDK for server-side Swift, for internal tools, and so a debug build can try the API.
public struct CnctApiKey: CnctCredentials, Hashable {
  /// Every key ever issued begins with this. Recognisable on sight in a log or a pull request, and
  /// greppable by the secret scanners that look for exactly this shape.
  public static let prefix = "kaer_sk_"
  /// A sandbox key: reads the real account, writes nothing real.
  public static let sandboxPrefix = "kaer_sk_test_"
  /// A production key. Keys from before there were two kinds have neither segment, and are this.
  public static let productionPrefix = "kaer_sk_live_"

  public let key: String

  public init(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw CnctError("An API key cannot be empty.", code: .invalid)
    }
    if !trimmed.hasPrefix(Self.prefix) {
      throw CnctError(
        "A CNCT API key starts with \"\(Self.prefix)\". Check you have not pasted an inbox public key "
          + "or a session token.",
        code: .invalid
      )
    }
    self.key = trimmed
  }

  /// Which kind of key this is, read from its prefix. The platform decides from its own records and
  /// this can only agree with it: a key is minted with its prefix and never changes kind.
  public var mode: CnctKeyMode { key.hasPrefix(Self.sandboxPrefix) ? .sandbox : .production }

  /// True for a `kaer_sk_test_` key, whose writes are kept apart and are not real.
  public var isSandbox: Bool { mode == .sandbox }

  public var headers: [String: String] { ["authorization": "Bearer \(key)"] }

  public var redacted: String { "apiKey:\(tail(key))" }

  public var modules: Set<CnctModule> { [.bookings, .tickets] }
}

extension CnctApiKey: CustomReflectable {
  public var customMirror: Mirror { Mirror(self, children: ["redacted": redacted, "mode": mode]) }
}

/// The last four characters, which is enough to tell two credentials apart in a log and not enough
/// to be one. The first characters are the same on every key ever issued, so they say nothing.
private func tail(_ secret: String) -> String {
  secret.count <= 4 ? "****" : "…\(secret.suffix(4))"
}
