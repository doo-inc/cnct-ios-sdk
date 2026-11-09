import Foundation

/// How an inbox's chat looks and behaves, as the business set it up in the CNCT console.
///
/// The same configuration the hosted chat page reads, so a business that brands its chat once in
/// the console gets the same chat on the web and in an app. Every section is merged over the
/// defaults one by one, exactly as the server merges — a response from a deployment that predates a
/// field must not leave an app reading a blank where a default belongs.
public struct CnctChatWidget: Sendable, Hashable {
  public let brand: Brand
  public let chat: Chat

  /// The whole configuration as the server sent it, for the sections this SDK does not model — the
  /// web launcher and the hosted page's home screen.
  public let raw: CnctJSON

  /// What an app shows before the server has said otherwise, and what it keeps showing for a server
  /// that does not send a widget at all.
  public static let defaults = CnctChatWidget(json: .null)

  public init(brand: Brand, chat: Chat, raw: CnctJSON = .null) {
    self.brand = brand
    self.chat = chat
    self.raw = raw
  }

  public init(json: CnctJSON) {
    self.init(
      brand: Brand(json: json["brand"] ?? .null),
      chat: Chat(json: json["chat"] ?? .null),
      raw: json
    )
  }

  /// The business's look.
  public struct Brand: Sendable, Hashable {
    /// The brand colour, `#rrggbb`. Anything that is not six hex digits is replaced by the default
    /// rather than passed on: a colour a UI cannot parse is a colour it draws as black.
    public let color: String

    /// Light, dark, or whatever the device is set to.
    public let appearance: CnctWidgetAppearance

    /// The name the business wants shown, where it differs from its account name. Already folded
    /// into ``CnctChatInbox/business`` by the server; here for completeness.
    public let businessName: String?

    /// The business's logo. Nil means "draw the first letter of the name on the brand colour" —
    /// never an empty circle.
    public let avatarURL: URL?

    /// Which language the chat speaks: one the business pinned, or `auto` for the visitor's own.
    public let language: CnctWidgetLanguage

    /// Whether to show the "Powered by CNCT" line.
    public let showBranding: Bool

    /// The default brand colour, CNCT's own.
    public static let defaultColor = "#b52d93"

    public init(
      color: String = Brand.defaultColor,
      appearance: CnctWidgetAppearance = .light,
      businessName: String? = nil,
      avatarURL: URL? = nil,
      language: CnctWidgetLanguage = .auto,
      showBranding: Bool = true
    ) {
      self.color = Self.isHexColor(color) ? color : Self.defaultColor
      self.appearance = appearance
      self.businessName = businessName
      self.avatarURL = avatarURL
      self.language = language
      self.showBranding = showBranding
    }

    public init(json: CnctJSON) {
      self.init(
        color: json["color"]?.stringValue ?? Self.defaultColor,
        appearance: CnctWidgetAppearance(rawValue: json["appearance"]?.stringValue ?? "") ?? .light,
        businessName: json["businessName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
        avatarURL: Self.webURL(json["avatarUrl"]?.stringValue),
        language: CnctWidgetLanguage(rawValue: json["language"]?.stringValue ?? "") ?? .auto,
        showBranding: json["showBranding"]?.boolValue ?? true
      )
    }

    static func isHexColor(_ value: String) -> Bool {
      value.count == 7 && value.hasPrefix("#") && value.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// Only an http(s) address becomes a URL an app will load. Anything else is a logo that is not
    /// there, which is drawn as the letter.
    static func webURL(_ raw: String?) -> URL? {
      guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
        scheme == "https" || scheme == "http", url.host != nil
      else { return nil }
      return url
    }
  }

  /// What the visitor is allowed to do in the conversation.
  public struct Chat: Sendable, Hashable {
    /// Show the attach button. The server refuses files from an inbox that turned this off anyway;
    /// this is so the button is not there to be refused.
    public let allowAttachments: Bool

    /// The web page's emoji panel. Phones have one on the keyboard, so the native UIs ignore this.
    public let allowEmoji: Bool

    /// Offer "End chat" in the header.
    public let allowEndConversation: Bool

    /// Ask for a name before the first message, or let them type first.
    public let start: CnctChatStart

    /// Ask "How did we do?" when a conversation closes.
    public let askForRating: Bool

    public init(
      allowAttachments: Bool = true,
      allowEmoji: Bool = true,
      allowEndConversation: Bool = false,
      start: CnctChatStart = .details,
      askForRating: Bool = true
    ) {
      self.allowAttachments = allowAttachments
      self.allowEmoji = allowEmoji
      self.allowEndConversation = allowEndConversation
      self.start = start
      self.askForRating = askForRating
    }

    public init(json: CnctJSON) {
      self.init(
        allowAttachments: json["allowAttachments"]?.boolValue ?? true,
        allowEmoji: json["allowEmoji"]?.boolValue ?? true,
        allowEndConversation: json["allowEndConversation"]?.boolValue ?? false,
        start: CnctChatStart(rawValue: json["start"]?.stringValue ?? "") ?? .details,
        askForRating: json["askForRating"]?.boolValue ?? true
      )
    }
  }
}

/// Light, dark, or the device's own setting.
public enum CnctWidgetAppearance: String, Sendable, Hashable, CaseIterable {
  case light, dark
  /// Follow the device.
  case auto
}

/// The language a business pinned its chat to, or `auto` for the visitor's own.
public enum CnctWidgetLanguage: String, Sendable, Hashable, CaseIterable {
  case auto, en, ar
}

/// How a conversation begins.
public enum CnctChatStart: String, Sendable, Hashable, CaseIterable {
  /// Ask for a name (and a phone number where the inbox wants one) before anything else.
  case details
  /// Let them type first; the conversation starts with their first message, and the name is asked
  /// for in the thread afterwards.
  case message
}

/// Somebody who writes on the business's side: an operator, or the assistant.
///
/// **A first name and a face, never more.** The platform publishes enough for a customer to know who
/// is answering — "Sara" — and nothing that identifies a colleague beyond that.
public struct CnctChatSender: Sendable, Hashable {
  public enum Kind: String, Sendable, Hashable, CaseIterable {
    /// A person on the team.
    case person
    /// The business's assistant.
    case ai
    /// A kind added after this version of the SDK. Draw it as the business.
    case unknown
  }

  public let kind: Kind

  /// A first name, or nil when the platform has none to give — sign it with the business's name.
  public let name: String?

  /// For a person: the key of the face they chose in the console (`fox-clay`), not an image URL.
  public let avatar: String?

  /// For the assistant: the key of its mascot, and the colour it was given.
  public let mascot: String?
  public let colour: String?

  public init(kind: Kind, name: String? = nil, avatar: String? = nil, mascot: String? = nil, colour: String? = nil) {
    self.kind = kind
    self.name = name
    self.avatar = avatar
    self.mascot = mascot
    self.colour = colour
  }

  public init(json: CnctJSON) {
    self.init(
      kind: Kind(rawValue: json["kind"]?.stringValue ?? "") ?? .unknown,
      name: json["name"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
      avatar: json["avatar"]?.stringValue,
      mascot: json["mascot"]?.stringValue,
      colour: json["colour"]?.stringValue
    )
  }

  /// Nil for anything that is not an object — the visitor's own messages and the system's lines
  /// carry `null`.
  static func parse(_ json: CnctJSON?) -> CnctChatSender? {
    guard let json, json.objectValue != nil else { return nil }
    return CnctChatSender(json: json)
  }
}

/// Whether the team is in, when it is back, and how fast it really replies.
public struct CnctChatAvailability: Sendable, Hashable {
  /// True or false where the inbox has opening hours; nil where it has none, and there is nothing
  /// to be in or out of. A UI draws a presence dot only when this is not nil.
  public let open: Bool?

  /// When the team is back, while it is out.
  public let opensAt: Date?

  /// True when the assistant answers now, whatever the hours.
  public let assistant: Bool

  /// How long replies have really taken over the last month, in minutes. Nil without a
  /// measurement — and then nothing is promised.
  public let replyMinutes: Double?

  public init(open: Bool? = nil, opensAt: Date? = nil, assistant: Bool = false, replyMinutes: Double? = nil) {
    self.open = open
    self.opensAt = opensAt
    self.assistant = assistant
    self.replyMinutes = replyMinutes
  }

  public init(json: CnctJSON) {
    self.init(
      open: json["open"]?.boolValue,
      opensAt: CnctDates.parse(json["opensAt"]?.stringValue),
      assistant: json["assistant"]?.boolValue ?? false,
      replyMinutes: json["replyMinutes"]?.doubleValue
    )
  }

  /// **What the visitor can expect, said honestly** — the hosted chat page's sentence, as a value.
  ///
  /// Closed: when the team is back and whether the assistant can help meanwhile. Open: how fast
  /// replies have really come. Without a measurement it promises nothing it cannot keep. The words
  /// themselves are the UI's, in its language; this decides which ones.
  public var line: CnctAvailabilityLine {
    if open == false, let opensAt { return .back(at: opensAt, assistantNow: assistant) }
    guard let minutes = replyMinutes else { return assistant ? .assistantNow : .replyUnknown }
    if minutes < 1 { return assistant ? .assistantNow : .replyUnder1 }
    if minutes <= 5 { return .replyFew }
    if minutes <= 20 { return .reply20 }
    if minutes <= 60 { return .replyHour }
    if minutes <= 240 { return .replyHours }
    return .replyDay
  }

  /// The line for an inbox that says nothing about its availability.
  public static func line(for availability: CnctChatAvailability?) -> CnctAvailabilityLine {
    availability?.line ?? .replyUnknown
  }
}

/// Which availability sentence to show. Each case is named for the string key that says it.
public enum CnctAvailabilityLine: Sendable, Hashable {
  case replyUnder1, replyFew, reply20, replyHour, replyHours, replyDay, replyUnknown, assistantNow
  /// "The team is back today at 9:00" (or tomorrow, or on a weekday), followed by "our assistant can
  /// help now" when it can.
  case back(at: Date, assistantNow: Bool)
}
