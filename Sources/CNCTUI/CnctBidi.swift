import Foundation

/// Which way a piece of text reads.
public enum CnctTextDirection: Sendable, Hashable {
  case leftToRight
  case rightToLeft
  /// No letters at all — digits, punctuation, an emoji. It takes the interface's direction.
  case neutral
}

/// **Each piece of text takes its own direction, whatever the interface's.**
///
/// An Arabic message in an English chat reads right to left, and an English one in an Arabic chat
/// reads left to right: the direction is the first strong character's — what a browser does for
/// `dir="auto"`. And inside any of them, a phone number, an email address or a web address stays
/// left to right, as it is read aloud; without that, "+973 3311 2233" in an Arabic sentence comes out
/// as "2233 3311 +973".
public enum CnctBidi {
  /// The direction of the first strong character, skipping digits, spaces, punctuation and symbols.
  public static func direction(of text: String) -> CnctTextDirection {
    for scalar in text.unicodeScalars {
      if isRightToLeft(scalar) { return .rightToLeft }
      if isStrongLeftToRight(scalar) { return .leftToRight }
    }
    return .neutral
  }

  /// Hebrew, Arabic, Syriac, Thaana, N'Ko and the rest of the right-to-left blocks, with their
  /// presentation forms — Unicode's bidi classes R and AL, by range.
  static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF,
      0x10800...0x10FFF, 0x1E800...0x1EFFF:
      // Arabic-Indic digits are weak, not strong: a number does not decide a line's direction.
      return !(0x0660...0x0669).contains(scalar.value) && !(0x06F0...0x06F9).contains(scalar.value)
    case 0x200F, 0x202B, 0x202E, 0x2067:  // RLM, RLE, RLO, RLI
      return true
    default:
      return false
    }
  }

  static func isStrongLeftToRight(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.value == 0x200E || scalar.value == 0x202A || scalar.value == 0x202D || scalar.value == 0x2066 {
      return true  // LRM, LRE, LRO, LRI
    }
    // A letter outside the right-to-left blocks: Latin, Greek, Cyrillic, CJK, Devanagari and the
    // rest.
    return scalar.properties.isAlphabetic && !isRightToLeft(scalar) && !scalar.properties.isEmojiPresentation
  }

  /// Left-to-right isolate and pop, around a run that must read left to right in any sentence.
  static let isolateStart = "\u{2066}"
  static let isolateEnd = "\u{2069}"

  /// A piece of a line: plain words, or something to keep left to right, with the address to open
  /// when it is a link.
  public struct Run: Sendable, Hashable {
    public let text: String
    /// Set for a web address: what tapping it opens — the address shown, character for character,
    /// with `https://` in front of a bare `www.`.
    public let link: URL?
    /// True for a phone number, an email address or a web address.
    public let keepsLeftToRight: Bool
  }

  /// A line split into runs, in order. Only `http` and `https` addresses become links, so a
  /// stranger's message cannot dress one place up as another.
  public static func runs(_ line: String) -> [Run] {
    let whole = NSRange(line.startIndex..<line.endIndex, in: line)
    var found: [(NSRange, URL?)] = []
    for match in webAddress.matches(in: line, range: whole) {
      guard let range = Range(match.range, in: line) else { continue }
      let text = String(line[range])
      let lower = text.lowercased()
      let url = URL(string: lower.hasPrefix("http://") || lower.hasPrefix("https://") ? text : "https://\(text)")
      found.append((match.range, url))
    }
    for pattern in [email, phone] {
      for match in pattern.matches(in: line, range: whole)
      where !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
        found.append((match.range, nil))
      }
    }
    found.sort { $0.0.location < $1.0.location }

    var runs: [Run] = []
    var cursor = line.startIndex
    for (nsRange, url) in found {
      guard let range = Range(nsRange, in: line) else { continue }
      if cursor < range.lowerBound {
        runs.append(Run(text: String(line[cursor..<range.lowerBound]), link: nil, keepsLeftToRight: false))
      }
      runs.append(Run(text: String(line[range]), link: url, keepsLeftToRight: true))
      cursor = range.upperBound
    }
    if cursor < line.endIndex {
      runs.append(Run(text: String(line[cursor...]), link: nil, keepsLeftToRight: false))
    }
    return runs
  }

  /// The text as it should be drawn: every phone number, email and web address wrapped in a
  /// left-to-right isolate, so it reads the same inside an Arabic sentence as it does on its own.
  public static func isolated(_ text: String) -> String {
    text.components(separatedBy: "\n").map { line in
      runs(line).map { $0.keepsLeftToRight ? isolateStart + $0.text + isolateEnd : $0.text }.joined()
    }.joined(separator: "\n")
  }

  // The hosted page's pattern, kept the same so a link is a link in both places: starts at http://,
  // https:// or www. in any case; ends before whitespace and before the punctuation a sentence puts
  // after an address — a full stop, the Arabic comma, a closing bracket the address did not open.
  static let webAddress = Pattern(
    #"(?:[Hh][Tt][Tt][Pp][Ss]?://|\b[Ww][Ww][Ww]\.)(?:[^\s()<>"]|\([^\s()<>"]*\))*(?:[^\s()<>".,:;!?'’”»\]}*_~،؛؟…]|\([^\s()<>"]*\))"#
  )
  static let email = Pattern(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}"#)
  // A plus or a digit, then digits with the spaces, dashes, dots and brackets people write numbers
  // with, then a digit — seven characters at least, so a time or a price is not a phone number.
  static let phone = Pattern(#"(?:\+|\b)\d[\d \x{00A0}\-.()]{5,}\d\b"#)

  /// A compiled pattern. `NSRegularExpression` is immutable once made and safe to share; this says
  /// so to the compiler on every platform.
  struct Pattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
      // A pattern written in this file that does not compile is a bug caught by the first test.
      regex = try! NSRegularExpression(pattern: pattern)  // swiftlint:disable:this force_try
    }

    func matches(in text: String, range: NSRange) -> [NSTextCheckingResult] {
      regex.matches(in: text, range: range)
    }
  }
}
