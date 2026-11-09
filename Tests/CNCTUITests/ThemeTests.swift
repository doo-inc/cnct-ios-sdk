import CNCT
import Foundation
import Testing

@testable import CNCTUI

private func widget(_ brand: CnctJSON) -> CnctChatWidget { CnctChatWidget(json: ["brand": brand]) }

@Suite("Theme")
struct ThemeTests {
  @Test("with nothing from the app or the server, the defaults")
  func defaults() {
    let light = CnctChatTheme().resolved(widget: nil, business: "Demo Café", systemIsDark: false)
    #expect(light.primary == "#b52d93")
    #expect(light.onPrimary == .white)
    #expect(light.background == "#ffffff")
    #expect(light.surface == "#f6f7f9")
    #expect(light.text == "#111418")
    #expect(light.textMuted == "#5b6573")
    #expect(light.border == "#e3e6ea")
    #expect(light.visitorBubble == light.primary)
    #expect(light.onVisitorBubble == light.onPrimary)
    #expect(light.agentBubble == light.surface)
    #expect(light.onAgentBubble == light.text)
    #expect(light.cornerRadius == 18)
    #expect(light.font == .system)
    #expect(light.logo == nil)
    #expect(light.title == "Demo Café")
    #expect(light.letter == "D")
    #expect(light.showPoweredBy)
    // The default widget is light, as the hosted page's is, until the console says otherwise.
    #expect(light.isDark == false)
  }

  @Test("the server's widget settings come next")
  func server() {
    let resolved = CnctChatTheme().resolved(
      widget: widget(["color": "#ffd400", "appearance": "dark", "avatarUrl": "https://cdn.test/logo.png", "showBranding": false]),
      business: "Demo Café", systemIsDark: false)
    #expect(resolved.primary == "#ffd400")
    // A light brand colour gets dark ink.
    #expect(resolved.onPrimary == "#141414")
    #expect(resolved.isDark)
    #expect(resolved.background == "#0f1115")
    #expect(resolved.surface == "#171a21")
    #expect(resolved.text == "#eef0f3")
    #expect(resolved.textMuted == "#9aa3af")
    #expect(resolved.border == "#2a2f38")
    #expect(resolved.logo == .url(URL(string: "https://cdn.test/logo.png")!))
    #expect(resolved.showPoweredBy == false)
  }

  @Test("what the app passes wins over the server and the defaults")
  func app() {
    let theme = CnctChatTheme(
      primary: "#D7262E", cornerRadius: 8, font: .named("Georgia"), logo: .image(Data([1, 2, 3])), title: "Help",
      appearance: .light, showPoweredBy: true)
    let resolved = theme.resolved(
      widget: widget(["color": "#ffd400", "appearance": "dark", "avatarUrl": "https://cdn.test/logo.png", "showBranding": false]),
      business: "Demo Café", systemIsDark: true)
    #expect(resolved.primary == "#d7262e")
    #expect(resolved.onPrimary == .white)
    #expect(resolved.isDark == false)
    #expect(resolved.background == "#ffffff")
    #expect(resolved.cornerRadius == 8)
    #expect(resolved.font == .named("Georgia"))
    #expect(resolved.logo == .image(Data([1, 2, 3])))
    #expect(resolved.title == "Help")
    #expect(resolved.letter == "D")
    #expect(resolved.showPoweredBy)
  }

  @Test("system, and the server's auto, follow the device")
  func system() {
    let auto = widget(["appearance": "auto"])
    #expect(CnctChatTheme().resolved(widget: auto, business: "", systemIsDark: true).isDark)
    #expect(CnctChatTheme().resolved(widget: auto, business: "", systemIsDark: false).isDark == false)
    #expect(CnctChatTheme(appearance: .system).resolved(widget: widget(["appearance": "light"]), business: "", systemIsDark: true).isDark)
    #expect(CnctChatTheme(appearance: .dark).resolved(widget: nil, business: "", systemIsDark: false).isDark)
  }

  @Test("light and dark can differ, and each falls back on its own")
  func perAppearance() {
    var theme = CnctChatTheme(primary: "#0057b8")
    theme.dark.primary = "#a7f3d0"
    theme.dark.background = "#000000"
    let light = theme.resolved(widget: nil, business: "", systemIsDark: false)
    let dark = CnctChatTheme(light: theme.light, dark: theme.dark, appearance: .dark).resolved(widget: nil, business: "", systemIsDark: false)
    #expect(light.primary == "#0057b8")
    #expect(light.background == "#ffffff")
    #expect(dark.primary == "#a7f3d0")
    #expect(dark.onPrimary == "#141414")
    #expect(dark.background == "#000000")
    #expect(dark.surface == "#171a21")
  }

  @Test("a recoloured bubble gets ink chosen for its own colour")
  func bubbleInk() {
    let resolved = CnctChatTheme(primary: "#b52d93", visitorBubble: "#fde68a", agentBubble: "#1f2937")
      .resolved(widget: nil, business: "", systemIsDark: false)
    #expect(resolved.onVisitorBubble == "#141414")
    #expect(resolved.onAgentBubble == .white)
    let pinned = CnctChatTheme(visitorBubble: "#fde68a", onVisitorBubble: "#7c2d12").resolved(widget: nil, business: "", systemIsDark: false)
    #expect(pinned.onVisitorBubble == "#7c2d12")
  }

  @Test(
    "onPrimary is the hosted page's contrast rule: near-black on a light colour, white on a dark one",
    arguments: [
      ("#b52d93", "#ffffff"), ("#D7262E", "#ffffff"), ("#ffd400", "#141414"), ("#ffffff", "#141414"),
      ("#000000", "#ffffff"), ("#a7f3d0", "#141414"), ("#0057b8", "#ffffff"), ("#22c55e", "#ffffff"),
    ]
  )
  func contrastRule(brand: String, ink: String) {
    let color = CnctChatColor(hex: brand)!
    #expect(color.readableInk == CnctChatColor(hex: ink)!)
  }

  @Test("the defaults keep text at 4.5:1 or better, in light and dark")
  func defaultContrast() {
    for dark in [false, true] {
      let theme = CnctChatTheme().resolved(widget: nil, business: "", systemIsDark: dark)
      let resolved = dark ? CnctChatTheme(appearance: .dark).resolved(widget: nil, business: "", systemIsDark: true) : theme
      #expect(resolved.text.contrast(with: resolved.background) >= 4.5)
      #expect(resolved.textMuted.contrast(with: resolved.background) >= 4.5)
      #expect(resolved.onAgentBubble.contrast(with: resolved.agentBubble) >= 4.5)
      #expect(resolved.onPrimary.contrast(with: resolved.primary) >= 4.5)
    }
    let custom = CnctChatFixture.customTheme.resolved(widget: nil, business: "", systemIsDark: false)
    #expect(custom.onPrimary.contrast(with: custom.primary) >= 4.5)
  }

  @Test("words in the brand colour read at 4.5:1, and the brand colour is left alone where it already does")
  func primaryText() {
    for dark in [false, true] {
      for brand in ["#b52d93", "#D7262E", "#ffd400", "#0057b8", "#22c55e"] {
        let resolved = CnctChatTheme(primary: CnctChatColor(hex: brand)!, appearance: dark ? .dark : .light)
          .resolved(widget: nil, business: "", systemIsDark: false)
        #expect(resolved.primaryText.contrast(with: resolved.background) >= 4.5, "\(brand) on \(dark ? "dark" : "light")")
        #expect(resolved.primaryText.contrast(with: resolved.surface) >= 4.5, "\(brand) on \(dark ? "dark" : "light")")
      }
    }
    let untouched = CnctChatTheme().resolved(widget: nil, business: "", systemIsDark: false)
    #expect(untouched.primaryText == untouched.primary)
  }

  @Test("colours parse in the three hex forms, and nothing else")
  func hex() {
    #expect(CnctChatColor(hex: "#fff") == .white)
    #expect(CnctChatColor(hex: "D7262E")?.hex == "#d7262e")
    #expect(CnctChatColor(hex: "#00000080")?.alpha == 128.0 / 255)
    #expect(CnctChatColor(hex: "red") == nil)
    #expect(CnctChatColor(hex: "#12345") == nil)
  }

  @Test("a business with no name is a question mark, never an empty disc")
  func letter() {
    #expect(CnctChatTheme.initial("  ") == "?")
    #expect(CnctChatTheme.initial("مقهى") == "م")
    #expect(CnctChatTheme.initial("demo") == "D")
  }
}

@Suite("Text direction")
struct BidiTests {
  @Test(
    "a piece of text takes the direction of its first strong character",
    arguments: [
      ("Do you open on Fridays?", CnctTextDirection.leftToRight),
      ("هل تفتحون يوم الجمعة؟", .rightToLeft),
      ("+973 3311 2233 اتصلوا بي", .rightToLeft),
      ("12:30 — ok", .leftToRight),
      ("👍", .neutral),
      ("١٢٣", .neutral),
      ("  “שלום”", .rightToLeft),
      ("", .neutral),
    ]
  )
  func direction(text: String, expected: CnctTextDirection) {
    #expect(CnctBidi.direction(of: text) == expected)
  }

  @Test("a phone number inside an Arabic sentence is kept left to right")
  func phoneIsolated() {
    let line = "اتصلوا بي على +973 3311 2233 من فضلك"
    #expect(CnctBidi.isolated(line) == "اتصلوا بي على \u{2066}+973 3311 2233\u{2069} من فضلك")
    #expect(CnctBidi.isolated("Call me on +973 3311 2233 please").contains("\u{2066}+973 3311 2233\u{2069}"))
  }

  @Test("emails and web addresses are kept left to right, and only web addresses are links")
  func links() {
    let runs = CnctBidi.runs("راسلنا على help@demo.test أو www.demo.test/menu.")
    #expect(runs.filter(\.keepsLeftToRight).map(\.text) == ["help@demo.test", "www.demo.test/menu"])
    #expect(runs.compactMap(\.link) == [URL(string: "https://www.demo.test/menu")!])
    // The full stop after an address is the sentence's, not the address's.
    #expect(runs.last?.text == ".")
    let https = CnctBidi.runs("Pay at HTTPS://pay.demo.test/x?y=1, thanks")
    #expect(https.compactMap(\.link) == [URL(string: "HTTPS://pay.demo.test/x?y=1")!])
    #expect(CnctBidi.runs("javascript:alert(1)").compactMap(\.link).isEmpty)
  }

  @Test("a time, a price or a short number is not a phone number")
  func notPhones() {
    for text in ["from 2pm to 10pm", "BD 12.500", "room 42", "at 14:30"] {
      #expect(CnctBidi.runs(text).allSatisfy { !$0.keepsLeftToRight }, "\(text)")
    }
  }
}
