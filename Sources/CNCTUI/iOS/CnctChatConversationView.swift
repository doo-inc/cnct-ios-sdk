#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  /// The conversation: the thread, oldest at the top and scrolled to the newest, then the composer
  /// — or, once it has ended, a way to start another.
  struct CnctChatConversationView: View {
    @ObservedObject var model: CnctChatModel

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.cnctFormat) var format
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
      let rows = CnctChatRow.rows(
        for: model.state,
        day: { format.dayLabel($0, words: words) },
        justNamed: model.justNamed,
        askForRating: model.widget.chat.askForRating)
      VStack(spacing: 0) {
        if model.state.status == .offline {
          CnctOfflineBanner()
        }
        CnctThreadView(model: model, rows: rows)
        if let notice = model.notice {
          Text(words(notice.key, notice.values))
            .font(theme.font(.footnote))
            .foregroundColor(theme.danger.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isStaticText)
        }
        if model.composerOpen {
          CnctComposer(model: model)
        } else {
          CnctClosedFooter(model: model)
        }
        if theme.showPoweredBy {
          CnctPoweredBy()
        }
      }
      .onAppear { if scenePhase == .active { model.sawThread() } }
      .onChange(of: model.state.messages.last?.id) { _ in
        if scenePhase == .active { model.sawThread() }
      }
      .fullScreenCover(item: $model.viewing) { attachment in
        CnctImageViewer(model: model, attachment: attachment)
          .environment(\.cnctTheme, theme)
          .environment(\.cnctWords, words)
      }
      .sheet(item: $model.previewing) { preview in
        CnctDocumentPreview(url: preview.url, done: words("back")).ignoresSafeArea()
      }
    }
  }

  struct CnctOfflineBanner: View {
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      HStack(spacing: 8) {
        ProgressView().scaleEffect(0.8)
        Text(words("connecting")).font(theme.font(.footnote, weight: .medium))
      }
      .foregroundColor(theme.text.color)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 6)
      .background(theme.warning.opacity(0.18).color)
      .accessibilityElement(children: .combine)
    }
  }

  struct CnctPoweredBy: View {
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      Text(verbatim: "\(words("poweredBy")) CNCT")
        .font(theme.font(.caption2))
        .foregroundColor(theme.textMuted.color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(theme.surface.color.ignoresSafeArea(edges: .bottom))
    }
  }

  /// Under a conversation that has ended: the way to the next one.
  struct CnctClosedFooter: View {
    @ObservedObject var model: CnctChatModel
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      Button {
        model.startNew()
      } label: {
        Text(words("startNew"))
          .font(theme.font(.body, weight: .semibold))
          .foregroundColor(theme.onPrimary.color)
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(RoundedRectangle(cornerRadius: min(theme.cornerRadius, 14)).fill(theme.primary.color))
      }
      .disabled(model.starting)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(theme.surface.color)
      .overlay(alignment: .top) { Rectangle().fill(theme.border.color).frame(height: 1) }
    }
  }

  /// The thread itself.
  struct CnctThreadView: View {
    @ObservedObject var model: CnctChatModel
    let rows: [CnctChatRow]

    @Environment(\.cnctTheme) var theme

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(rows) { row in
              CnctRowView(model: model, row: row).id(row.id)
            }
            Color.clear.frame(height: 1).id(Self.bottom)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 12)
        }
        .background(theme.background.color)
        .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        .onChange(of: rows.last?.id) { _ in
          withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .onChange(of: rows.count) { _ in
          withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        // The newest message stays in sight when the keyboard comes up over it, and when the files
        // waiting above the composer take some of the thread's height, or give it back.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
          withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .onChange(of: model.uploads.isEmpty) { _ in
          withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
      }
    }

    static let bottom = "cnct-bottom"
  }

  struct CnctRowView: View {
    @ObservedObject var model: CnctChatModel
    let row: CnctChatRow

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      switch row {
      case .day(_, let label):
        Text(label)
          .font(theme.font(.caption, weight: .medium))
          .foregroundColor(theme.textMuted.color)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
          .accessibilityAddTraits(.isHeader)
      case .system(let message):
        CnctUserText(text: message.words, style: .footnote, color: theme.textMuted, link: theme.primary, alignment: .center)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 24)
          .padding(.vertical, 4)
      case .group(let group):
        CnctGroupView(model: model, group: group)
      case .choices(_, let flow, let active):
        CnctChoicesView(flow: flow, active: active && model.composerOpen) { model.choose($0) }
      case .suggestions(let suggestions):
        CnctSuggestionsView(suggestions: suggestions) { model.suggest($0) }
      case .typing:
        CnctTypingView()
      case .details:
        CnctDetailsCard(model: model)
      case .thanks(let name):
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill").foregroundColor(theme.success.color).accessibilityHidden(true)
          Text(words("detailsThanks", ["name": name])).font(theme.font(.subheadline)).foregroundColor(theme.text.color)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius).fill(theme.surface.color))
      case .ended:
        HStack(spacing: 10) {
          Rectangle().fill(theme.border.color).frame(height: 1)
          Text(words("endedDivider")).font(theme.font(.caption, weight: .medium)).foregroundColor(theme.textMuted.color)
            .fixedSize()
          Rectangle().fill(theme.border.color).frame(height: 1)
        }
        .padding(.vertical, 8)
      case .rating(let conversation):
        CnctRatingCard(model: model, conversation: conversation)
      }
    }
  }
#endif
