#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  /// The chat screen for a UIKit app: ``CnctChatView`` in a view controller, with the same options.
  ///
  /// ```swift
  /// let chat = CnctChatViewController(publicKey: try CnctChatPublicKey("your-inbox-public-key")) { [weak self] in
  ///   self?.dismiss(animated: true)
  /// }
  /// present(chat, animated: true)
  /// ```
  public final class CnctChatViewController: UIViewController {
    private let host: UIHostingController<CnctChatView>

    /// The chat on a client the app made, and keeps.
    public init(
      client: CnctChatClient,
      theme: CnctChatTheme = CnctChatTheme(),
      language: CnctChatLanguage? = nil,
      strings: CnctChatStrings = CnctChatStrings(),
      identity: CnctChatIdentity? = nil,
      onEvent: ((CnctChatUIEvent) -> Void)? = nil,
      onClose: (() -> Void)? = nil
    ) {
      host = UIHostingController(
        rootView: CnctChatView(
          client: client, theme: theme, language: language, strings: strings, identity: identity, onClose: onClose,
          onEvent: onEvent))
      super.init(nibName: nil, bundle: nil)
    }

    /// The chat on an inbox's public key; the visitor's session is kept in the Keychain.
    public init(
      publicKey: CnctChatPublicKey,
      cnct: Cnct = Cnct(),
      tokenStore: (any CnctTokenStore)? = nil,
      theme: CnctChatTheme = CnctChatTheme(),
      language: CnctChatLanguage? = nil,
      strings: CnctChatStrings = CnctChatStrings(),
      identity: CnctChatIdentity? = nil,
      onEvent: ((CnctChatUIEvent) -> Void)? = nil,
      onClose: (() -> Void)? = nil
    ) {
      host = UIHostingController(
        rootView: CnctChatView(
          publicKey: publicKey, cnct: cnct, tokenStore: tokenStore, theme: theme, language: language, strings: strings,
          identity: identity, onClose: onClose, onEvent: onEvent))
      super.init(nibName: nil, bundle: nil)
    }

    /// The scripted conversation, with no key and no network. See ``CnctChatFixture``.
    public init(fixture language: CnctChatLanguage, theme: CnctChatTheme = CnctChatTheme(), onClose: (() -> Void)? = nil) {
      host = UIHostingController(rootView: CnctChatView(fixture: language, theme: theme, onClose: onClose))
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "Use init(client:) or init(publicKey:).")
    public required init?(coder: NSCoder) {
      fatalError("CnctChatViewController is made in code, not in a storyboard.")
    }

    public override func viewDidLoad() {
      super.viewDidLoad()
      addChild(host)
      host.view.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(host.view)
      NSLayoutConstraint.activate([
        host.view.topAnchor.constraint(equalTo: view.topAnchor),
        host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      ])
      host.didMove(toParent: self)
    }
  }
#endif
