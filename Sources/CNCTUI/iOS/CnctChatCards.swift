#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  /// "How did we do?" under a conversation that has ended: five faces, worst to best, each with its
  /// word — a face is read differently across cultures, and a screen reader reads none of them well.
  struct CnctRatingCard: View {
    @ObservedObject var model: CnctChatModel
    let conversation: CnctChatConversation

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @State var commentHeight: CGFloat = 44

    /// Worst to best.
    static let faces = ["😠", "🙁", "😐", "🙂", "😄"]

    var body: some View {
      let stage = model.shownRatingStage
      let score = model.shownScore
      VStack(spacing: 12) {
        Text(stage == .faces ? words("ratePrompt") : words("rated"))
          .font(theme.font(.headline, weight: .semibold))
          .foregroundColor(theme.text.color)
          .multilineTextAlignment(.center)
        HStack(spacing: 6) {
          ForEach(1...5, id: \.self) { value in
            Button {
              model.rate(value)
            } label: {
              Text(verbatim: Self.faces[value - 1])
                .font(.system(size: 28))
                .frame(minWidth: 48, minHeight: 48)
                .background(Circle().fill(score == value ? theme.primary.opacity(0.18).color : Color.clear))
                .overlay(Circle().stroke(score == value ? theme.primary.color : Color.clear, lineWidth: 2))
                .opacity(score == nil || score == value ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!conversation.ratable)
            .accessibilityLabel(words("rating\(value)"))
            .accessibilityAddTraits(score == value ? .isSelected : [])
          }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(words("ratePrompt"))
        if let score {
          Text(words("rating\(score)")).font(theme.font(.footnote, weight: .medium)).foregroundColor(theme.textMuted.color)
        }
        if stage == .comment {
          ZStack(alignment: .topLeading) {
            CnctComposerField(
              text: $model.ratingComment, height: $commentHeight, font: theme.uiFont(.body), color: theme.text.uiColor,
              tint: theme.primary.uiColor, keyboard: .default, contentType: nil, rightToLeft: words.language.isRightToLeft,
              label: words("tellUsMore"), maxLines: 4
            )
            .frame(height: max(44, commentHeight))
            if model.ratingComment.isEmpty {
              Text(words("tellUsMore")).font(theme.font(.body)).foregroundColor(theme.textMuted.color)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
          }
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.background.color))
          .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border.color, lineWidth: 1))
          HStack {
            Button(words("skip")) { model.skipComment() }
              .font(theme.font(.subheadline, weight: .medium))
              .foregroundColor(theme.textMuted.color)
              .frame(minHeight: 44)
            Spacer()
            CnctPrimaryButton(title: words("send"), small: true) { model.sendComment() }
          }
        } else if let comment = conversation.rating?.comment, !comment.isEmpty {
          CnctUserText(text: comment, style: .subheadline, color: theme.textMuted, alignment: .center)
        }
        if let notice = model.ratingNotice {
          Text(words(notice.key, notice.values)).font(theme.font(.footnote)).foregroundColor(theme.danger.color)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity)
      .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.surface.color))
      .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.border.color, lineWidth: 1))
    }
  }

  /// "Who are we talking to?" in the thread, for a visitor who wrote before giving a name.
  struct CnctDetailsCard: View {
    @ObservedObject var model: CnctChatModel
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Text(words("detailsTitle")).font(theme.font(.headline, weight: .semibold)).foregroundColor(theme.text.color)
        Text(words("detailsBody")).font(theme.font(.subheadline)).foregroundColor(theme.textMuted.color)
          .fixedSize(horizontal: false, vertical: true)
        CnctTextField(placeholder: words("yourName"), text: $model.detailsName, contentType: .givenName)
        if model.inbox?.requirePhone == true {
          CnctTextField(placeholder: words("detailsPhone"), text: $model.detailsPhone, contentType: .telephoneNumber, keyboard: .phonePad)
        }
        CnctPrimaryButton(title: words("detailsSave"), small: true, busy: model.savingDetails) { model.saveDetails() }
          .disabled(model.detailsName.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).fill(theme.surface.color))
      .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous).stroke(theme.border.color, lineWidth: 1))
    }
  }

  /// Before the conversation, when the inbox asks for a name first: who the business is, its
  /// greeting, the name (and a phone number where the inbox wants one), and what is kept.
  struct CnctChatIntro: View {
    @ObservedObject var model: CnctChatModel
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @State var name = ""
    @State var phone = ""

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(spacing: 10) {
            CnctLogo(size: 64)
            CnctUserText(text: theme.title, style: .title3, weight: .bold, color: theme.text, alignment: .center)
            if let greeting = model.inbox?.greeting, !greeting.isEmpty {
              CnctUserText(text: greeting, style: .body, color: theme.textMuted, alignment: .center)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.bottom, 8)

          VStack(alignment: .leading, spacing: 6) {
            Text(words("yourName")).font(theme.font(.subheadline, weight: .semibold)).foregroundColor(theme.text.color)
            CnctTextField(placeholder: words("namePlaceholder"), text: $name, contentType: .givenName)
          }
          if model.inbox?.requirePhone == true {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 4) {
                Text(words("phoneNumber")).font(theme.font(.subheadline, weight: .semibold)).foregroundColor(theme.text.color)
                Text(words("optional")).font(theme.font(.subheadline)).italic().foregroundColor(theme.textMuted.color)
              }
              CnctTextField(placeholder: "+973 …", text: $phone, contentType: .telephoneNumber, keyboard: .phonePad)
              Text(words("phoneHint")).font(theme.font(.footnote)).foregroundColor(theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          CnctPrimaryButton(title: model.starting ? words("starting") : words("startChatting"), busy: model.starting) {
            model.submitIntro(name: name, phone: phone)
          }
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.starting)
          if let notice = model.introNotice {
            Text(words(notice.key, notice.values)).font(theme.font(.footnote)).foregroundColor(theme.danger.color)
          }
          Text(words("legal")).font(theme.font(.footnote)).foregroundColor(theme.textMuted.color)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
      }
      .background(theme.background.color)
    }
  }

  /// A single-line field in the chat's colours.
  struct CnctTextField: View {
    let placeholder: String
    @Binding var text: String
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default

    @Environment(\.cnctTheme) var theme

    var body: some View {
      TextField(placeholder, text: $text)
        .font(theme.font(.body))
        .foregroundColor(theme.text.color)
        .textContentType(contentType)
        .keyboardType(keyboard)
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.background.color))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border.color, lineWidth: 1))
    }
  }

  /// The brand-coloured button.
  struct CnctPrimaryButton: View {
    let title: String
    var small = false
    var busy = false
    let action: () -> Void

    @Environment(\.cnctTheme) var theme
    @Environment(\.isEnabled) var enabled

    var body: some View {
      Button(action: action) {
        HStack(spacing: 8) {
          if busy { ProgressView().tint(theme.onPrimary.color) }
          Text(title).font(theme.font(small ? .subheadline : .body, weight: .semibold))
        }
        .foregroundColor(theme.onPrimary.color)
        .padding(.horizontal, small ? 18 : 20)
        .frame(maxWidth: small ? nil : .infinity, minHeight: small ? 44 : 50)
        .background(RoundedRectangle(cornerRadius: min(theme.cornerRadius, 14), style: .continuous).fill(theme.primary.color))
        .opacity(enabled ? 1 : 0.5)
      }
      .buttonStyle(.plain)
    }
  }
#endif
