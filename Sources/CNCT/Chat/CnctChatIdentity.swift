import Foundation

/// Who your app has signed in, proven by your server.
///
/// With this, a visitor is one of your users rather than a stranger on a device: their conversations
/// follow them to a new phone, and an anonymous chat they started before signing in moves across.
///
/// **`userHash` is computed on your server, never in the app.** It is
/// `HMAC-SHA256(userId, the inbox's identity secret)` in lowercase hex. The secret is what stops
/// anybody from claiming to be anybody; an app that holds it hands that power to whoever unpacks the
/// binary. Your app asks your server for the hash once the user is signed in, and passes it here.
///
/// ```js
/// // On your server (Node). The secret is in the CNCT console, on the inbox's settings.
/// import { createHmac } from 'node:crypto';
/// app.get('/cnct-identity', requireSignedIn, (req, res) => {
///   const userId = String(req.user.id);
///   const userHash = createHmac('sha256', process.env.CNCT_IDENTITY_SECRET)
///     .update(userId)
///     .digest('hex');
///   res.json({ userId, userHash, name: req.user.firstName, email: req.user.email });
/// });
/// ```
public struct CnctChatIdentity: Sendable, Hashable {
  /// Your own id for this user. Stable: the same person is the same id on every device.
  public let userId: String

  /// `HMAC-SHA256(userId, secret)`, lowercase hex, from your server.
  public let userHash: String

  public let name: String?
  public let email: String?
  public let phone: String?

  public init(userId: String, userHash: String, name: String? = nil, email: String? = nil, phone: String? = nil) {
    self.userId = userId
    self.userHash = userHash
    self.name = name
    self.email = email
    self.phone = phone
  }

  var json: CnctJSON {
    let fields: [String: CnctJSON?] = [
      "userId": .string(userId),
      "userHash": .string(userHash),
      "name": Self.nonEmpty(name).map(CnctJSON.string),
      "email": Self.nonEmpty(email).map(CnctJSON.string),
      "phone": Self.nonEmpty(phone).map(CnctJSON.string),
    ]
    return .object(fields.compacted())
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
  }
}

// The hash signs a user in — whoever holds it can be them — and the contact details are a person's.
// Neither belongs in a log line, so printing an identity shows the user id alone.
extension CnctChatIdentity: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public var description: String { "CnctChatIdentity(userId: \(userId), userHash: ****)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["userId": userId, "userHash": "****"]) }
}
