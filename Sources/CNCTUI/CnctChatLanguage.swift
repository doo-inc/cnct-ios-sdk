import CNCT
import Foundation

/// The language the chat speaks.
///
/// Arabic is the whole interface right to left — header, composer, which side the bubbles sit on,
/// the icons that point — and Latin digits, as Gulf apps write them. Choosing a language never
/// changes the business's own words: a greeting, a flow's text and the team's messages are shown as
/// they were written.
public enum CnctChatLanguage: String, Sendable, Hashable, CaseIterable {
  /// The first of the device's preferred languages that is Arabic or English, else English.
  case auto
  case en
  case ar

  /// The language to speak.
  ///
  /// **Precedence: what the app passes, then the inbox's `brand.language` from the console, then
  /// the device.** `auto` at either level means the device: one install serves an Arabic phone in
  /// Arabic and an English phone in English.
  ///
  /// - Parameter preferred: The device's languages, most wanted first — `Locale.preferredLanguages`.
  public static func pick(
    app: CnctChatLanguage?,
    server: CnctWidgetLanguage?,
    preferred: [String] = Locale.preferredLanguages
  ) -> CnctChatLanguage {
    if let app, app != .auto { return app }
    if app == nil, let server, server != .auto { return server == .ar ? .ar : .en }
    for tag in preferred {
      let base = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
      if base == "ar" { return .ar }
      if base == "en" { return .en }
    }
    return .en
  }

  /// True for Arabic.
  public var isRightToLeft: Bool { self == .ar }

  /// The locale times, dates and sizes are written in: this language, with Latin digits.
  ///
  /// The device's own region is kept where the device speaks this language — so an English phone in
  /// Bahrain and one in London each keep their own clock — and digits are Latin in Arabic either
  /// way (`ar-u-nu-latn`).
  public func locale(device: Locale = .current) -> Locale {
    let code = self == .ar ? "ar" : "en"
    let deviceLanguage = device.identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
    var identifier = deviceLanguage == code ? device.identifier : code
    if let at = identifier.firstIndex(of: "@") { identifier = String(identifier[..<at]) }
    return Locale(identifier: self == .ar ? "\(identifier)@numbers=latn" : identifier)
  }
}

/// Per-language replacements for any of the chat's words, by key.
///
/// The keys are the shared table's (`docs/chat-ui/strings.json`), the same in every CNCT SDK; `{name}`
/// marks where a value goes. A key left out keeps the built-in words. Only the interface's own words
/// live here — the greeting and everything the team writes are the business's, and are shown as
/// written.
///
/// ```swift
/// CnctChatStrings(en: ["writeMessage": "Ask us anything…"], ar: ["writeMessage": "اسألنا عن أي شيء…"])
/// ```
public struct CnctChatStrings: Sendable, Hashable {
  public var en: [String: String]
  public var ar: [String: String]

  public init(en: [String: String] = [:], ar: [String: String] = [:]) {
    self.en = en
    self.ar = ar
  }

  func overrides(for language: CnctChatLanguage) -> [String: String] {
    language == .ar ? ar : en
  }
}

/// Every word the chat says, in one language — the shared table, the app's overrides, and the few
/// words only a phone needs.
public struct CnctChatWords: Sendable, Hashable {
  /// `en` or `ar` — never `auto`.
  public let language: CnctChatLanguage
  let overrides: CnctChatStrings

  public init(_ language: CnctChatLanguage, overrides: CnctChatStrings = CnctChatStrings()) {
    self.language = language == .ar ? .ar : .en
    self.overrides = overrides
  }

  /// The words for `key`, with each `{name}` in them replaced by its value.
  ///
  /// The chosen language first, the app's override before the built-in; then English, the same
  /// way. **A missing Arabic key is an English word, never the key itself** — a line a translation
  /// has not caught up with should still say something.
  public func callAsFunction(_ key: String, _ values: [String: String] = [:]) -> String {
    var text =
      overrides.overrides(for: language)[key]
      ?? Self.table(language)[key]
      ?? overrides.en[key]
      ?? Self.table(.en)[key]
      ?? key
    for (name, value) in values {
      text = text.replacingOccurrences(of: "{\(name)}", with: value)
    }
    return text
  }

  /// The built-in table for a language: the shared one from the bundle, plus this platform's own.
  static func table(_ language: CnctChatLanguage) -> [String: String] {
    language == .ar ? arabic : english
  }

  private static let english = load("en").merging(platform["en"] ?? [:]) { shared, _ in shared }
  private static let arabic = load("ar").merging(platform["ar"] ?? [:]) { shared, _ in shared }

  /// The shared table as shipped in `Localizable.strings`, generated from `strings.json`.
  static func load(_ language: String) -> [String: String] {
    guard
      let path = Bundle.module.path(
        forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language),
      let data = FileManager.default.contents(atPath: path),
      let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
    else { return [:] }
    return table
  }

  /// **The words only a phone needs**, kept apart from the shared table so that table stays
  /// identical to the web's and Android's. A browser's file input names its own sources; a phone's
  /// attach button opens a menu of three, and the menu needs words.
  static let platform: [String: [String: String]] = [
    "en": [
      "attachPhotos": "Photo library",
      "attachCamera": "Take a photo",
      "attachFiles": "Choose a file",
    ],
    "ar": [
      "attachPhotos": "مكتبة الصور",
      "attachCamera": "التقاط صورة",
      "attachFiles": "اختيار ملف",
    ],
  ]
}

/// Times, dates and sizes, written in the chat's language.
public struct CnctChatFormat: Sendable {
  public let language: CnctChatLanguage
  public let locale: Locale
  let calendar: Calendar
  let timeZone: TimeZone

  public init(language: CnctChatLanguage, locale: Locale? = nil, timeZone: TimeZone = .current) {
    self.language = language == .ar ? .ar : .en
    self.locale = locale ?? self.language.locale()
    self.timeZone = timeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = self.locale
    calendar.timeZone = timeZone
    self.calendar = calendar
  }

  private func formatter(_ template: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.calendar = calendar
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  /// "2:30 PM", "2:30 م" — the visitor's own clock, in the chat's language.
  public func clock(_ date: Date) -> String { formatter("jmm").string(from: date) }

  /// "Today", "Yesterday", or "8 September" — what heads each day in the thread.
  public func dayLabel(_ date: Date, now: Date = Date(), words: CnctChatWords) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return words("today") }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
      return words("yesterday")
    }
    return formatter("dMMMM").string(from: date)
  }

  /// "Conversation ended today", "… yesterday", "… on 8 September".
  public func ended(_ date: Date, now: Date = Date(), words: CnctChatWords) -> String {
    let label = dayLabel(date, now: now, words: words)
    let when: String
    if label == words("today") {
      when = words("endedToday")
    } else if label == words("yesterday") {
      when = words("endedYesterday")
    } else {
      when = words("endedOn", ["date": label])
    }
    return words("ended", ["when": when])
  }

  /// The availability sentence: "Usually replies in a few minutes", "The team is back tomorrow at
  /// 9:00 · our assistant can help now", in the visitor's clock.
  public func availability(_ line: CnctAvailabilityLine, now: Date = Date(), words: CnctChatWords) -> String {
    switch line {
    case .replyUnder1: return words("replyUnder1")
    case .replyFew: return words("replyFew")
    case .reply20: return words("reply20")
    case .replyHour: return words("replyHour")
    case .replyHours: return words("replyHours")
    case .replyDay: return words("replyDay")
    case .replyUnknown: return words("replyUnknown")
    case .assistantNow: return words("assistantNow")
    case .back(let at, let assistantNow):
      let time = clock(at)
      let back: String
      if calendar.isDate(at, inSameDayAs: now) {
        back = words("backToday", ["time": time])
      } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(at, inSameDayAs: tomorrow) {
        back = words("backTomorrow", ["time": time])
      } else {
        back = words("backOn", ["day": formatter("EEEE").string(from: at), "time": time])
      }
      return assistantNow ? words("backAssistant", ["back": back]) : back
    }
  }

  /// "1.2 MB", "220 KB" — or "1.2 ميغابايت" — in decimal units, as the system's file sizes are.
  public func size(_ bytes: Int) -> String {
    let units: [String] =
      language == .ar ? ["بايت", "كيلوبايت", "ميغابايت", "غيغابايت"] : ["bytes", "KB", "MB", "GB"]
    var value = Double(max(0, bytes))
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
      value /= 1000
      unit += 1
    }
    let number = NumberFormatter()
    number.locale = locale
    number.numberStyle = .decimal
    number.minimumFractionDigits = 0
    number.maximumFractionDigits = unit >= 2 ? 1 : 0
    let digits = number.string(from: NSNumber(value: unit >= 2 ? value : value.rounded())) ?? "\(value)"
    return "\(digits) \(units[unit])"
  }
}
