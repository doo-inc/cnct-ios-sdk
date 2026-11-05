import Foundation

/// The CNCT hosts this SDK knows about by name.
///
/// **CNCT runs at `app.doo.ooo`, and that is the default.** Anything else — a proxy on your own
/// domain, a CNCT on your laptop — is one `baseURL` away.
///
/// Whether what you do is real is decided by the key, not the host: a sandbox key
/// (`kaer_sk_test_…`) talks to the same production host and writes nothing real. See ``CnctApiKey``.
public enum CnctHosts {
  /// Production. What ``CnctConfig/baseURL`` is when you leave it out.
  public static let production = URL(string: "https://app.doo.ooo")!
}

/// How loud a log line is.
public enum CnctLogLevel: Int, Sendable, Comparable {
  case debug, info, warning, error

  public static func < (lhs: CnctLogLevel, rhs: CnctLogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where this SDK says what it is doing.
public typealias CnctLogger = @Sendable (_ level: CnctLogLevel, _ message: String, _ error: (any Error)?) -> Void

/// Where this SDK points and how it behaves on the wire.
///
/// One value, passed to every client, and the only thing that has to change to move an app between
/// a developer's laptop, a staging host and production. It is a struct, so a changed copy is a
/// `var` away; ``withBaseURL(_:)`` is the one change that can fail, because a host can be wrong.
///
/// ```swift
/// let config = CnctConfig()                                   // https://app.doo.ooo
/// let local = try CnctConfig(baseURL: "http://localhost:3001")
/// ```
public struct CnctConfig: Sendable {
  /// The version this SDK reports in its `User-Agent`. The release workflow refuses a tag that does
  /// not match it.
  public static let sdkVersion = "0.1.0"

  /// The CNCT host, with an optional path prefix. Defaults to ``CnctHosts/production``.
  ///
  /// A prefix is honoured rather than stripped: a client fronting CNCT at
  /// `https://theirdomain.com/support` is a legitimate arrangement, and every path this SDK builds
  /// is appended to whatever is here. Trailing slashes, a query and a fragment are dropped.
  public let baseURL: URL

  /// How long to wait for an HTTP response before giving up with ``CnctErrorCode/timeout``.
  public var connectTimeout: TimeInterval

  /// How long to wait for a chat message to be acknowledged before rejecting it. Rejecting is safe:
  /// every message carries an idempotency key, so a retry cannot double-post.
  public var sendTimeout: TimeInterval

  /// Sent on every request. For a proxy that wants its own header, a tracing id, or a tenant
  /// selector in front of CNCT. Never put a CNCT credential here — the clients set those
  /// themselves, on the header each one actually uses.
  public var headers: [String: String]

  /// Identifies this SDK in the platform's request logs. Worth overriding with your own app's name
  /// and version: when a client asks why their integration is being rate-limited, this is the field
  /// that answers it.
  public var userAgent: String

  /// Where this SDK says what it is doing. Nil is silence, which is the default — an SDK that
  /// prints to a customer's console uninvited is a bug report.
  public var logger: CnctLogger?

  /// Production, `https://app.doo.ooo`. Cannot fail.
  public init(
    connectTimeout: TimeInterval = 20,
    sendTimeout: TimeInterval = 15,
    headers: [String: String] = [:],
    userAgent: String = "cnct-ios-sdk/\(CnctConfig.sdkVersion)",
    logger: CnctLogger? = nil
  ) {
    self.baseURL = CnctHosts.production
    self.connectTimeout = connectTimeout
    self.sendTimeout = sendTimeout
    self.headers = headers
    self.userAgent = userAgent
    self.logger = logger
  }

  /// Another host. Throws ``CnctErrorCode/invalid`` for anything that is not an absolute http(s)
  /// URL — including an empty string, which is never "left out": it is a variable somebody meant to
  /// set.
  public init(
    baseURL: String,
    connectTimeout: TimeInterval = 20,
    sendTimeout: TimeInterval = 15,
    headers: [String: String] = [:],
    userAgent: String = "cnct-ios-sdk/\(CnctConfig.sdkVersion)",
    logger: CnctLogger? = nil
  ) throws {
    self.baseURL = try Self.normalise(baseURL)
    self.connectTimeout = connectTimeout
    self.sendTimeout = sendTimeout
    self.headers = headers
    self.userAgent = userAgent
    self.logger = logger
  }

  /// Another host, as a `URL`.
  public init(
    baseURL: URL,
    connectTimeout: TimeInterval = 20,
    sendTimeout: TimeInterval = 15,
    headers: [String: String] = [:],
    userAgent: String = "cnct-ios-sdk/\(CnctConfig.sdkVersion)",
    logger: CnctLogger? = nil
  ) throws {
    try self.init(
      baseURL: baseURL.absoluteString,
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      userAgent: userAgent,
      logger: logger
    )
  }

  /// The same config pointed somewhere else. Everything but the host is carried over.
  public func withBaseURL(_ baseURL: String) throws -> CnctConfig {
    try CnctConfig(
      baseURL: baseURL,
      connectTimeout: connectTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      userAgent: userAgent,
      logger: logger
    )
  }

  /// The WebSocket origin, derived rather than configured.
  ///
  /// Two URLs to keep in step is one URL that gets forgotten, and the forgotten one is always the
  /// socket — it fails later, in a way that looks like a network problem rather than a
  /// misconfiguration. `https` becomes `wss`, `http` becomes `ws`, and the path prefix travels.
  public var socketBaseURL: URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
    return components.url!
  }

  /// Build a request URL under ``baseURL``, preserving any path prefix it carries.
  ///
  /// `path` is taken as already percent-encoded where it needs to be — build an id into it with
  /// ``CnctConfig/pathSegment(_:)``. In `query`, nil and empty values are left out, arrays repeat
  /// the key, and keys are sorted so the same call always builds the same URL. Values are encoded
  /// strictly: a `+` in a phone number arrives as a `+`, not as a space.
  public func resolve(_ path: String, query: [String: Any?] = [:]) -> URL {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    let prefix = components.percentEncodedPath.trimmingTrailing("/")
    let suffix = path.hasPrefix("/") ? path : "/\(path)"
    components.percentEncodedPath =
      prefix + (suffix.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? suffix)

    var items: [(String, String)] = []
    for key in query.keys.sorted() {
      guard let value = query[key] ?? nil else { continue }
      if let many = value as? [Any] {
        for item in many {
          let text = "\(item)"
          if !text.isEmpty { items.append((key, text)) }
        }
      } else {
        let text = "\(value)"
        if !text.isEmpty { items.append((key, text)) }
      }
    }
    components.percentEncodedQuery =
      items.isEmpty
      ? nil
      : items.map { "\(Self.queryEscape($0.0))=\(Self.queryEscape($0.1))" }.joined(separator: "&")
    return components.url!
  }

  /// One path segment, percent-encoded — for an id that is about to go into a path. A `/` in it is
  /// encoded rather than read as a separator.
  public static func pathSegment(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? value
  }

  // MARK: - Private

  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
  private static let segmentAllowed = unreserved
  private static let pathAllowed = CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "%"))

  private static func queryEscape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  static func normalise(_ raw: String) throws -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw CnctError(
        "baseURL is empty. Leave it out to use CNCT production (\(CnctHosts.production.absoluteString)), "
          + "or pass your own host.",
        code: .invalid
      )
    }
    guard
      var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host, !host.isEmpty
    else {
      throw CnctError("baseURL must be an absolute http(s) URL — got \"\(trimmed)\".", code: .invalid)
    }
    // Trailing slashes are stripped once, here, so that every path built from this is built the
    // same way and a host written with one behaves identically to a host written without.
    components.scheme = scheme
    components.percentEncodedPath = components.percentEncodedPath.trimmingTrailing("/")
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
      throw CnctError("baseURL must be an absolute http(s) URL — got \"\(trimmed)\".", code: .invalid)
    }
    return url
  }
}

extension CnctConfig: CustomStringConvertible {
  public var description: String { "CnctConfig(baseURL: \(baseURL.absoluteString))" }
}

extension String {
  fileprivate func trimmingTrailing(_ character: Character) -> String {
    var copy = self
    while copy.last == character { copy.removeLast() }
    return copy
  }
}
