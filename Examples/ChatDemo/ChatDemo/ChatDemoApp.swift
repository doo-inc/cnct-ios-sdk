import CNCT
import CNCTUI
import SwiftUI

@main
struct ChatDemoApp: App {
  /// Made once, here, rather than in a view: a client holds the socket and the session, and a view
  /// that SwiftUI rebuilds must not rebuild those with it. Nil without a key — the demo then runs on
  /// the scripted conversation.
  private let live: CnctChatClient?

  /// The scripted conversation for the "Your own UI" tab in fixture mode: no key, no network.
  private let fixture = CnctChatFixture.client(language: .en)

  init() {
    live = Self.makeChat()
  }

  var body: some Scene {
    WindowGroup {
      DemoRoot(live: live, fixture: fixture)
    }
  }

  /// Both values are build settings rather than constants in the source — see `Config.xcconfig`. The
  /// host is optional: without it the SDK goes to CNCT production, `https://app.doo.ooo`.
  private static func makeChat() -> CnctChatClient? {
    let info = Bundle.main.infoDictionary ?? [:]
    let key = (info["CNCTPublicKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    let host = (info["CNCTBaseURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
    guard let publicKey = try? CnctChatPublicKey(key) else { return nil }
    // One place holds the host. Everything the SDK does — HTTP and the socket alike — follows it,
    // because the socket origin is derived rather than configured separately.
    let cnct: Cnct
    if host.isEmpty {
      cnct = Cnct()
    } else {
      guard let other = try? Cnct(host: host) else { return nil }
      cnct = other
    }
    // The Keychain, so somebody who chatted last week comes back to their own thread.
    return cnct.chat(publicKey, tokenStore: CnctKeychainTokenStore())
  }
}

/// Three tabs: the ready-made screen, a screen of your own on the headless client, and the switches.
struct DemoRoot: View {
  let live: CnctChatClient?
  let fixture: CnctChatClient

  @AppStorage("demo.language") private var language = DemoLanguage.auto
  @AppStorage("demo.appearance") private var appearance = DemoAppearance.system
  @AppStorage("demo.customTheme") private var customTheme = false
  @AppStorage("demo.fixture") private var preferFixture = false

  /// With no key there is nothing else to run on.
  private var usingFixture: Bool { live == nil || preferFixture }

  var body: some View {
    TabView {
      chat
        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
      ChatScreen(chat: usingFixture ? fixture : live!)
        .id(usingFixture)
        .tabItem { Label("Your own UI", systemImage: "hammer") }
      DemoSettingsView(
        language: $language, appearance: $appearance, customTheme: $customTheme, preferFixture: $preferFixture,
        hasKey: live != nil
      )
      .tabItem { Label("Settings", systemImage: "gearshape") }
    }
  }

  /// `CnctChatView`, with the switches applied. The fixture is a conversation in one language, so a
  /// new language is a new fixture.
  @ViewBuilder private var chat: some View {
    if usingFixture {
      CnctChatView(fixture: language.chat, theme: theme, onEvent: { print("CNCT:", $0) })
        .id("fixture-\(language.rawValue)")
    } else if let live {
      CnctChatView(client: live, theme: theme, language: language.chat, onEvent: { print("CNCT:", $0) })
    }
  }

  private var theme: CnctChatTheme {
    var theme = customTheme ? CnctChatFixture.customTheme : CnctChatTheme()
    theme.appearance = appearance.chat
    return theme
  }
}
