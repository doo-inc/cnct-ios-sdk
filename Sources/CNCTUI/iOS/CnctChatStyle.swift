#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  extension CnctChatColor {
    /// A `UIColor`, resolved for the current appearance where it is a dynamic one.
    public init(_ color: UIColor) {
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
          red = white
          green = white
          blue = white
        }
      }
      self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
    }

    /// A SwiftUI `Color`.
    public init(_ color: Color) {
      self.init(UIColor(color))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var uiColor: UIColor { UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }
  }

  extension CnctChatLogo {
    /// A logo from an image the app already has. Nil for an image with nothing to draw.
    public static func image(from image: UIImage) -> CnctChatLogo? {
      image.pngData().map(CnctChatLogo.image)
    }
  }

  extension CnctResolvedChatTheme {
    /// The theme's typeface at a text style, scaling with Dynamic Type either way.
    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
      switch font {
      case .system:
        return Font.system(style).weight(weight)
      case .named(let name):
        return Font.custom(name, size: Self.size(of: style), relativeTo: style).weight(weight)
      }
    }

    /// The same, for UIKit — the composer is a text view.
    func uiFont(_ style: UIFont.TextStyle) -> UIFont {
      switch font {
      case .system:
        return UIFont.preferredFont(forTextStyle: style)
      case .named(let name):
        let base = UIFont(name: name, size: 17) ?? UIFont.systemFont(ofSize: 17)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
      }
    }

    /// The size each text style has at the default Dynamic Type setting, which a custom font is
    /// scaled from.
    static func size(of style: Font.TextStyle) -> CGFloat {
      switch style {
      case .largeTitle: return 34
      case .title: return 28
      case .title2: return 22
      case .title3: return 20
      case .headline: return 17
      case .body: return 17
      case .callout: return 16
      case .subheadline: return 15
      case .footnote: return 13
      case .caption: return 12
      case .caption2: return 11
      default: return 17
      }
    }

    /// For a failed message: red that reads on the background in either appearance.
    var danger: CnctChatColor { isDark ? "#f97066" : "#c4320a" }
    var success: CnctChatColor { isDark ? "#47cd89" : "#079455" }
    var warning: CnctChatColor { isDark ? "#fdb022" : "#b54708" }
  }

  private struct ThemeKey: EnvironmentKey {
    static let defaultValue = CnctResolvedChatTheme.fallback
  }

  private struct WordsKey: EnvironmentKey {
    static let defaultValue = CnctChatWords(.en)
  }

  private struct FormatKey: EnvironmentKey {
    static let defaultValue = CnctChatFormat(language: .en)
  }

  extension EnvironmentValues {
    var cnctTheme: CnctResolvedChatTheme {
      get { self[ThemeKey.self] }
      set { self[ThemeKey.self] = newValue }
    }

    var cnctWords: CnctChatWords {
      get { self[WordsKey.self] }
      set { self[WordsKey.self] = newValue }
    }

    var cnctFormat: CnctChatFormat {
      get { self[FormatKey.self] }
      set { self[FormatKey.self] = newValue }
    }
  }

  /// Somebody's words — a message, a name, a choice, a file name — drawn in their own direction.
  ///
  /// The direction comes from the first strong character, whatever the interface's: an Arabic line
  /// in an English chat is laid out right to left, and the other way round. Phone numbers, emails
  /// and web addresses inside it stay left to right, and web addresses are links.
  struct CnctUserText: View {
    let text: String
    var style: Font.TextStyle = .body
    var weight: Font.Weight = .regular
    var color: CnctChatColor
    var link: CnctChatColor?
    var lineLimit: Int?
    var alignment: TextAlignment = .leading

    @Environment(\.cnctTheme) var theme
    @Environment(\.layoutDirection) var interface

    var body: some View {
      Text(Self.attributed(text))
        .font(theme.font(style, weight: weight))
        .foregroundColor(color.color)
        .tint((link ?? color).color)
        .lineLimit(lineLimit)
        .multilineTextAlignment(alignment)
        .fixedSize(horizontal: false, vertical: lineLimit == nil)
        .environment(\.layoutDirection, Self.layout(of: text, interface: interface))
    }

    static func layout(of text: String, interface: LayoutDirection) -> LayoutDirection {
      switch CnctBidi.direction(of: text) {
      case .rightToLeft: return .rightToLeft
      case .leftToRight: return .leftToRight
      case .neutral: return interface
      }
    }

    static func attributed(_ text: String) -> AttributedString {
      var result = AttributedString()
      for (index, line) in text.components(separatedBy: "\n").enumerated() {
        if index > 0 { result.append(AttributedString("\n")) }
        for run in CnctBidi.runs(line) {
          var piece = AttributedString(
            run.keepsLeftToRight ? CnctBidi.isolateStart + run.text + CnctBidi.isolateEnd : run.text)
          if let url = run.link { piece.link = url }
          result.append(piece)
        }
      }
      return result
    }
  }

  /// A circle with a face in it: the business's logo or letter, a person's initial, the assistant's
  /// mark.
  struct CnctFace: View {
    enum Who {
      case business
      case sender(CnctChatSender?)
    }

    let who: Who
    var size: CGFloat = 28

    @Environment(\.cnctTheme) var theme

    var body: some View {
      Group {
        switch who {
        case .business:
          CnctLogo(size: size)
        case .sender(let sender):
          if let sender, sender.kind == .ai {
            Image(systemName: "sparkles")
              .font(.system(size: size * 0.5, weight: .semibold))
              .foregroundColor(theme.primary.color)
              .frame(width: size, height: size)
              .background(Circle().fill(theme.primary.opacity(0.16).color))
          } else if let sender, sender.kind == .person, let name = sender.name {
            Text(CnctChatTheme.initial(name))
              .font(.system(size: size * 0.45, weight: .semibold))
              .foregroundColor(theme.text.color)
              .frame(width: size, height: size)
              .background(Circle().fill(theme.border.color))
          } else {
            CnctLogo(size: size)
          }
        }
      }
      .accessibilityHidden(true)
    }
  }

  /// The business's mark: the logo, or its first letter on the brand colour while there is none.
  struct CnctLogo: View {
    var size: CGFloat = 40
    @Environment(\.cnctTheme) var theme

    var body: some View {
      Group {
        switch theme.logo {
        case .image(let data):
          if let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
          } else {
            letter
          }
        case .url(let url):
          AsyncImage(url: url) { phase in
            if let image = phase.image {
              image.resizable().scaledToFill()
            } else {
              letter
            }
          }
        case nil:
          letter
        }
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
      .accessibilityHidden(true)
    }

    private var letter: some View {
      Text(theme.letter)
        .font(.system(size: size * 0.44, weight: .bold))
        .foregroundColor(theme.onPrimary.color)
        .frame(width: size, height: size)
        .background(theme.primary.color)
    }
  }
#endif
