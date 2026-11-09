import Foundation

/// Who said it.
public enum CnctSpeaker: String, Sendable, Hashable, CaseIterable {
  /// The visitor — the person using your app.
  case caller
  /// The assistant.
  case ai
  /// A human on the business's side. Signed with a first name and a face — see
  /// ``CnctChatMessage/sender`` — and never more than that.
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
  case open, pending, snoozed, closed, unknown

  public static func parse(_ raw: String?) -> CnctConversationStatus {
    switch raw {
    case "OPEN": return .open
    case "PENDING": return .pending
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

  /// How the business set its chat up in the console: colour, appearance, logo, language, and what
  /// the visitor may do. Defaults, section by section, for anything the server left out.
  public let widget: CnctChatWidget

  /// A few of the people who answer, for a "who you will reach" line. First names and faces only.
  public let team: [CnctChatSender]

  /// Whether the team is in and how fast it replies. Nil from a server that does not say.
  public let availability: CnctChatAvailability?

  public init(
    business: String,
    inbox: String,
    isActive: Bool,
    greeting: String,
    requirePhone: Bool,
    widget: CnctChatWidget = .defaults,
    team: [CnctChatSender] = [],
    availability: CnctChatAvailability? = nil
  ) {
    self.business = business
    self.inbox = inbox
    self.isActive = isActive
    self.greeting = greeting
    self.requirePhone = requirePhone
    self.widget = widget
    self.team = team
    self.availability = availability
  }

  public init(json: CnctJSON) {
    self.init(
      business: json["business"]?.stringValue ?? "",
      inbox: json["inbox"]?.stringValue ?? "",
      isActive: json["isActive"]?.boolValue ?? false,
      greeting: json["greeting"]?.stringValue ?? "",
      requirePhone: json["requirePhone"]?.boolValue ?? false,
      widget: CnctChatWidget(json: json["widget"] ?? .null),
      team: json.objects("team").map(CnctChatSender.init(json:)),
      availability: json["availability"].flatMap { $0.objectValue == nil ? nil : CnctChatAvailability(json: $0) }
    )
  }

  /// The availability sentence to show in a header — ``CnctAvailabilityLine/replyUnknown`` when the
  /// server says nothing.
  public var availabilityLine: CnctAvailabilityLine { CnctChatAvailability.line(for: availability) }
}

/// How the visitor rated a conversation.
public struct CnctChatRating: Sendable, Hashable {
  /// One to five, worst to best.
  public let score: Int

  /// What they added, if they did.
  public let comment: String?
  public let ratedAt: Date?

  public init(score: Int, comment: String? = nil, ratedAt: Date? = nil) {
    self.score = score
    self.comment = comment
    self.ratedAt = ratedAt
  }

  /// Nil for anything without a score from one to five.
  init?(json: CnctJSON?) {
    guard let json, let score = json["score"]?.truncatedInt, (1...5).contains(score) else { return nil }
    self.init(
      score: score,
      comment: json["comment"]?.stringValue,
      ratedAt: CnctDates.parse(json["ratedAt"]?.stringValue)
    )
  }
}

/// The state of one of the visitor's conversations.
public struct CnctChatConversation: Sendable, Hashable, Identifiable {
  /// Empty from a server that predates conversation ids.
  public let id: String
  public internal(set) var status: CnctConversationStatus
  public let startedAt: Date

  /// When it closed, once it has.
  public internal(set) var closedAt: Date?

  /// True when somebody — an operator or the assistant — is on this thread.
  public internal(set) var withPerson: Bool

  /// The person it is assigned to, by first name and face, where there is one.
  public internal(set) var assignee: CnctChatSender?

  /// How far the team has read: everything the visitor wrote up to this instant has been seen. What
  /// a UI shows as "Seen" under the visitor's last words. Nil until somebody reads it.
  public internal(set) var seenAt: Date?

  /// Whether it can still be rated. Only a closed conversation can, and only for a while.
  public internal(set) var ratable: Bool

  /// The rating it was given, if any.
  public internal(set) var rating: CnctChatRating?

  /// When the last message was written. In the conversations list.
  public internal(set) var lastMessageAt: Date?

  /// The last message, for a conversations list. Nil on the conversation a session is in — its
  /// messages are in ``CnctChatState/messages``.
  public internal(set) var preview: CnctChatMessage?

  public init(
    id: String = "",
    status: CnctConversationStatus,
    startedAt: Date,
    withPerson: Bool,
    closedAt: Date? = nil,
    assignee: CnctChatSender? = nil,
    seenAt: Date? = nil,
    ratable: Bool = false,
    rating: CnctChatRating? = nil,
    lastMessageAt: Date? = nil,
    preview: CnctChatMessage? = nil
  ) {
    self.id = id
    self.status = status
    self.startedAt = startedAt
    self.withPerson = withPerson
    self.closedAt = closedAt
    self.assignee = assignee
    self.seenAt = seenAt
    self.ratable = ratable
    self.rating = rating
    self.lastMessageAt = lastMessageAt
    self.preview = preview
  }

  public init(json: CnctJSON) {
    self.init(
      id: json["id"]?.stringValue ?? "",
      status: CnctConversationStatus.parse(json["status"]?.stringValue),
      startedAt: CnctDates.parse(json["startedAt"]?.stringValue) ?? Date(),
      withPerson: json["withPerson"]?.boolValue ?? false,
      closedAt: CnctDates.parse(json["closedAt"]?.stringValue),
      assignee: CnctChatSender.parse(json["assignee"]),
      seenAt: CnctDates.parse(json["seenAt"]?.stringValue),
      ratable: json["ratable"]?.boolValue ?? false,
      rating: CnctChatRating(json: json["rating"]),
      lastMessageAt: CnctDates.parse(json["lastMessageAt"]?.stringValue),
      preview: json["preview"].flatMap { $0.objectValue == nil ? nil : CnctChatMessage(json: $0) }
    )
  }

  /// True until it closes.
  public var isLive: Bool { status != .closed }

  /// A change the server announced — `chat.conversation.updated` — laid over what is known. Only
  /// the fields it carries move; a missing field is not a cleared one.
  func patched(with json: CnctJSON) -> CnctChatConversation {
    var next = self
    if let status = json["status"]?.stringValue { next.status = CnctConversationStatus.parse(status) }
    if let withPerson = json["withPerson"]?.boolValue { next.withPerson = withPerson }
    if let assignee = json["assignee"] { next.assignee = CnctChatSender.parse(assignee) }
    if let closedAt = json["closedAt"] { next.closedAt = CnctDates.parse(closedAt.stringValue) }
    if let seenAt = json["seenAt"]?.stringValue { next.seenAt = CnctDates.parse(seenAt) ?? next.seenAt }
    if let ratable = json["ratable"]?.boolValue { next.ratable = ratable }
    if let rating = json["rating"] { next.rating = CnctChatRating(json: rating) }
    return next
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

/// What kind of answer a flow's question is waiting for — and so which keyboard to show.
public enum CnctFlowExpects: String, Sendable, Hashable, CaseIterable {
  case name, number, email, phone, date
}

/// An assistant's message from a flow: words, perhaps a picture, and choices to tap.
///
/// On the web a flow message's ``CnctChatMessage/body`` is numbered text — "1. Book a visit …
/// Reply with the number" — because that reads correctly anywhere that knows nothing of flows. A UI
/// that does know draws ``text``, ``media`` and ``footer`` itself and offers ``choices`` as buttons.
public struct CnctChatFlow: Sendable, Hashable {
  public enum Layout: String, Sendable, Hashable, CaseIterable {
    /// Short choices, side by side.
    case buttons
    /// A list, opened from ``CnctChatFlow/listButton``, where choices often carry a description.
    case list
  }

  public struct Choice: Sendable, Hashable, Identifiable {
    /// What goes back as `replyId` when this is tapped.
    public let id: String
    /// What goes back as the message body when this is tapped — the visitor's own words.
    public let title: String
    public let description: String?

    public init(id: String, title: String, description: String? = nil) {
      self.id = id
      self.title = title
      self.description = description
    }
  }

  /// A picture, film or document above the words. Always a public http(s) address.
  public struct Media: Sendable, Hashable {
    /// `image`, `video`, or anything else (drawn as a document).
    public let kind: String
    public let url: URL
    public let filename: String?

    public init(kind: String, url: URL, filename: String? = nil) {
      self.kind = kind
      self.url = url
      self.filename = filename
    }
  }

  /// The words to show. Nil on a message stored before the server sent them — draw its body.
  public let text: String?
  public let layout: Layout

  /// Only choices with both an id and a title survive; a choice that cannot be sent back is not
  /// offered.
  public let choices: [Choice]
  public let footer: String?

  /// The label of the button that opens a list.
  public let listButton: String?
  public let media: Media?

  /// What a question is waiting for, when it asks for an answer rather than offering choices.
  public let expects: CnctFlowExpects?

  public init(
    text: String?,
    layout: Layout = .buttons,
    choices: [Choice] = [],
    footer: String? = nil,
    listButton: String? = nil,
    media: Media? = nil,
    expects: CnctFlowExpects? = nil
  ) {
    self.text = text
    self.layout = layout
    self.choices = choices
    self.footer = footer
    self.listButton = listButton
    self.media = media
    self.expects = expects
  }

  init?(json: CnctJSON?) {
    guard let json, json.objectValue != nil else { return nil }
    let choices = json.objects("choices").compactMap { choice -> Choice? in
      guard let id = choice["id"]?.stringValue, let title = choice["title"]?.stringValue else { return nil }
      return Choice(id: id, title: title, description: choice["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
    }
    var media: Media?
    if let raw = json["media"], let url = CnctChatWidget.Brand.webURL(raw["url"]?.stringValue) {
      media = Media(kind: raw["kind"]?.stringValue ?? "document", url: url, filename: raw["filename"]?.stringValue)
    }
    self.init(
      text: json["text"]?.stringValue,
      layout: Layout(rawValue: json["layout"]?.stringValue ?? "") ?? .buttons,
      choices: choices,
      footer: json["footer"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
      listButton: json["listButton"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
      media: media,
      expects: CnctFlowExpects(rawValue: json["expects"]?.stringValue ?? "")
    )
  }

  /// True when a UI should draw this from its parts rather than from the message's body.
  public var drawsAsFlow: Bool { text != nil }

  /// True when the choices want rows rather than pills: a list, or any choice with a description,
  /// which needs the width.
  public var choicesAsRows: Bool { layout == .list || choices.contains { $0.description != nil } }
}

/// An earlier message this one replies to, as the platform quoted it.
///
/// The words are the server's snapshot of the quoted row, so nothing here is anything the quoting
/// side made up.
public struct CnctChatQuote: Sendable, Hashable {
  /// The quoted message, where it is in this conversation — scroll to it.
  public let messageId: String?

  /// True when the quoted message is the visitor's own: "You".
  public let mine: Bool

  /// Its first words. Nil for a file with no words — say what kind of file it was instead.
  public let excerpt: String?

  /// What it was, when it was a file.
  public let attachmentKind: CnctAttachmentKind?

  public init(messageId: String? = nil, mine: Bool = false, excerpt: String? = nil, attachmentKind: CnctAttachmentKind? = nil) {
    self.messageId = messageId
    self.mine = mine
    self.excerpt = excerpt
    self.attachmentKind = attachmentKind
  }

  init?(json: CnctJSON?) {
    guard let json, json.objectValue != nil else { return nil }
    self.init(
      messageId: json["messageId"]?.stringValue,
      mine: json["mine"]?.boolValue ?? false,
      excerpt: json["excerpt"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
      attachmentKind: json["attachmentKind"]?.stringValue.map(CnctAttachmentKind.parse)
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

  /// Who wrote it, for the face and the first name beside it. Nil for the visitor's own messages and
  /// for the system's lines.
  public let sender: CnctChatSender?

  /// The flow's parts, on an assistant's message from a flow. Nil otherwise.
  public let flow: CnctChatFlow?

  /// Short replies the assistant offers with this message, to show as chips. At most three, never
  /// empty strings.
  public let suggestions: [String]

  /// The earlier message this one replies to.
  public let replyTo: CnctChatQuote?

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
    sender: CnctChatSender? = nil,
    flow: CnctChatFlow? = nil,
    suggestions: [String] = [],
    replyTo: CnctChatQuote? = nil,
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
    self.sender = sender
    self.flow = flow
    self.suggestions = suggestions
    self.replyTo = replyTo
    self.pending = pending
    self.failed = failed
  }

  public init(json: CnctJSON) {
    let raw = json["type"].map { $0.isNull ? "TEXT" : $0.text } ?? "TEXT"
    let suggestions = (json["suggestions"]?.arrayValue ?? [])
      .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    self.init(
      id: json["id"]?.stringValue ?? "",
      speaker: CnctSpeaker.parse(json["speaker"]?.stringValue),
      type: CnctMessageType.parse(raw),
      rawType: raw,
      body: json["body"]?.stringValue ?? "",
      createdAt: CnctDates.parse(json["createdAt"]?.text) ?? Date(),
      data: json["data"]?.objectValue,
      clientKey: json["clientKey"]?.stringValue,
      attachments: json.objects("attachments").map(CnctChatAttachment.init(json:)),
      sender: CnctChatSender.parse(json["sender"]),
      flow: CnctChatFlow(json: json["flow"]),
      suggestions: Array(suggestions.prefix(3)),
      replyTo: CnctChatQuote(json: json["replyTo"])
    )
  }

  /// A bubble drawn the moment somebody pressed send, before the server has it. Replaced in place
  /// by the stored row, matched on ``clientKey``.
  public static func optimistic(
    clientKey: String,
    body: String,
    attachments: [CnctChatAttachment] = []
  ) -> CnctChatMessage {
    CnctChatMessage(
      id: "pending_\(clientKey)",
      speaker: .caller,
      type: .text,
      rawType: "TEXT",
      body: body,
      createdAt: Date(),
      clientKey: clientKey,
      attachments: attachments,
      pending: true
    )
  }

  /// The ticket card, when this is one. Nil otherwise.
  public var ticket: CnctTicketCard? { type == .ticketUpdate ? CnctTicketCard(data: data) : nil }

  /// The booking card, when this is one. Nil otherwise.
  public var booking: CnctBookingCard? { type == .bookingUpdate ? CnctBookingCard(data: data) : nil }

  /// What this message says in words: a flow's own text where it has one, its body otherwise.
  public var words: String {
    if let flow, let text = flow.text { return text }
    return body
  }

  /// True for a message from the business's side — the assistant or a person — with a real id: the
  /// kind of message the visitor reading it is worth telling the team about.
  public var isReply: Bool { (speaker == .operator || speaker == .ai) && !id.isEmpty && !pending }
}

extension CnctChatMessage: CustomStringConvertible {
  public var description: String { "CnctChatMessage(\(speaker.rawValue), \(rawType), \"\(body)\")" }
}

/// The visitor, as the platform knows them. A display name and two facts about it: this SDK is
/// not told which contact record they resolved to, and a customer-facing app has no use for one.
public struct CnctChatVisitor: Sendable, Hashable {
  public let displayName: String

  /// True until they have given a name. A UI asks for one in the thread once they have said
  /// something.
  public let anonymous: Bool

  /// True when the app signed them in with ``CnctChatIdentity`` — their conversations follow them
  /// between devices.
  public let identified: Bool

  public init(displayName: String, anonymous: Bool = false, identified: Bool = false) {
    self.displayName = displayName
    self.anonymous = anonymous
    self.identified = identified
  }

  public init(json: CnctJSON) {
    self.init(
      displayName: json["displayName"]?.stringValue ?? "",
      anonymous: json["anonymous"]?.boolValue ?? false,
      identified: json["identified"]?.boolValue ?? false
    )
  }
}
