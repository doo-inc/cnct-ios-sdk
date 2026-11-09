#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  /// **A ready-made chat screen**, branded from the CNCT console or from code, in English or Arabic.
  ///
  /// Built only on the public headless client: what it does, an app building its own screen can do
  /// too. Give it the client, or just the inbox's public key:
  ///
  /// ```swift
  /// import CNCTUI
  ///
  /// struct SupportView: View {
  ///   var body: some View {
  ///     CnctChatView(publicKey: try! CnctChatPublicKey("your-inbox-public-key"))
  ///   }
  /// }
  /// ```
  ///
  /// The options are the same in every CNCT SDK: `theme`, `language`, `strings`, `identity`,
  /// `onClose` and `onEvent`.
  public struct CnctChatView: View {
    @StateObject private var model: CnctChatModel
    private let theme: CnctChatTheme
    private let language: CnctChatLanguage?
    private let strings: CnctChatStrings
    private let onClose: (() -> Void)?
    private let onEvent: ((CnctChatUIEvent) -> Void)?

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase

    /// The chat on a client the app made — and keeps: the screen never disposes it.
    ///
    /// - Parameters:
    ///   - theme: Colours, corner radius, font, logo, title, appearance. What is left out comes from
    ///     the inbox's settings in the CNCT console, then from the defaults.
    ///   - language: `auto`, `en` or `ar`. The console's choice when left out, then the device's.
    ///   - strings: Replacements for any of the chat's words, per language.
    ///   - identity: Who your app has signed in, with the hash from your server. Applied before any
    ///     conversation is read. A failure is logged and the visitor chats anonymously.
    ///   - onClose: Shows a close button in the header, and is called when it is tapped.
    ///   - onEvent: Called as the visitor opens, starts, sends, sends files, ends and rates — for
    ///     analytics. Never carries what anybody wrote.
    public init(
      client: CnctChatClient,
      theme: CnctChatTheme = CnctChatTheme(),
      language: CnctChatLanguage? = nil,
      strings: CnctChatStrings = CnctChatStrings(),
      identity: CnctChatIdentity? = nil,
      onClose: (() -> Void)? = nil,
      onEvent: ((CnctChatUIEvent) -> Void)? = nil
    ) {
      _model = StateObject(wrappedValue: CnctChatModel(client: client, ownsClient: false, identity: identity))
      self.theme = theme
      self.language = language
      self.strings = strings
      self.onClose = onClose
      self.onEvent = onEvent
    }

    /// The chat on an inbox's public key. The screen makes the client, keeps the visitor's session
    /// in the Keychain so they come back to their own conversation, and lets the client go with the
    /// screen.
    ///
    /// - Parameters:
    ///   - cnct: Where CNCT is. Production, `https://app.doo.ooo`, by default.
    ///   - tokenStore: Where the visitor's session is kept. The Keychain by default.
    public init(
      publicKey: CnctChatPublicKey,
      cnct: Cnct = Cnct(),
      tokenStore: (any CnctTokenStore)? = nil,
      theme: CnctChatTheme = CnctChatTheme(),
      language: CnctChatLanguage? = nil,
      strings: CnctChatStrings = CnctChatStrings(),
      identity: CnctChatIdentity? = nil,
      onClose: (() -> Void)? = nil,
      onEvent: ((CnctChatUIEvent) -> Void)? = nil
    ) {
      _model = StateObject(
        wrappedValue: CnctChatModel(
          client: cnct.chat(publicKey, tokenStore: tokenStore ?? CnctKeychainTokenStore()), ownsClient: true,
          identity: identity))
      self.theme = theme
      self.language = language
      self.strings = strings
      self.onClose = onClose
      self.onEvent = onEvent
    }

    /// **The scripted conversation**, with no key and no network: the greeting, a question, the
    /// assistant's answer with choices, a photo, a reply with an invoice, a line with a phone number
    /// in it, a message that failed, the team typing, and two files in the composer. For previews,
    /// screenshots and a demo. See ``CnctChatFixture``.
    public init(
      fixture language: CnctChatLanguage,
      theme: CnctChatTheme = CnctChatTheme(),
      strings: CnctChatStrings = CnctChatStrings(),
      onClose: (() -> Void)? = nil,
      onEvent: ((CnctChatUIEvent) -> Void)? = nil
    ) {
      let spoken = CnctChatLanguage.pick(app: language, server: nil)
      _model = StateObject(
        wrappedValue: CnctChatModel(
          client: CnctChatFixture.client(language: spoken), ownsClient: true, identity: nil, fixture: spoken))
      self.theme = theme
      self.language = spoken
      self.strings = strings
      self.onClose = onClose
      self.onEvent = onEvent
    }

    public var body: some View {
      let inbox = model.state.inbox
      let spoken = CnctChatLanguage.pick(app: language, server: inbox?.widget.brand.language)
      let format = CnctChatFormat(language: spoken)
      let resolved = theme.resolved(widget: inbox?.widget, business: inbox?.business ?? "", systemIsDark: systemScheme == .dark)
      CnctChatScreen(model: model, onClose: onClose)
        .environment(\.cnctTheme, resolved)
        .environment(\.cnctWords, CnctChatWords(spoken, overrides: strings))
        .environment(\.cnctFormat, format)
        .environment(\.layoutDirection, spoken.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.locale, format.locale)
        // System controls inside — menus, dialogs, the keyboard — take the chat's appearance, not
        // only the app's.
        .environment(\.colorScheme, resolved.isDark ? .dark : .light)
        .onAppear {
          model.onEvent = onEvent
          model.open()
        }
        .onChange(of: scenePhase) { phase in
          if phase == .active { model.becameActive() }
        }
    }
  }

  /// The screen inside the options: whichever of loading, unavailable, the name form and the
  /// conversation is current, under one header.
  struct CnctChatScreen: View {
    @ObservedObject var model: CnctChatModel
    let onClose: (() -> Void)?

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      VStack(spacing: 0) {
        CnctChatHeader(model: model, onClose: onClose)
        switch model.phase {
        case .loading:
          CnctChatLoading()
        case .unavailable(let title, let body, let values):
          CnctChatUnavailable(title: words(title, values), message: words(body, values))
        case .intro:
          CnctChatIntro(model: model)
        case .chat:
          CnctChatConversationView(model: model)
        }
      }
      .background(theme.background.color.ignoresSafeArea())
      .tint(theme.primary.color)
    }
  }

  struct CnctChatLoading: View {
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      VStack(spacing: 12) {
        ProgressView()
        Text(words("connecting")).font(theme.font(.subheadline)).foregroundColor(theme.textMuted.color)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    }
  }

  struct CnctChatUnavailable: View {
    let title: String
    let message: String
    @Environment(\.cnctTheme) var theme

    var body: some View {
      VStack(spacing: 12) {
        Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
          .font(.system(size: 40))
          .foregroundColor(theme.textMuted.color)
          .accessibilityHidden(true)
        Text(title)
          .font(theme.font(.headline, weight: .semibold))
          .foregroundColor(theme.text.color)
          .multilineTextAlignment(.center)
        Text(message)
          .font(theme.font(.subheadline))
          .foregroundColor(theme.textMuted.color)
          .multilineTextAlignment(.center)
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    }
  }
#endif
