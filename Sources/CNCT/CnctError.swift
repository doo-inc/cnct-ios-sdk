import Foundation

/// Everything in this SDK that can fail, fails with one of these.
///
/// The ``code`` is the part worth branching on. It is stable across versions and, where the failure
/// came from the server, it is the server's own code verbatim — the same string a JavaScript,
/// Flutter or Android integrator sees for the same event, because SDKs inventing their own
/// vocabularies for one error is how a support answer stops being portable between them.
///
/// ```swift
/// do { try await chat.send("Hello") }
/// catch let error as CnctError where error.code == .conversationClosed { startAgain() }
/// ```
public struct CnctError: Error, Sendable, Hashable {
  /// For a human. Never parse this — branch on ``code``.
  public let message: String

  /// Stable. See ``CnctErrorCode`` for the ones this SDK promises to keep.
  public let code: CnctErrorCode

  /// The HTTP status, when the failure arrived as a response rather than as a socket frame or a
  /// dead network.
  public let status: Int?

  /// The server's whole error body, where it answered with one.
  ///
  /// Worth reading: a refused tool call carries everything the tool answered, and a validation
  /// refusal carries the fields under `error` as `{fieldErrors, formErrors}`.
  public let details: CnctJSON?

  public init(_ message: String, code: CnctErrorCode = .requestFailed, status: Int? = nil, details: CnctJSON? = nil) {
    self.message = message
    self.code = code
    self.status = status
    self.details = details
  }

  /// True when retrying later is reasonable: the network was down, the socket dropped mid-send, or
  /// the server asked us to slow down. A 4xx that is not a rate limit is not in here — retrying a
  /// request the server understood and refused just refuses again.
  public var isRetryable: Bool {
    [.offline, .timeout, .rateLimited, .serverError].contains(code)
  }

  /// True when the credential is the problem: it expired, it was revoked, or it never resolved.
  /// A chat client clears its stored session token when it sees this; anything else should ask for
  /// a fresh credential rather than retrying.
  public var isUnauthenticated: Bool { code == .unauthenticated }
}

extension CnctError: LocalizedError {
  public var errorDescription: String? { message }
}

extension CnctError: CustomStringConvertible {
  public var description: String {
    "CnctError(\(code.rawValue)\(status.map { " \($0)" } ?? "")): \(message)"
  }
}

/// The codes this SDK will not rename.
///
/// The first block is the server's — the platform sends these by name and they are the same strings
/// the web and Flutter SDKs expose. The second block is this client's, for the failures that never
/// reach a server. A code the server invents later still arrives intact: this is a string, not a
/// closed enum.
public struct CnctErrorCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  // MARK: The server's

  /// The request was malformed or failed validation. ``CnctError/details`` carries the fields.
  public static let invalid: CnctErrorCode = "invalid"
  /// Too many requests. Slow down.
  public static let rateLimited: CnctErrorCode = "rate_limited"
  /// The message body was over the four-thousand-character limit.
  public static let tooLarge: CnctErrorCode = "too_large"
  /// The conversation has ended. Start a new one; it cannot be reopened from this side.
  public static let conversationClosed: CnctErrorCode = "conversation_closed"
  /// The request collided with something that already exists or has already moved on — a slot
  /// somebody else took, say. Never a reason to retry unchanged.
  public static let conflict: CnctErrorCode = "conflict"
  /// The session token now points at a different conversation than the one being written to.
  public static let conversationChanged: CnctErrorCode = "conversation_changed"
  /// The credential did not resolve, or no longer does.
  public static let unauthenticated: CnctErrorCode = "unauthenticated"
  /// Something broke on the far side.
  public static let serverError: CnctErrorCode = "server_error"

  // MARK: This client's

  /// The network could not be reached at all, or a socket dropped before a frame was acknowledged.
  /// Distinct from a 4xx on purpose: one is worth retrying and the other is not.
  public static let offline: CnctErrorCode = "offline"
  /// A request or a send was not answered inside the configured window.
  public static let timeout: CnctErrorCode = "timeout"
  /// A method that needs a live session was called before `start()` or `resume()`.
  public static let noSession: CnctErrorCode = "no_session"
  /// Nothing to send: the body was empty or whitespace.
  public static let empty: CnctErrorCode = "empty"
  /// A lookup found nothing.
  public static let notFound: CnctErrorCode = "not_found"
  /// The server answered, and answered with an error this SDK has no more specific name for.
  public static let requestFailed: CnctErrorCode = "request_failed"
  /// The response was not the shape this SDK expects. Almost always a base URL pointing at
  /// something that is not a CNCT host.
  public static let badResponse: CnctErrorCode = "bad_response"
  /// A module was used without the credential it needs.
  public static let missingCredential: CnctErrorCode = "missing_credential"
  /// A tool declined, in a sentence rather than a status code. The platform answers `200` with an
  /// `error` key when it will not do something, and this is that, raised.
  public static let toolRefused: CnctErrorCode = "tool_refused"
  /// The device would not keep or hand back the visitor's session token — the Keychain refused,
  /// most often because the device has not been unlocked since it started. Nothing reached a server.
  public static let storageFailed: CnctErrorCode = "storage_failed"
}
