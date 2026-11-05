import Foundation

/// Who said it.
public enum CnctSpeaker: String, Sendable, Hashable, CaseIterable {
  /// The visitor — the person using your app.
  case caller
  /// The assistant.
  case ai
  /// A human on the business's side. Never named: the platform publishes that somebody is with you,
  /// never who, and this SDK cannot show you what it is not sent.
  case `operator`
  /// The platform itself: a greeting, an out-of-hours notice, a "nobody is covering this" line.
  case system
  /// A speaker added after this version of the SDK was written. Render it as you would ``system``.
  case unknown

  /// The platform's spelling — `CALLER`, `AI`, `OPERATOR`, `SYSTEM` — and anything else as
  /// ``unknown``.
  public static func parse(_ raw: String?) -> CnctSpeaker {
    switch raw {
    case "CALLER": return .caller
    case "AI": return .ai
    case "OPERATOR": return .operator
    case "SYSTEM": return .system
    default: return .unknown
    }
  }

  /// True for anything that is not the visitor — the side of the bubble to draw it on.
  public var isFromBusiness: Bool { self != .caller }
}

/// Where a conversation is.
public enum CnctConversationStatus: String, Sendable, Hashable, CaseIterable {
  case open, snoozed, closed, unknown

  public static func parse(_ raw: String?) -> CnctConversationStatus {
    switch raw {
    case "OPEN": return .open
    case "SNOOZED": return .snoozed
    case "CLOSED": return .closed
    default: return .unknown
    }
  }
}

/// What to render a message as.
///
/// **Anything unrecognised is ``other``, with a `body` that reads as text, and that is the whole
/// compatibility story.** A card type added to the platform next year arrives at an app built today
/// with a `body` that reads correctly as a sentence — "We have opened ticket #1042 for this: Refund
/// not received" — so the app shows something true rather than an empty bubble. Handling a new card
/// is an opt-in improvement, never a required migration.
public enum CnctMessageType: String, Sendable, Hashable, CaseIterable {
  case text
  case ticketUpdate
  case bookingUpdate
  /// A card this SDK does not know. ``CnctChatMessage/rawType`` has its name and
  /// ``CnctChatMessage/data`` its fields; ``CnctChatMessage/body`` is always safe to show.
  case other

  public static func parse(_ raw: String?) -> CnctMessageType {
    switch raw {
    case "TICKET_UPDATE": return .ticketUpdate
    case "BOOKING_UPDATE": return .bookingUpdate
    case "TEXT": return .text
    default: return .other
    }
  }
}

/// What kind of file was sent.
public enum CnctAttachmentKind: String, Sendable, Hashable, CaseIterable {
  case image, video, audio, document, sticker, other

  public static func parse(_ raw: String?) -> CnctAttachmentKind {
    switch raw {
    case "IMAGE": return .image
    case "VIDEO": return .video
    case "AUDIO": return .audio
    case "DOCUMENT": return .document
    case "STICKER": return .sticker
    default: return .other
    }
  }
}

/// What the inbox says before anybody has typed. Readable without a session — it is the front door.
public struct CnctChatInbox: Sendable, Hashable {
  /// The business's name, for your header.
  public let business: String

  /// This inbox's name.
  public let inbox: String

  /// **False means do not open the composer.** The inbox is switched off; a session start will be
  /// refused. Say so rather than letting somebody type into something that will not accept it.
  public let isActive: Bool

  /// What to show before the first message.
  public let greeting: String

  /// True when this inbox wants a phone number before the conversation starts. Ask for it in your
  /// pre-chat step and pass it to `start(phone:)` — it is what joins this visitor to the contact
  /// record the business already has.
  public let requirePhone: Bool

  public init(business: String, inbox: String, isActive: Bool, greeting: String, requirePhone: Bool) {
    self.business = business
    self.inbox = inbox
    self.isActive = isActive
    self.greeting = greeting
    self.requirePhone = requirePhone
  }

  public init(json: CnctJSON) {
    self.init(
      business: json["business"]?.stringValue ?? "",
      inbox: json["inbox"]?.stringValue ?? "",
      isActive: json["isActive"]?.boolValue ?? false,
      greeting: json["greeting"]?.stringValue ?? "",
      requirePhone: json["requirePhone"]?.boolValue ?? false
    )
  }
}

/// The state of the visitor's own conversation.
public struct CnctChatConversation: Sendable, Hashable {
  public let status: CnctConversationStatus
  public let startedAt: Date

  /// True when somebody — an operator or the assistant — is on this thread. **Never who.** The
  /// platform does not publish a colleague's name to a customer, so "Sara is typing" is not
  /// something this SDK can offer and not something it will pretend to.
  public let withPerson: Bool

  public init(status: CnctConversationStatus, startedAt: Date, withPerson: Bool) {
    self.status = status
    self.startedAt = startedAt
    self.withPerson = withPerson
  }

  public init(json: CnctJSON) {
    self.init(
      status: CnctConversationStatus.parse(json["status"]?.stringValue),
      startedAt: CnctDates.parse(json["startedAt"]?.stringValue) ?? Date(),
      withPerson: json["withPerson"]?.boolValue ?? false
    )
  }
}

/// A ticket raised out of this conversation, where the inbox publishes them.
///
/// Off by default per inbox: a business that files a ticket for every awkward question has not
/// thereby agreed to tell the customer a case was opened.
public struct CnctTicketCard: Sendable, Hashable {
  /// What a customer quotes back to you.
  public let ticketNumber: Int
  public let title: String

  /// `OPEN`, `RESOLVED`, and the rest of the lifecycle. A string rather than an enum on purpose:
  /// the lifecycle is per account and a closed enum here would turn a client adding a status into
  /// a crash in somebody's app.
  public let status: String
  public let raisedAt: Date?

  public init(ticketNumber: Int, title: String, status: String, raisedAt: Date? = nil) {
    self.ticketNumber = ticketNumber
    self.title = title
    self.status = status
    self.raisedAt = raisedAt
  }

  /// The card in a message's `data`, or nil when there is no ticket number in it — a malformed card
  /// does not take the message down with it.
  public init?(data: [String: CnctJSON]?) {
    guard let data, let number = data["ticketNumber"]?.truncatedInt else { return nil }
    self.init(
      ticketNumber: number,
      title: data["title"]?.stringValue ?? "",
      status: data["status"]?.stringValue ?? "",
      raisedAt: CnctDates.parse(data["raisedAt"]?.text)
    )
  }
}

/// A booking taken, moved or cancelled in this conversation, where the inbox publishes them.
///
/// All three moments arrive, not just the first — a card that announces an appointment and goes
/// quiet when it moves leaves a stale time on a screen the customer has every reason to trust.
public struct CnctBookingCard: Sendable, Hashable {
  /// The service, or the booking's own title where there is no service.
  public let title: String

  /// **Render this in the customer's locale, not the business's.** It is an instant; format it with
  /// the device's own calendar and zone.
  public let startsAt: Date
  public let endsAt: Date?
  public let status: String

  /// Where to go. Nil where the business has one location.
  public let locationName: String?

  /// Nil unless the booking took one.
  public let partySize: Int?

  public init(
    title: String,
    startsAt: Date,
    endsAt: Date? = nil,
    status: String,
    locationName: String? = nil,
    partySize: Int? = nil
  ) {
    self.title = title
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.status = status
    self.locationName = locationName
    self.partySize = partySize
  }

  /// The card in a message's `data`, or nil when it has no start time to show.
  public init?(data: [String: CnctJSON]?) {
    guard let data, let startsAt = CnctDates.parse(data["startsAt"]?.text) else { return nil }
    self.init(
      title: data["title"]?.stringValue ?? "",
      startsAt: startsAt,
      endsAt: CnctDates.parse(data["endsAt"]?.text),
      status: data["status"]?.stringValue ?? "",
      locationName: data["locationName"]?.stringValue,
      partySize: data["partySize"]?.truncatedInt
    )
  }
}

/// A file sent with a message. Only files the platform actually holds are published, so anything in
/// this list can be fetched.
public struct CnctChatAttachment: Sendable, Hashable, Identifiable {
  public let id: String
  public let kind: CnctAttachmentKind
  public let mimeType: String
  public let filename: String?

  /// Size in bytes, where the platform recorded one.
  public let bytes: Int?

  public init(id: String, kind: CnctAttachmentKind, mimeType: String, filename: String? = nil, bytes: Int? = nil) {
    self.id = id
    self.kind = kind
    self.mimeType = mimeType
    self.filename = filename
    self.bytes = bytes
  }

  public init(json: CnctJSON) {
    self.init(
      id: json["id"]?.stringValue ?? "",
      kind: CnctAttachmentKind.parse(json["kind"]?.stringValue),
      mimeType: json["mimeType"]?.stringValue ?? "application/octet-stream",
      filename: json["filename"]?.stringValue,
      bytes: json["bytes"]?.truncatedInt
    )
  }
}

/// One message in the transcript.
public struct CnctChatMessage: Sendable, Hashable, Identifiable {
  public let id: String
  public let speaker: CnctSpeaker

  /// What to render this as. Unrecognised card types arrive as ``CnctMessageType/other``; ``body``
  /// is always safe to show.
  public let type: CnctMessageType

  /// The type exactly as the server named it, for the cards this SDK version has not met.
  public let rawType: String

  /// **Always reads correctly on its own**, card or not. This is the field a `default` branch shows.
  public let body: String
  public let createdAt: Date

  /// A card's fields, allowlisted by the server. Nil on ordinary text.
  public let data: [String: CnctJSON]?

  /// The visitor's own idempotency key, handed back so an optimistic bubble can be retired. Only
  /// ever present on the visitor's own messages — an operator's key is none of a visitor's business.
  public let clientKey: String?

  public let attachments: [CnctChatAttachment]

  /// In flight. Draw it, greyed.
  public internal(set) var pending: Bool

  /// The send failed. Offer a retry button wired to `CnctChatClient.retry(clientKey)` — retrying
  /// cannot double-post.
  public internal(set) var failed: Bool

  public init(
    id: String,
    speaker: CnctSpeaker,
    type: CnctMessageType,
    rawType: String,
    body: String,
    createdAt: Date,
    data: [String: CnctJSON]? = nil,
    clientKey: String? = nil,
    attachments: [CnctChatAttachment] = [],
    pending: Bool = false,
    failed: Bool = false
  ) {
    self.id = id
    self.speaker = speaker
    self.type = type
    self.rawType = rawType
    self.body = body
    self.createdAt = createdAt
    self.data = data
    self.clientKey = clientKey
    self.attachments = attachments
    self.pending = pending
    self.failed = failed
  }

  public init(json: CnctJSON) {
    let raw = json["type"].map { $0.isNull ? "TEXT" : $0.text } ?? "TEXT"
    self.init(
      id: json["id"]?.stringValue ?? "",
      speaker: CnctSpeaker.parse(json["speaker"]?.stringValue),
      type: CnctMessageType.parse(raw),
      rawType: raw,
      body: json["body"]?.stringValue ?? "",
      createdAt: CnctDates.parse(json["createdAt"]?.text) ?? Date(),
      data: json["data"]?.objectValue,
      clientKey: json["clientKey"]?.stringValue,
      attachments: json.objects("attachments").map(CnctChatAttachment.init(json:))
    )
  }

  /// A bubble drawn the moment somebody pressed send, before the server has it. Replaced in place
  /// by the stored row, matched on ``clientKey``.
  public static func optimistic(clientKey: String, body: String) -> CnctChatMessage {
    CnctChatMessage(
      id: "pending_\(clientKey)",
      speaker: .caller,
      type: .text,
      rawType: "TEXT",
      body: body,
      createdAt: Date(),
      clientKey: clientKey,
      pending: true
    )
  }

  /// The ticket card, when this is one. Nil otherwise.
  public var ticket: CnctTicketCard? { type == .ticketUpdate ? CnctTicketCard(data: data) : nil }

  /// The booking card, when this is one. Nil otherwise.
  public var booking: CnctBookingCard? { type == .bookingUpdate ? CnctBookingCard(data: data) : nil }
}

extension CnctChatMessage: CustomStringConvertible {
  public var description: String { "CnctChatMessage(\(speaker.rawValue), \(rawType), \"\(body)\")" }
}

/// The visitor, as the platform knows them. A display name and nothing else: this SDK is not told
/// which contact record they resolved to, and a customer-facing app has no use for one.
public struct CnctChatVisitor: Sendable, Hashable {
  public let displayName: String

  public init(displayName: String) {
    self.displayName = displayName
  }

  public init(json: CnctJSON) {
    self.init(displayName: json["displayName"]?.stringValue ?? "")
  }
}
