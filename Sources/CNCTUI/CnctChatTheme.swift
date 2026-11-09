import CNCT
import Foundation

/// A colour, as a theme token holds one: sRGB, with alpha.
///
/// A value of its own rather than a SwiftUI `Color`, because a theme has to *reason* about its
/// colours — which ink reads on the brand colour is arithmetic on its channels, and a `Color` will
/// not say what its channels are. Write one as a hex literal, or build one from a `UIColor` or a
/// `Color` on iOS.
public struct CnctChatColor: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = min(1, max(0, red))
    self.green = min(1, max(0, green))
    self.blue = min(1, max(0, blue))
    self.alpha = min(1, max(0, alpha))
  }

  /// `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the `#`. Nil for anything else.
  public init?(hex: String) {
    var digits = hex.trimmingCharacters(in: .whitespaces)
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.allSatisfy(\.isHexDigit) else { return nil }
    if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
    guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
    let channel = { (shift: UInt64) in Double((value >> shift) & 0xff) / 255 }
    if digits.count == 6 {
      self.init(red: channel(16), green: channel(8), blue: channel(0))
    } else {
      self.init(red: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }
  }

  /// A hex literal. A literal that is not a colour is a mistake in the code that wrote it, caught the
  /// first time that code runs in a debug build; a release build draws it black rather than
  /// crashing somebody's app.
  public init(stringLiteral value: String) {
    if let parsed = CnctChatColor(hex: value) {
      self = parsed
    } else {
      assertionFailure("\"\(value)\" is not a #rrggbb colour.")
      self.init(red: 0, green: 0, blue: 0)
    }
  }

  /// `#rrggbb`, lower case, for logs and CSS.
  public var hex: String {
    let byte = { (value: Double) in String(format: "%02x", Int((value * 255).rounded())) }
    return "#\(byte(red))\(byte(green))\(byte(blue))"
  }

  public var description: String { alpha < 1 ? "\(hex) at \(Int(alpha * 100))%" : hex }

  /// Relative luminance, the WCAG way: sRGB channels linearised, then weighted.
  public var luminance: Double {
    func linear(_ value: Double) -> Double {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  /// How far apart two colours are to a reader, from 1 (the same) to 21 (black on white). Text wants
  /// 4.5 or more.
  public func contrast(with other: CnctChatColor) -> Double {
    let lighter = max(luminance, other.luminance)
    let darker = min(luminance, other.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// **Which ink reads on this colour** — near-black or white, by the same sRGB luminance the server
  /// computes and the hosted chat page repeats. Half the palette somebody who is not a designer
  /// reaches for makes white text unreadable, and the alternative is a second colour picker asking
  /// them to solve contrast by eye.
  public var readableInk: CnctChatColor {
    luminance > 0.55 ? CnctChatColor(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255) : .white
  }

  public static let white = CnctChatColor(red: 1, green: 1, blue: 1)

  func opacity(_ alpha: Double) -> CnctChatColor {
    CnctChatColor(red: red, green: green, blue: blue, alpha: self.alpha * alpha)
  }
}

/// Light, dark, or whatever the device is set to.
public enum CnctChatAppearance: String, Sendable, Hashable, CaseIterable {
  case light, dark, system
}

/// The typeface the chat is set in.
public enum CnctChatFont: Sendable, Hashable {
  /// San Francisco, and the system's own Arabic.
  case system
  /// A font by its PostScript or family name — one the app bundles, or one iOS ships ("Georgia",
  /// "Avenir Next"). It scales with Dynamic Type like the system font does. Where it has no Arabic,
  /// the system's Arabic fills in.
  case named(String)
}

/// The header's image.
public enum CnctChatLogo: Sendable, Hashable {
  /// Fetched from a web address. While it loads, and if it fails, the business's first letter shows
  /// instead — never a broken image.
  case url(URL)
  /// PNG or JPEG bytes from the app, drawn as they are.
  case image(Data)
}

/// The colour tokens for one appearance. Every one is optional: what is left out comes from the
/// inbox's settings in the CNCT console, and then from the built-in defaults.
public struct CnctChatPalette: Sendable, Hashable {
  /// The brand colour: the send button, links, the header accent, and the visitor's own bubbles.
  public var primary: CnctChatColor?
  /// Text and icons on `primary`. Black or white by luminance when left out.
  public var onPrimary: CnctChatColor?
  /// The screen.
  public var background: CnctChatColor?
  /// The header, the composer and the cards.
  public var surface: CnctChatColor?
  /// The main text.
  public var text: CnctChatColor?
  /// Timestamps and hints.
  public var textMuted: CnctChatColor?
  /// Dividers and outlines.
  public var border: CnctChatColor?
  /// The visitor's own messages. `primary` when left out.
  public var visitorBubble: CnctChatColor?
  public var onVisitorBubble: CnctChatColor?
  /// The team's and the assistant's messages. `surface` when left out.
  public var agentBubble: CnctChatColor?
  public var onAgentBubble: CnctChatColor?

  public init(
    primary: CnctChatColor? = nil,
    onPrimary: CnctChatColor? = nil,
    background: CnctChatColor? = nil,
    surface: CnctChatColor? = nil,
    text: CnctChatColor? = nil,
    textMuted: CnctChatColor? = nil,
    border: CnctChatColor? = nil,
    visitorBubble: CnctChatColor? = nil,
    onVisitorBubble: CnctChatColor? = nil,
    agentBubble: CnctChatColor? = nil,
    onAgentBubble: CnctChatColor? = nil
  ) {
    self.primary = primary
    self.onPrimary = onPrimary
    self.background = background
    self.surface = surface
    self.text = text
    self.textMuted = textMuted
    self.border = border
    self.visitorBubble = visitorBubble
    self.onVisitorBubble = onVisitorBubble
    self.agentBubble = agentBubble
    self.onAgentBubble = onAgentBubble
  }

  /// The built-in light colours.
  public static let defaultLight = CnctChatPalette(
    background: "#ffffff", surface: "#f6f7f9", text: "#111418", textMuted: "#5b6573", border: "#e3e6ea")

  /// The built-in dark colours.
  public static let defaultDark = CnctChatPalette(
    background: "#0f1115", surface: "#171a21", text: "#eef0f3", textMuted: "#9aa3af", border: "#2a2f38")
}

/// How the chat looks: colours for light and dark, a corner radius, a typeface, a logo, a title.
///
/// **Precedence: what the app passes here, then the inbox's widget settings on the server, then the
/// built-in defaults.** So a business can brand its chat from the CNCT console with no code at all,
/// and an app can pin any part of it in code. Every token is optional for exactly that reason — a
/// token left out is a token the console decides.
///
/// ```swift
/// CnctChatView(client: chat, theme: CnctChatTheme(primary: "#D7262E", cornerRadius: 8, font: .named("Georgia")))
/// ```
///
/// The token names are the same in the web and Android SDKs.
public struct CnctChatTheme: Sendable, Hashable {
  /// The colours in light appearance.
  public var light: CnctChatPalette
  /// The colours in dark appearance.
  public var dark: CnctChatPalette
  /// Bubbles and cards. 18 when left out.
  public var cornerRadius: Double?
  /// The system font when left out.
  public var font: CnctChatFont?
  /// The header image. The inbox's logo from the console when left out, and the business's first
  /// letter on `primary` when there is none.
  public var logo: CnctChatLogo?
  /// The header title. The business's name when left out.
  public var title: String?
  /// Light, dark or the device's setting. The console's choice when left out (its `auto` is
  /// `system`).
  public var appearance: CnctChatAppearance?
  /// The "Powered by CNCT" line. The console's choice when left out.
  public var showPoweredBy: Bool?

  /// The same colour tokens in light and dark. For a token that should differ between the two, set
  /// it on ``light`` or ``dark`` afterwards.
  public init(
    primary: CnctChatColor? = nil,
    onPrimary: CnctChatColor? = nil,
    background: CnctChatColor? = nil,
    surface: CnctChatColor? = nil,
    text: CnctChatColor? = nil,
    textMuted: CnctChatColor? = nil,
    border: CnctChatColor? = nil,
    visitorBubble: CnctChatColor? = nil,
    onVisitorBubble: CnctChatColor? = nil,
    agentBubble: CnctChatColor? = nil,
    onAgentBubble: CnctChatColor? = nil,
    cornerRadius: Double? = nil,
    font: CnctChatFont? = nil,
    logo: CnctChatLogo? = nil,
    title: String? = nil,
    appearance: CnctChatAppearance? = nil,
    showPoweredBy: Bool? = nil
  ) {
    let both = CnctChatPalette(
      primary: primary, onPrimary: onPrimary, background: background, surface: surface, text: text,
      textMuted: textMuted, border: border, visitorBubble: visitorBubble, onVisitorBubble: onVisitorBubble,
      agentBubble: agentBubble, onAgentBubble: onAgentBubble)
    self.init(
      light: both, dark: both, cornerRadius: cornerRadius, font: font, logo: logo, title: title,
      appearance: appearance, showPoweredBy: showPoweredBy)
  }

  /// Different colours for light and dark.
  public init(
    light: CnctChatPalette,
    dark: CnctChatPalette,
    cornerRadius: Double? = nil,
    font: CnctChatFont? = nil,
    logo: CnctChatLogo? = nil,
    title: String? = nil,
    appearance: CnctChatAppearance? = nil,
    showPoweredBy: Bool? = nil
  ) {
    self.light = light
    self.dark = dark
    self.cornerRadius = cornerRadius
    self.font = font
    self.logo = logo
    self.title = title
    self.appearance = appearance
    self.showPoweredBy = showPoweredBy
  }

  /// The built-in default corner radius.
  public static let defaultCornerRadius = 18.0

  /// Every token decided: the app's, then the server's, then the defaults.
  ///
  /// - Parameters:
  ///   - widget: The inbox's settings, from `boot()`. Nil before it has answered, which reads as the
  ///     defaults.
  ///   - business: The business's name, for the title and the letter that stands in for a logo.
  ///   - systemIsDark: Whether the device is in dark mode — what `system` follows.
  public func resolved(widget: CnctChatWidget?, business: String, systemIsDark: Bool) -> CnctResolvedChatTheme {
    let brand = (widget ?? .defaults).brand
    let appearance =
      self.appearance
      ?? {
        switch brand.appearance {
        case .light: return .light
        case .dark: return .dark
        case .auto: return .system
        }
      }()
    let isDark = appearance == .dark || (appearance == .system && systemIsDark)
    let app = isDark ? dark : light
    let base = isDark ? CnctChatPalette.defaultDark : CnctChatPalette.defaultLight

    let primary = app.primary ?? CnctChatColor(hex: brand.color) ?? "#b52d93"
    let onPrimary = app.onPrimary ?? primary.readableInk
    let surface = app.surface ?? base.surface!
    let text = app.text ?? base.text!
    let visitorBubble = app.visitorBubble ?? primary
    let agentBubble = app.agentBubble ?? surface
    let name = (title ?? business).trimmingCharacters(in: .whitespacesAndNewlines)

    return CnctResolvedChatTheme(
      isDark: isDark,
      primary: primary,
      onPrimary: onPrimary,
      background: app.background ?? base.background!,
      surface: surface,
      text: text,
      textMuted: app.textMuted ?? base.textMuted!,
      border: app.border ?? base.border!,
      visitorBubble: visitorBubble,
      // A bubble the app recoloured gets ink chosen for its colour, not for the brand colour it no
      // longer is.
      onVisitorBubble: app.onVisitorBubble ?? (app.visitorBubble == nil ? onPrimary : visitorBubble.readableInk),
      agentBubble: agentBubble,
      onAgentBubble: app.onAgentBubble ?? (app.agentBubble == nil ? text : agentBubble.readableInk),
      cornerRadius: max(0, cornerRadius ?? Self.defaultCornerRadius),
      font: font ?? .system,
      logo: logo ?? brand.avatarURL.map(CnctChatLogo.url),
      title: name.isEmpty ? business : name,
      letter: Self.initial(business.isEmpty ? name : business),
      showPoweredBy: showPoweredBy ?? brand.showBranding
    )
  }

  /// The business's first letter, upper-cased — what stands in for a logo. Never an empty disc.
  static func initial(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
  }
}

/// A theme with every token decided — what the screen draws with.
public struct CnctResolvedChatTheme: Sendable, Hashable {
  public let isDark: Bool
  public let primary: CnctChatColor
  public let onPrimary: CnctChatColor
  public let background: CnctChatColor
  public let surface: CnctChatColor
  public let text: CnctChatColor
  public let textMuted: CnctChatColor
  public let border: CnctChatColor
  public let visitorBubble: CnctChatColor
  public let onVisitorBubble: CnctChatColor
  public let agentBubble: CnctChatColor
  public let onAgentBubble: CnctChatColor
  public let cornerRadius: Double
  public let font: CnctChatFont
  public let logo: CnctChatLogo?
  public let title: String
  /// What stands in for the logo: the business's first letter.
  public let letter: String
  public let showPoweredBy: Bool

  /// What draws before the inbox has answered, and in a preview.
  public static let fallback = CnctChatTheme().resolved(widget: nil, business: "", systemIsDark: false)
}
