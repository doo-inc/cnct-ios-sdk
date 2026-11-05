import CNCT
import Foundation
import Observation

/// The headless client, made observable.
///
/// The SDK knows nothing about SwiftUI: it hands out an `AsyncStream` of immutable snapshots and one
/// of events. This is the handful of lines that turn those into something a view observes — an app
/// with its own state container would put the same lines there instead, and nothing else changes.
@MainActor
@Observable
final class ChatModel {
  /// Everything the screen renders. Always the truth, including straight after a reconnect.
  private(set) var state = CnctChatState()
  private(set) var inbox: CnctChatInbox?
  private(set) var bootFailure: CnctError?
  var draft = ""

  private let chat: CnctChatClient
  @ObservationIgnored private var listeners: [Task<Void, Never>] = []

  init(chat: CnctChatClient) {
    self.chat = chat
  }

  func open() async {
    listen()
    do {
      let inbox = try await chat.boot()
      self.inbox = inbox
      // A visitor who has been here before comes straight back to their own thread. False simply
      // means this is their first time — not an error.
      let resumed = try await chat.resume()
      if !resumed, inbox.isActive, !inbox.requirePhone {
        try await chat.start(displayName: "Visitor")
      }
    } catch let error as CnctError {
      bootFailure = error
    } catch {
      // Cancelled: the screen went away before it opened.
    }
  }

  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draft = ""
    Task {
      // Nothing to do on a failure: the bubble is still on screen, marked failed, with a retry
      // button.
      _ = try? await chat.send(text)
    }
  }

  /// Safe to press as often as somebody likes: the retry carries the same key, so the server keeps
  /// one message.
  func retry(_ message: CnctChatMessage) {
    guard let key = message.clientKey else { return }
    Task { _ = try? await chat.retry(key) }
  }

  /// Throttled inside the SDK to one frame every three seconds, and again on the server, so calling
  /// it per keystroke is the intended use.
  func typing() {
    Task { await chat.typing() }
  }

  func download(_ attachment: CnctChatAttachment) async -> Data? {
    try? await chat.downloadAttachment(attachment.id)
  }

  private func listen() {
    guard listeners.isEmpty else { return }
    let states = chat.states
    let events = chat.events
    // Weak, and ending once the model is gone: the client outlives any one screen.
    listeners = [
      Task { [weak self] in
        for await state in states {
          guard let self else { return }
          self.state = state
        }
      },
      Task { [weak self] in
        for await event in events {
          guard let self else { return }
          await self.handle(event)
        }
      },
    ]
  }

  private func handle(_ event: CnctChatEvent) async {
    switch event {
    case .unauthenticated:
      // Their thirty days ran out, or the conversation was closed from the other side. They are a
      // stranger again; start them over rather than leaving a dead screen.
      try? await chat.start(displayName: "Visitor")
    default:
      // Everything else is already in `state`. Events are for what a UI does rather than shows — a
      // sound on `.messageReceived`, say.
      break
    }
  }
}
