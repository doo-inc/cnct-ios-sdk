#if os(iOS)
  import CNCT
  import SwiftUI

  /// Logo, title, the availability line, "End chat" where the inbox allows it, and close where the
  /// app asked for one.
  struct CnctChatHeader: View {
    @ObservedObject var model: CnctChatModel
    let onClose: (() -> Void)?

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.cnctFormat) var format

    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
      Group {
        // At the accessibility text sizes a single row has no room for the title, the line and the
        // buttons together; the title and the line get the full width on rows of their own.
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              CnctLogo(size: 40)
              Spacer(minLength: 8)
              actions
            }
            titles(lineLimit: nil)
          }
        } else {
          HStack(spacing: 12) {
            CnctLogo(size: 40)
            titles(lineLimit: 1)
            Spacer(minLength: 8)
            actions
          }
        }
      }
      .padding(.leading, 16)
      .padding(.trailing, onClose == nil ? 16 : 6)
      .padding(.vertical, 10)
      .background(theme.surface.color.ignoresSafeArea(edges: .top))
      .overlay(alignment: .bottom) {
        Rectangle().fill(theme.border.color).frame(height: 1)
      }
      .confirmationDialog(words("endConfirm"), isPresented: $model.confirmingEnd, titleVisibility: .visible) {
        Button(words("endChat"), role: .destructive) { model.end() }
        Button(words("keepChatting"), role: .cancel) {}
      }
    }

    private func titles(lineLimit: Int?) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        CnctUserText(text: theme.title, style: .headline, weight: .semibold, color: theme.text, lineLimit: lineLimit)
        HStack(spacing: 6) {
          if let color = presence {
            Circle().fill(color.color).frame(width: 8, height: 8).accessibilityHidden(true)
          }
          Text(line)
            .font(theme.font(.footnote))
            .foregroundColor(theme.textMuted.color)
            .lineLimit(lineLimit.map { $0 + 1 })
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
      if model.canEnd {
        Button(words("endChat")) { model.confirmingEnd = true }
          .font(theme.font(.subheadline, weight: .semibold))
          .foregroundColor(theme.primaryText.color)
          // Smaller rather than broken across lines: "End chat" split in two reads as two buttons.
          .lineLimit(1)
          .minimumScaleFactor(0.6)
          .frame(minHeight: 44)
      }
      if let onClose {
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(theme.text.color)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(words("closeChat"))
      }
    }

    /// Who the visitor can expect, said honestly: ended, somebody with them, or the availability
    /// sentence.
    private var line: String {
      if let conversation = model.state.conversation, !conversation.isLive {
        return format.ended(conversation.closedAt ?? conversation.startedAt, words: words)
      }
      if model.state.status == .offline { return words("connecting") }
      if model.state.conversation?.withPerson == true { return words("withPerson") }
      return format.availability(model.inbox?.availabilityLine ?? .replyUnknown, words: words)
    }

    /// A dot only where the inbox has opening hours to be in or out of; without them it would be a
    /// guess.
    private var presence: CnctChatColor? {
      guard model.state.conversation?.isLive != false, let open = model.inbox?.availability?.open else { return nil }
      if open { return theme.success }
      return model.inbox?.availability?.assistant == true ? theme.warning : theme.textMuted
    }
  }
#endif
