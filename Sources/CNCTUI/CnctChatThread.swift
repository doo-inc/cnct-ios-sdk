import CNCT
import Foundation

/// The conversation as rows on a screen: days, runs of one sender, the system's lines, choices,
/// chips, the typing dots and the cards under it all.
///
/// Worked out here, away from any view, so the grouping rules — the part of a chat screen that is
/// easiest to get subtly wrong — are tested on every platform.
public enum CnctChatRow: Sendable, Hashable, Identifiable {
  /// A day's heading: "Today", "Yesterday", "8 September".
  case day(id: String, label: String)
  /// A line from the platform itself, centred: the greeting, an out-of-hours notice.
  case system(CnctChatMessage)
  /// One sender's run of messages, signed once underneath.
  case group(CnctChatGroup)
  /// A flow's choices, under the message that offered them. Tappable only while that message is
  /// the last thing said.
  case choices(message: CnctChatMessage, flow: CnctChatFlow, active: Bool)
  /// The assistant's suggested replies, as chips.
  case suggestions([String])
  /// The team is typing.
  case typing
  /// "Who are we talking to?" — for a visitor who typed before giving a name.
  case details
  /// "Thanks, Layla — the team will see your name."
  case thanks(name: String)
  /// "This conversation has ended".
  case ended
  /// "How did we do?"
  case rating(CnctChatConversation)

  public var id: String {
    switch self {
    case .day(let id, _): return "day:\(id)"
    case .system(let message): return "system:\(message.id)"
    case .group(let group): return "group:\(group.id)"
    case .choices(let message, _, _): return "choices:\(message.id)"
    case .suggestions: return "suggestions"
    case .typing: return "typing"
    case .details: return "details"
    case .thanks: return "thanks"
    case .ended: return "ended"
    case .rating(let conversation): return "rating:\(conversation.id)"
    }
  }
}

/// Consecutive messages from one sender.
public struct CnctChatGroup: Sendable, Hashable, Identifiable {
  /// The first message's key — its `clientKey` where it has one, so the visitor's own run keeps its
  /// identity when the stored row replaces the optimistic one.
  public let id: String
  public let mine: Bool
  public let speaker: CnctSpeaker
  public let sender: CnctChatSender?
  public let messages: [CnctChatMessage]
  /// True when "Seen" goes under this run: the team has read the visitor's last words, and they
  /// are the last thing said.
  public let seen: Bool
}

extension CnctChatRow {
  /// The rows for a snapshot.
  ///
  /// - Parameters:
  ///   - day: How to head a day — `CnctChatFormat.dayLabel`.
  ///   - justNamed: The name the visitor just gave in the thread, to thank them for.
  ///   - askForRating: The inbox's `chat.askForRating`.
  public static func rows(
    for state: CnctChatState,
    day: (Date) -> String,
    justNamed: String? = nil,
    askForRating: Bool = true
  ) -> [CnctChatRow] {
    var rows: [CnctChatRow] = []
    var messages = state.messages
    // A conversation with nothing in it yet still opens with the business saying hello — the line
    // the server writes first the moment the session starts.
    if messages.isEmpty, state.conversation == nil, let greeting = state.inbox?.greeting, !greeting.isEmpty {
      messages = [
        CnctChatMessage(id: "greeting", speaker: .system, type: .text, rawType: "TEXT", body: greeting, createdAt: Date())
      ]
    }
    let awaiting = state.awaitingFlow?.id
    let seenId = state.seenMessageId

    var lastDay: String?
    var run: [CnctChatMessage] = []
    var runKey: String?

    func flush() {
      guard let first = run.first, let last = run.last else { return }
      rows.append(
        .group(
          CnctChatGroup(
            id: first.clientKey ?? first.id,
            mine: first.speaker == .caller,
            speaker: first.speaker,
            sender: first.sender,
            messages: run,
            seen: last.id == seenId && seenId != nil
          )))
      run = []
      runKey = nil
    }

    for message in messages {
      let label = day(message.createdAt)
      if label != lastDay {
        flush()
        rows.append(.day(id: "\(label)-\(message.id)", label: label))
        lastDay = label
      }
      if message.speaker == .system || message.speaker == .unknown {
        flush()
        rows.append(.system(message))
        continue
      }
      let key = signer(message)
      if key != runKey { flush() }
      run.append(message)
      runKey = key
      if let flow = message.flow, flow.drawsAsFlow, !flow.choices.isEmpty {
        flush()
        rows.append(.choices(message: message, flow: flow, active: message.id == awaiting))
      }
    }
    flush()

    let live = state.isLive
    let suggestions = state.offeredSuggestions
    if !suggestions.isEmpty { rows.append(.suggestions(suggestions)) }
    if state.theyAreTyping && live { rows.append(.typing) }

    if let justNamed {
      rows.append(.thanks(name: justNamed))
    } else if state.conversation != nil, state.visitor?.anonymous == true,
      state.messages.contains(where: { $0.speaker == .caller && !$0.pending })
    {
      rows.append(.details)
    }

    if let conversation = state.conversation, !live {
      rows.append(.ended)
      if askForRating && (conversation.ratable || conversation.rating != nil) {
        rows.append(.rating(conversation))
      }
    }
    return rows
  }

  /// Who a message is from, as one comparable string — what decides where a run starts. A person
  /// and the assistant are different voices; two people are different voices.
  static func signer(_ message: CnctChatMessage) -> String {
    if message.speaker == .caller { return "you" }
    guard let sender = message.sender else { return message.speaker == .ai ? "ai:" : "business" }
    return "\(sender.kind.rawValue):\(sender.name ?? ""):\(sender.avatar ?? sender.mascot ?? "")"
  }
}
