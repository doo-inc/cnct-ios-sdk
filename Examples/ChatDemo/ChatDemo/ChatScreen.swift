import CNCT
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// A complete chat screen, and a deliberately ordinary one.
///
/// Nothing here is provided by the SDK: the bubbles, the composer, the retry button and the cards
/// are all this app's. That is the arrangement — the SDK ships state and events, the interface is
/// yours. What it does give you is the guarantee that rendering `CnctChatState` is always rendering
/// the truth, including straight after a reconnect.
struct ChatScreen: View {
  @State private var model: ChatModel

  init(chat: CnctChatClient) {
    _model = State(initialValue: ChatModel(chat: chat))
  }

  var body: some View {
    NavigationStack {
      content
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
              Text(model.inbox?.business ?? "Chat").font(.headline)
              StatusLine(state: model.state)
            }
          }
        }
    }
    .task { await model.open() }
  }

  @ViewBuilder private var content: some View {
    if let failure = model.bootFailure {
      ContentUnavailableView("Chat is unavailable", systemImage: "wifi.exclamationmark", description: Text(failure.message))
    } else if let inbox = model.inbox {
      conversation(inbox)
    } else {
      ProgressView()
    }
  }

  private func conversation(_ inbox: CnctChatInbox) -> some View {
    VStack(spacing: 0) {
      if !inbox.isActive {
        Text("This inbox is closed right now.")
          .frame(maxWidth: .infinity)
          .padding(12)
          .background(Color.orange.opacity(0.2))
      }
      ScrollViewReader { scroller in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            if model.state.messages.isEmpty, !inbox.greeting.isEmpty {
              Text(inbox.greeting).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(model.state.messages) { message in
              Bubble(message: message, retry: { model.retry(message) }, download: { await model.download($0) })
                .id(message.id)
            }
          }
          .padding(12)
        }
        .onChange(of: model.state.messages.last?.id) { _, last in
          guard let last else { return }
          withAnimation { scroller.scrollTo(last, anchor: .bottom) }
        }
      }
      if model.state.theyAreTyping {
        Text("typing…")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
      }
      Composer(draft: $model.draft, enabled: model.state.canSend, typing: { model.typing() }, send: { model.send() })
    }
  }
}

private struct StatusLine: View {
  let state: CnctChatState

  var body: some View {
    Text(label).font(.caption).foregroundStyle(.secondary)
  }

  private var label: String {
    switch state.status {
    // `withPerson` says somebody is on the thread. Never who — the platform does not publish a
    // colleague's name to a customer, so neither does this.
    case .live where state.conversation?.withPerson == true: return "Someone is with you"
    case .live: return "Connected"
    case .connecting: return "Connecting…"
    // Offline is not an error: the transcript is still true and sends still go over HTTP.
    case .offline: return "Reconnecting…"
    case .ended: return "This conversation has ended"
    case .idle: return ""
    }
  }
}

private struct Bubble: View {
  let message: CnctChatMessage
  let retry: () -> Void
  let download: (CnctChatAttachment) async -> Data?

  private var mine: Bool { message.speaker == .caller }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      content.opacity(message.pending ? 0.6 : 1)
      ForEach(message.attachments) { attachment in
        AttachmentRow(attachment: attachment, download: download)
      }
      // The words somebody typed never disappear on a failure — they get a way back.
      if message.failed, message.clientKey != nil {
        Button("Retry", systemImage: "arrow.clockwise", action: retry).font(.footnote)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(mine ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 16))
    .overlay {
      if message.failed { RoundedRectangle(cornerRadius: 16).stroke(.red) }
    }
    .frame(maxWidth: 320, alignment: mine ? .trailing : .leading)
    .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
  }

  /// Switching on `type` is the whole of card handling, and the `default` is the compatibility
  /// story: a card type added to the platform next year arrives here with a `body` that reads
  /// correctly as a sentence, so this app shows something true rather than an empty bubble.
  @ViewBuilder private var content: some View {
    switch message.type {
    case .ticketUpdate where message.ticket != nil:
      let ticket = message.ticket!
      Card(icon: "doc.text", title: "Ticket #\(ticket.ticketNumber)", lines: [ticket.title, ticket.status])
    case .bookingUpdate where message.booking != nil:
      let booking = message.booking!
      Card(
        icon: "calendar",
        title: booking.title,
        // The customer's own clock and locale, not the business's: the SDK hands over the instant.
        lines: [booking.startsAt.formatted(date: .abbreviated, time: .shortened), booking.locationName, booking.status]
          .compactMap { $0 }
      )
    default:
      Text(message.body)
    }
  }
}

private struct Card: View {
  let icon: String
  let title: String
  let lines: [String]

  var body: some View {
    Label {
      VStack(alignment: .leading) {
        Text(title).font(.subheadline.bold())
        ForEach(lines, id: \.self) { Text($0) }
      }
    } icon: {
      Image(systemName: icon)
    }
  }
}

/// An image is fetched and shown; anything else is its name. The download goes through the client,
/// because the file is only served to the visitor's own session token — a plain `AsyncImage` would
/// be refused.
private struct AttachmentRow: View {
  let attachment: CnctChatAttachment
  let download: (CnctChatAttachment) async -> Data?
  @State private var image: Image?

  var body: some View {
    if attachment.kind == .image {
      Group {
        if let image {
          image.resizable().scaledToFit().frame(maxHeight: 200).clipShape(.rect(cornerRadius: 8))
        } else {
          ProgressView()
        }
      }
      .task { await load() }
    } else {
      Label(attachment.filename ?? attachment.mimeType, systemImage: "paperclip").font(.footnote)
    }
  }

  private func load() async {
    #if canImport(UIKit)
      if image == nil, let data = await download(attachment), let picture = UIImage(data: data) {
        image = Image(uiImage: picture)
      }
    #endif
  }
}

private struct Composer: View {
  @Binding var draft: String
  let enabled: Bool
  let typing: () -> Void
  let send: () -> Void

  var body: some View {
    HStack {
      TextField("Type a message", text: $draft, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...4)
        .disabled(!enabled)
        .onSubmit(send)
        .onChange(of: draft) { _, text in
          if !text.isEmpty { typing() }
        }
      Button("Send", systemImage: "paperplane.fill", action: send)
        .labelStyle(.iconOnly)
        .disabled(!enabled || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(8)
    .background(.bar)
  }
}
