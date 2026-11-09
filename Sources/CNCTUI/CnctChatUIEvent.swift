import Foundation

/// Something the visitor did in the chat screen, for an app's analytics.
///
/// Never carries what anybody wrote: an analytics pipeline is the last place a customer's words
/// should end up.
public enum CnctChatUIEvent: Sendable, Hashable {
  /// The screen opened.
  case opened
  /// A conversation started.
  case started
  /// The visitor sent a message.
  case sent
  /// The visitor sent files — `count` of them, with a message.
  case attachmentSent(count: Int)
  /// The conversation ended, from either side.
  case ended
  /// The visitor rated the conversation, one to five.
  case rated(score: Int)
}
