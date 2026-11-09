import Foundation

/// Where the chat client is.
public enum CnctChatStatus: String, Sendable, Hashable, CaseIterable {
  /// No session. `boot()` may have run; nobody has started a conversation.
  case idle

  /// A session exists and the socket is being opened.
  case connecting

  /// Connected. Messages arrive as they are written.
  case live

  /// The socket dropped and is being retried. **Not an error state** — the transcript is still
  /// true, sends still work over HTTP, and the client is already backing off towards a reconnect.
  case offline

  /// The conversation is closed. It cannot be reopened; `start()` a new one.
  case ended
}

/// Everything a UI renders, in one immutable snapshot.
///
/// A value, replaced rather than mutated on every change, so a SwiftUI view, an `@Observable` model
/// or anything else comparing snapshots sees the change, and anything reading fields sees a
/// consistent picture rather than a half-applied one. It is `Equatable`, so a view model can skip a
/// render when nothing moved.
public struct CnctChatState: Sendable, Hashable {
  public internal(set) var status: CnctChatStatus

  /// What `boot()` returned. Nil until it has run.
  public internal(set) var inbox: CnctChatInbox?

  public internal(set) var conversation: CnctChatConversation?
  public internal(set) var visitor: CnctChatVisitor?

  /// Oldest first.
  public internal(set) var messages: [CnctChatMessage]

  /// True while the other side is typing. Clears itself after four seconds — the platform sends a
  /// start, never a stop, because a stop that goes missing leaves an indicator on the screen for
  /// ever.
  public internal(set) var theyAreTyping: Bool

  /// The last failure, or nil. Cleared by the next success.
  public internal(set) var error: CnctError?

  /// Every field has a default, so a preview or a test can build exactly the snapshot it needs.
  public init(
    status: CnctChatStatus = .idle,
    inbox: CnctChatInbox? = nil,
    conversation: CnctChatConversation? = nil,
    visitor: CnctChatVisitor? = nil,
    messages: [CnctChatMessage] = [],
    theyAreTyping: Bool = false,
    error: CnctError? = nil
  ) {
    self.status = status
    self.inbox = inbox
    self.conversation = conversation
    self.visitor = visitor
    self.messages = messages
    self.theyAreTyping = theyAreTyping
    self.error = error
  }

  /// True when there is a conversation to type into.
  public var canSend: Bool {
    status != .idle && status != .ended && conversation?.status != .closed
  }

  /// Messages that failed to send and are waiting for a retry.
  public var failed: [CnctChatMessage] { messages.filter(\.failed) }

  /// True while the conversation can still be written in — none yet counts, because the first
  /// message is what starts one.
  public var isLive: Bool { status != .ended && conversation?.status != .closed }

  /// **The flow message waiting for an answer, if one is**: the last thing said, from the
  /// assistant, drawn as a flow, with choices to tap or an ``CnctChatFlow/expects`` that picks the
  /// keyboard. Nil the moment anybody says anything else, and on a conversation that has ended —
  /// once a question is answered its choices go, as quick replies do everywhere.
  public var awaitingFlow: CnctChatMessage? {
    guard isLive, let last = messages.last, last.speaker == .ai, !last.pending,
      let flow = last.flow, flow.drawsAsFlow, !flow.choices.isEmpty || flow.expects != nil
    else { return nil }
    return last
  }

  /// Replies the assistant offered with its last answer, to show as chips. Read back over the
  /// assistant's trailing messages, because pictures it sends after its words arrive as messages of
  /// their own and carry none. Empty once anybody else speaks, beside a flow's choices (one row of
  /// answers to tap at a time), and on a conversation that has ended.
  public var offeredSuggestions: [String] {
    guard isLive, awaitingFlow?.flow?.choices.isEmpty ?? true else { return [] }
    for message in messages.reversed() {
      guard message.speaker == .ai else { break }
      if !message.suggestions.isEmpty { return message.suggestions }
    }
    return []
  }

  /// The visitor's last message, when it is the last thing said and the team has read it — where a
  /// UI writes "Seen". Nil after a reply: the reply says it better.
  public var seenMessageId: String? {
    guard let last = messages.last, last.speaker == .caller, !last.pending, !last.failed, !last.id.isEmpty,
      let seenAt = conversation?.seenAt, seenAt >= last.createdAt
    else { return nil }
    return last.id
  }
}

/// One conversation and everything said in it — what ``CnctChatClient/conversation(_:)`` answers.
public struct CnctChatTranscript: Sendable, Hashable {
  public let conversation: CnctChatConversation
  /// Oldest first.
  public let messages: [CnctChatMessage]

  public init(conversation: CnctChatConversation, messages: [CnctChatMessage]) {
    self.conversation = conversation
    self.messages = messages
  }
}

extension CnctChatState: CustomStringConvertible {
  public var description: String {
    "CnctChatState(\(status.rawValue), \(messages.count) messages\(theyAreTyping ? ", typing" : ""))"
  }
}

/// Something that happened, as opposed to something that is true.
///
/// ``CnctChatState`` is enough to render the whole interface; these are for the things a UI *does*
/// rather than shows — playing a sound on a new message, scrolling to the bottom, sending the
/// visitor back to a pre-chat screen when their session is refused.
public enum CnctChatEvent: Sendable, Hashable {
  /// The socket is up and the transcript has been refetched.
  case connected

  /// The socket dropped. A reconnect is already scheduled; nothing is required of you.
  case disconnected

  /// The session token was refused and has been cleared. The visitor is a stranger again — show
  /// whatever you show before a conversation starts.
  case unauthenticated

  /// A message arrived. Already in ``CnctChatState/messages`` by the time this is emitted.
  case messageReceived(CnctChatMessage)

  /// A message already in ``CnctChatState/messages`` changed — edited, deleted, or a file it carries
  /// finished storing — and was replaced where it stands.
  case messageUpdated(CnctChatMessage)

  /// The team read the visitor's messages up to this instant. Also in
  /// ``CnctChatConversation/seenAt``.
  case read(Date)

  /// The other side is typing.
  case typingReceived

  /// The conversation changed — assigned to somebody, snoozed, reopened.
  case conversationUpdated(CnctChatConversation)

  /// The conversation was closed, by the visitor or by the business.
  case closed

  /// Something failed. Also in ``CnctChatState/error``.
  case errored(CnctError)
}
