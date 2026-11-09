#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  /// One sender's run: the bubbles, then a byline under them — the face, the first name, an "AI"
  /// tag where it applies, and the time. Signed underneath like a letter: the bubbles get the full
  /// width, and the name is read after what was said rather than before it.
  struct CnctGroupView: View {
    @ObservedObject var model: CnctChatModel
    let group: CnctChatGroup

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.cnctFormat) var format

    var body: some View {
      VStack(alignment: group.mine ? .trailing : .leading, spacing: 4) {
        ForEach(group.messages) { message in
          HStack(spacing: 0) {
            if group.mine { Spacer(minLength: 48) }
            CnctBubble(model: model, message: message, mine: group.mine, signer: signer)
            if !group.mine { Spacer(minLength: 48) }
          }
          if message.failed {
            Button {
              model.retry(message)
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
                Text(words("notSent"))
              }
              .font(theme.font(.footnote, weight: .medium))
              .foregroundColor(theme.danger.color)
              .frame(minHeight: 32)
            }
            .accessibilityLabel(words("notSent"))
          }
        }
        if let last = group.messages.last, !last.failed {
          byline(last)
        }
      }
      .frame(maxWidth: .infinity, alignment: group.mine ? .trailing : .leading)
      .padding(.top, 4)
    }

    /// The name a run is signed with. A person with no name is signed by the business.
    private var signer: String {
      if group.mine { return words("you") }
      return group.sender?.name ?? theme.title
    }

    @ViewBuilder
    private func byline(_ last: CnctChatMessage) -> some View {
      HStack(spacing: 5) {
        if !group.mine {
          CnctFace(who: .sender(group.sender), size: 20)
          Text(signer).font(theme.font(.caption, weight: .semibold)).foregroundColor(theme.text.color)
          if group.speaker == .ai {
            Text(verbatim: "AI")
              .font(.system(size: 10, weight: .bold))
              .foregroundColor(theme.primaryText.color)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Capsule().fill(theme.primary.opacity(0.14).color))
              .accessibilityLabel(words("aiAssistant"))
          }
          Text(verbatim: "·").accessibilityHidden(true)
        }
        Text(last.pending ? words("sending") : format.clock(last.createdAt))
        if group.seen {
          Text(verbatim: "·").accessibilityHidden(true)
          Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
          Text(words("seen"))
        }
      }
      .font(theme.font(.caption))
      .foregroundColor(theme.textMuted.color)
      .padding(.horizontal, 4)
      .accessibilityElement(children: .combine)
    }
  }

  /// One message: a quote, a flow's picture, the words, a footer, the files.
  struct CnctBubble: View {
    @ObservedObject var model: CnctChatModel
    let message: CnctChatMessage
    let mine: Bool
    let signer: String

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.cnctFormat) var format
    @Environment(\.layoutDirection) var interface

    var body: some View {
      let ink = mine ? theme.onVisitorBubble : theme.onAgentBubble
      let paper = mine ? theme.visitorBubble : theme.agentBubble
      let text = message.words.trimmingCharacters(in: .whitespacesAndNewlines)
      let onlyFiles = text.isEmpty && !message.attachments.isEmpty
      // A photo on its own is its own frame; a coloured bubble round it only crowds it.
      let onlyPictures = onlyFiles && message.replyTo == nil
        && message.attachments.allSatisfy { $0.kind == .image || $0.mimeType.hasPrefix("image/") }
      VStack(alignment: textAlignment(text), spacing: 8) {
        if let quote = message.replyTo {
          CnctQuoteView(quote: quote, ink: ink)
        }
        if let media = message.flow?.media, message.flow?.drawsAsFlow == true {
          CnctFlowMedia(media: media, ink: ink)
        }
        if !onlyFiles {
          CnctUserText(text: message.words, color: ink, link: mine ? ink : theme.primaryText)
            .accessibilityLabel(spoken)
        }
        if let footer = message.flow?.footer, message.flow?.drawsAsFlow == true {
          CnctUserText(text: footer, style: .footnote, color: ink.opacity(0.75))
        }
        ForEach(message.attachments) { attachment in
          CnctAttachmentView(model: model, attachment: attachment, ink: ink, signer: signer)
        }
      }
      .padding(.horizontal, onlyPictures ? 0 : onlyFiles ? 4 : 14)
      .padding(.vertical, onlyPictures ? 0 : onlyFiles ? 4 : 10)
      .background(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .fill(onlyPictures ? Color.clear : paper.color)
      )
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(
            message.failed ? theme.danger.color : (mine || onlyPictures ? Color.clear : theme.border.color), lineWidth: 1)
      )
      .opacity(message.pending ? 0.6 : 1)
    }

    /// "You: Do you open on Fridays?", "Sara: Thanks, here is your invoice." — who said it, then
    /// what, in the chat's language.
    private var spoken: String { signer + ": " + message.words }

    /// Words that read the other way from the interface sit on the other side of a bubble that is
    /// wider than they are — an Arabic caption under an English file name, say.
    private func textAlignment(_ text: String) -> HorizontalAlignment {
      CnctUserText.layout(of: text, interface: interface) == interface ? .leading : .trailing
    }
  }

  /// The message this one replies to, drawn above its words: a bar, whose it was, and its first
  /// words or the kind of file it was.
  struct CnctQuoteView: View {
    let quote: CnctChatQuote
    let ink: CnctChatColor
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.5).color).frame(width: 3)
        VStack(alignment: .leading, spacing: 2) {
          if quote.mine {
            Text(words("quoteYou")).font(theme.font(.caption, weight: .semibold)).foregroundColor(ink.color)
          }
          CnctUserText(text: excerpt, style: .footnote, color: ink.opacity(0.8), lineLimit: 2)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(words("showQuoted") + ": " + excerpt)
    }

    private var excerpt: String {
      if let text = quote.excerpt { return text }
      switch quote.attachmentKind {
      case .image: return words("quoteIMAGE")
      case .video: return words("quoteVIDEO")
      case .audio: return words("quoteAUDIO")
      case .sticker: return words("quoteSTICKER")
      case .document, .other: return words("quoteDOCUMENT")
      case nil: return words("quoteEarlier")
      }
    }
  }

  /// A picture, film or document a flow put above its words, from its public address.
  struct CnctFlowMedia: View {
    let media: CnctChatFlow.Media
    let ink: CnctChatColor
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.openURL) var openURL

    var body: some View {
      if media.kind == "image" {
        AsyncImage(url: media.url) { phase in
          if let image = phase.image {
            image.resizable().aspectRatio(contentMode: .fit)
          } else {
            theme.border.color.aspectRatio(4 / 3, contentMode: .fit)
          }
        }
        .frame(maxWidth: 240, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: max(4, theme.cornerRadius - 6), style: .continuous))
        .accessibilityHidden(true)
      } else {
        let name = media.filename ?? words("attachment")
        Button {
          openURL(media.url)
        } label: {
          Label(name, systemImage: media.kind == "video" ? "play.rectangle" : "doc")
            .font(theme.font(.subheadline, weight: .medium))
            .foregroundColor(ink.color)
        }
        .accessibilityLabel(words("openDocument", ["name": name]))
      }
    }
  }

  /// A file in a message: a photo inline, anything else as a card that opens in the system viewer.
  struct CnctAttachmentView: View {
    @ObservedObject var model: CnctChatModel
    let attachment: CnctChatAttachment
    let ink: CnctChatColor
    let signer: String

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.cnctFormat) var format
    @State var image: UIImage?
    @State var failed = false

    private var name: String { attachment.filename ?? words("attachment") }
    private var isImage: Bool { attachment.kind == .image || attachment.mimeType.hasPrefix("image/") }

    var body: some View {
      if isImage {
        Button {
          model.viewing = attachment
        } label: {
          picture
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(words("quoteIMAGE")))
        .task(id: attachment.id) {
          image = await model.image(for: attachment)
          failed = image == nil
        }
      } else {
        Button {
          model.open(attachment)
        } label: {
          card
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(words("quoteDOCUMENT")))
        .accessibilityHint(words("openDocument", ["name": name]))
      }
    }

    /// "Sara: Photo, photo.jpg, 1.2 MB".
    private func label(_ kind: String) -> String {
      var parts = [kind, name]
      if let bytes = attachment.bytes { parts.append(format.size(bytes)) }
      return "\(signer): " + parts.joined(separator: words("listSeparator"))
    }

    @ViewBuilder private var picture: some View {
      let shape = RoundedRectangle(cornerRadius: max(4, theme.cornerRadius - 2), style: .continuous)
      if let image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(image.size, contentMode: .fit)
          .frame(maxWidth: 240, maxHeight: 300)
          .clipShape(shape)
      } else if failed {
        Text(words("couldNotLoad", ["name": name]))
          .font(theme.font(.footnote))
          .foregroundColor(ink.color)
          .padding(12)
      } else {
        theme.border.color
          .aspectRatio(4 / 3, contentMode: .fit)
          .frame(width: 240)
          .overlay(ProgressView())
          .clipShape(shape)
      }
    }

    private var card: some View {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .font(.system(size: 18, weight: .medium))
          .foregroundColor(ink.color)
          .frame(width: 40, height: 40)
          .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink.opacity(0.12).color))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          CnctUserText(text: name, style: .subheadline, weight: .medium, color: ink, lineLimit: 2)
          if let bytes = attachment.bytes {
            Text(format.size(bytes)).font(theme.font(.caption)).foregroundColor(ink.opacity(0.75).color)
          }
        }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }

    private var icon: String {
      switch attachment.kind {
      case .video: return "film"
      case .audio: return "waveform"
      case .image, .sticker: return "photo"
      case .document, .other:
        return attachment.mimeType == "application/pdf" ? "doc.richtext" : "doc"
      }
    }
  }

  /// A flow's choices: pills for short ones, rows for ones with a description or a list. Only the
  /// last question's choices can be tapped; earlier ones stay, dimmed, as a record of what was asked.
  struct CnctChoicesView: View {
    let flow: CnctChatFlow
    let active: Bool
    let choose: (CnctChatFlow.Choice) -> Void

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        if flow.choicesAsRows, let label = flow.listButton {
          CnctUserText(text: label, style: .caption, weight: .semibold, color: theme.textMuted)
        }
        ForEach(flow.choices) { choice in
          Button {
            choose(choice)
          } label: {
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                CnctUserText(
                  text: choice.title, style: .subheadline, weight: .semibold,
                  color: active ? theme.primaryText : theme.textMuted)
                if let description = choice.description {
                  CnctUserText(text: description, style: .caption, color: theme.textMuted)
                }
              }
              if flow.choicesAsRows {
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundColor(theme.textMuted.color)
                  .accessibilityHidden(true)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .frame(maxWidth: flow.choicesAsRows ? .infinity : nil, alignment: .leading)
            .background(
              RoundedRectangle(cornerRadius: flow.choicesAsRows ? min(theme.cornerRadius, 12) : 22, style: .continuous)
                .fill(theme.background.color)
            )
            .overlay(
              RoundedRectangle(cornerRadius: flow.choicesAsRows ? min(theme.cornerRadius, 12) : 22, style: .continuous)
                .stroke(active ? theme.primary.opacity(0.6).color : theme.border.color, lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
          // Answered, or overtaken: still there as a record of what was asked, no longer a button.
          .disabled(!active)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 4)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(flow.listButton ?? words("choices"))
    }
  }

  /// The assistant's suggested replies, as chips. Tapping one sends it.
  struct CnctSuggestionsView: View {
    let suggestions: [String]
    let send: (String) -> Void
    @Environment(\.cnctTheme) var theme

    var body: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(suggestions, id: \.self) { suggestion in
            Button {
              send(suggestion)
            } label: {
              CnctUserText(text: suggestion, style: .subheadline, weight: .medium, color: theme.primaryText, lineLimit: 1)
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .background(Capsule().fill(theme.primary.opacity(0.10).color))
                .overlay(Capsule().stroke(theme.primary.opacity(0.35).color, lineWidth: 1))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 4)
      }
    }
  }

  /// Three dots where the team's next words will be.
  struct CnctTypingView: View {
    @Environment(\.cnctTheme) var theme
    @State var phase = false

    var body: some View {
      HStack {
        HStack(spacing: 5) {
          ForEach(0..<3) { index in
            Circle()
              .fill(theme.onAgentBubble.opacity(0.5).color)
              .frame(width: 7, height: 7)
              .opacity(phase ? (index == 1 ? 1 : 0.45) : (index == 1 ? 0.45 : 1))
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.agentBubble.color))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.border.color, lineWidth: 1))
        Spacer()
      }
      .accessibilityHidden(true)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { phase = true }
      }
    }
  }
#endif
