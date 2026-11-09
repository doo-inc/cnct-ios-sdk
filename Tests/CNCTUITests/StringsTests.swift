import CNCT
import Foundation
import Testing

@testable import CNCTUI

/// The shared table, read from the spec folder in this repository — the source the bundled
/// `Localizable.strings` files are generated from.
private func sharedTable() throws -> [String: [String: String]] {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/chat-ui/strings.json")
  let data = try Data(contentsOf: url)
  return try JSONDecoder().decode([String: [String: String]].self, from: data)
}

@Suite("The words")
struct StringsTests {
  @Test("the bundled tables are strings.json, key for key and word for word")
  func tablesMatchTheSpec() throws {
    let shared = try sharedTable()
    for language in ["en", "ar"] {
      let bundled = CnctChatWords.load(language)
      let expected = try #require(shared[language])
      #expect(bundled.count == expected.count, "\(language): \(bundled.count) keys bundled, \(expected.count) in strings.json")
      #expect(Set(bundled.keys) == Set(expected.keys))
      for (key, value) in expected {
        #expect(bundled[key] == value, "\(language).\(key)")
      }
    }
  }

  @Test("English and Arabic have the same keys, and no Arabic word is empty")
  func sameKeys() throws {
    let english = CnctChatWords.load("en")
    let arabic = CnctChatWords.load("ar")
    #expect(english.count == 129)
    #expect(Set(english.keys) == Set(arabic.keys))
    for (key, value) in arabic {
      #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "ar.\(key) is empty")
    }
    // The words only a phone needs are in both languages too.
    #expect(Set(CnctChatWords.platform["en"]!.keys) == Set(CnctChatWords.platform["ar"]!.keys))
    #expect(Set(CnctChatWords.platform["en"]!.keys).isDisjoint(with: english.keys))
  }

  @Test("a word is looked up in the chosen language, with its values put in")
  func lookup() {
    let arabic = CnctChatWords(.ar)
    #expect(arabic("send") == "إرسال")
    #expect(arabic("tooBig", ["name": "photo.jpg"]) == "photo.jpg أكبر من 50 ميغابايت.")
    #expect(CnctChatWords(.en)("notTakingChats", ["business": "Demo Café"]) == "Demo Café is not taking chats right now")
    #expect(CnctChatWords(.auto).language == .en)
  }

  @Test("an app's override wins, and a word missing in Arabic is English, never its key")
  func fallback() {
    let words = CnctChatWords(.ar, overrides: CnctChatStrings(en: ["send": "Go", "onlyEnglish": "Only in English"], ar: ["writeMessage": "اكتب هنا…"]))
    #expect(words("writeMessage") == "اكتب هنا…")
    #expect(words("send") == "إرسال")  // the Arabic table before an English override
    #expect(words("onlyEnglish") == "Only in English")
    #expect(CnctChatWords(.en, overrides: CnctChatStrings(en: ["send": "Go"]))("send") == "Go")
  }
}

@Suite("Language")
struct LanguageTests {
  @Test(
    "auto takes the first of the device's languages that is Arabic or English",
    arguments: [
      (["ar-BH", "en-GB"], CnctChatLanguage.ar),
      (["fr-FR", "ar"], .ar),
      (["en-US", "ar-SA"], .en),
      (["fr-FR", "de-DE"], .en),
      ([String](), .en),
      (["AR_bh"], .ar),
    ]
  )
  func device(preferred: [String], expected: CnctChatLanguage) {
    #expect(CnctChatLanguage.pick(app: nil, server: .auto, preferred: preferred) == expected)
    #expect(CnctChatLanguage.pick(app: .auto, server: .en, preferred: preferred) == expected)
  }

  @Test("the app's choice, then the server's, then the device")
  func precedence() {
    #expect(CnctChatLanguage.pick(app: .en, server: .ar, preferred: ["ar"]) == .en)
    #expect(CnctChatLanguage.pick(app: nil, server: .ar, preferred: ["en"]) == .ar)
    #expect(CnctChatLanguage.pick(app: nil, server: nil, preferred: ["ar"]) == .ar)
  }

  @Test("Arabic writes Latin digits, and keeps the device's region where the device speaks it")
  func digits() {
    let locale = CnctChatLanguage.ar.locale(device: Locale(identifier: "ar_BH"))
    #expect(locale.identifier.contains("numbers=latn"))
    #expect(locale.identifier.hasPrefix("ar_BH"))
    #expect(CnctChatLanguage.ar.locale(device: Locale(identifier: "en_US")).identifier == "ar@numbers=latn")
    #expect(CnctChatLanguage.en.locale(device: Locale(identifier: "en_GB")).identifier == "en_GB")

    let format = CnctChatFormat(language: .ar, timeZone: TimeZone(identifier: "UTC")!)
    let time = format.clock(Date(timeIntervalSince1970: 14 * 3600 + 30 * 60))
    #expect(time.contains("2:30") || time.contains("14:30"), "\(time)")
    #expect(!time.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }, "Arabic-Indic digits in \(time)")
  }
}

@Suite("Formatting")
struct FormatTests {
  let utc = TimeZone(identifier: "UTC")!

  @Test("sizes are decimal, one decimal place from a megabyte up")
  func sizes() {
    let english = CnctChatFormat(language: .en, timeZone: utc)
    #expect(english.size(1_200_000) == "1.2 MB")
    #expect(english.size(220_000) == "220 KB")
    #expect(english.size(512) == "512 bytes")
    let arabic = CnctChatFormat(language: .ar, timeZone: utc)
    #expect(arabic.size(1_200_000) == "1.2 ميغابايت")
    #expect(arabic.size(220_000) == "220 كيلوبايت")
  }

  @Test("days read as words, older ones as the date")
  func days() {
    let format = CnctChatFormat(language: .en, timeZone: utc)
    let words = CnctChatWords(.en)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(format.dayLabel(now.addingTimeInterval(-60), now: now, words: words) == "Today")
    #expect(format.dayLabel(now.addingTimeInterval(-86_400), now: now, words: words) == "Yesterday")
    #expect(format.ended(now.addingTimeInterval(-60), now: now, words: words) == "Conversation ended today")
    #expect(format.ended(now.addingTimeInterval(-5 * 86_400), now: now, words: words).hasPrefix("Conversation ended on "))
  }

  @Test("the team is back today, tomorrow, or on a weekday, and the assistant is mentioned when it can help")
  func back() {
    let format = CnctChatFormat(language: .en, locale: Locale(identifier: "en_GB"), timeZone: utc)
    let words = CnctChatWords(.en)
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // a Friday, 08:00 UTC
    let later = format.availability(.back(at: now.addingTimeInterval(3600), assistantNow: false), now: now, words: words)
    #expect(later == "The team is back today at 09:00")
    let tomorrow = format.availability(.back(at: now.addingTimeInterval(86_400), assistantNow: true), now: now, words: words)
    #expect(tomorrow == "The team is back tomorrow at 08:00 · our assistant can help now")
    let monday = format.availability(.back(at: now.addingTimeInterval(3 * 86_400), assistantNow: false), now: now, words: words)
    #expect(monday == "The team is back Monday at 08:00")
    #expect(format.availability(.replyFew, words: words) == "Usually replies in a few minutes")
  }
}
