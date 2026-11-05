import CNCT
import SwiftUI

@main
struct ChatDemoApp: App {
  /// Made once, here, rather than in a view: the client holds the socket and the session, and a view
  /// that SwiftUI rebuilds must not rebuild those with it.
  private let chat: CnctChatClient?

  init() {
    chat = Self.makeChat()
  }

  var body: some Scene {
    WindowGroup {
      if let chat {
        ChatScreen(chat: chat)
      } else {
        MissingKey()
      }
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

private struct MissingKey: View {
  var body: some View {
    ContentUnavailableView {
      Label("No inbox key", systemImage: "key")
    } description: {
      Text(
        """
        Set CNCT_PUBLIC_KEY in Examples/ChatDemo/Local.xcconfig, or pass it to xcodebuild:

        CNCT_PUBLIC_KEY=your-inbox-public-key

        CNCT_BASE_URL is optional: without it the app talks to https://app.doo.ooo.
        """
      )
    }
  }
}
