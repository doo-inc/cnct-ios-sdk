#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit

  /// The box at the bottom: the files waiting to go, the attach button, the words, and send.
  ///
  /// It grows to five lines and then scrolls; send is off while there is nothing to send or a file
  /// is still on its way up; and the keyboard is the one a flow's question asks for — numbers for a
  /// number, the email keyboard for an address.
  struct CnctComposer: View {
    @ObservedObject var model: CnctChatModel

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.layoutDirection) var direction
    @State var height: CGFloat = 22

    var body: some View {
      VStack(spacing: 8) {
        if !model.uploads.isEmpty {
          CnctUploadTray(model: model)
        }
        HStack(alignment: .bottom, spacing: 6) {
          if model.canAttach {
            CnctAttachMenu(model: model)
          }
          ZStack(alignment: .topLeading) {
            CnctComposerField(
              text: $model.draft,
              height: $height,
              font: theme.uiFont(.body),
              color: theme.text.uiColor,
              tint: theme.primary.uiColor,
              keyboard: keyboard,
              contentType: contentType,
              rightToLeft: direction == .rightToLeft,
              label: words("message")
            )
            .frame(height: height)
            if model.draft.isEmpty {
              // Wraps rather than truncates at the large text sizes, and the box grows with it.
              Text(placeholder)
                .font(theme.font(.body))
                .foregroundColor(theme.textMuted.color)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.background.color))
          .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(theme.border.color, lineWidth: 1))

          Button {
            model.send()
          } label: {
            Image(systemName: "paperplane.fill")
              .font(.system(size: 17, weight: .semibold))
              .flipsForRightToLeftLayoutDirection(true)
              .foregroundColor(theme.onPrimary.color)
              .frame(width: 44, height: 44)
              .background(Circle().fill(theme.primary.color))
          }
          .disabled(!model.canSend)
          .opacity(model.canSend ? 1 : 0.4)
          .accessibilityLabel(model.uploading ? words("uploading") : words("send"))
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(theme.surface.color.ignoresSafeArea(edges: .bottom))
      .overlay(alignment: .top) { Rectangle().fill(theme.border.color).frame(height: 1) }
    }

    private var placeholder: String {
      switch model.expects {
      case .name: return words("answerName")
      case .number: return words("answerNumber")
      case .email: return words("answerEmail")
      case .phone: return words("answerPhone")
      case .date: return words("answerDate")
      case nil: return model.awaitingChoices ? words("chooseOrWrite") : words("writeMessage")
      }
    }

    private var keyboard: UIKeyboardType {
      switch model.expects {
      case .number: return .decimalPad
      case .email: return .emailAddress
      case .phone: return .phonePad
      case .name, .date, nil: return .default
      }
    }

    private var contentType: UITextContentType? {
      switch model.expects {
      case .name: return .givenName
      case .email: return .emailAddress
      case .phone: return .telephoneNumber
      case .number, .date, nil: return nil
      }
    }
  }

  /// A text view that grows with what is typed into it, up to a few lines, and then scrolls.
  ///
  /// UIKit rather than SwiftUI because iOS 15 has no growing text field, and because a keyboard type
  /// that changes while the field is focused only takes effect through `reloadInputViews`.
  struct CnctComposerField: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let font: UIFont
    let color: UIColor
    let tint: UIColor
    let keyboard: UIKeyboardType
    let contentType: UITextContentType?
    let rightToLeft: Bool
    let label: String
    var maxLines = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.delegate = context.coordinator
      view.backgroundColor = .clear
      view.textContainerInset = .zero
      view.textContainer.lineFragmentPadding = 0
      view.isScrollEnabled = false
      view.adjustsFontForContentSizeCategory = true
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      view.setContentHuggingPriority(.defaultLow, for: .horizontal)
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.parent = self
      if view.text != text { view.text = text }
      if view.font != font { view.font = font }
      view.textColor = color
      view.tintColor = tint
      view.textContentType = contentType
      view.accessibilityLabel = label
      view.semanticContentAttribute = rightToLeft ? .forceRightToLeft : .forceLeftToRight
      view.textAlignment = .natural
      if view.keyboardType != keyboard {
        view.keyboardType = keyboard
        if view.isFirstResponder { view.reloadInputViews() }
      }
      context.coordinator.measure(view)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: CnctComposerField

      init(_ parent: CnctComposerField) {
        self.parent = parent
      }

      func textViewDidChange(_ textView: UITextView) {
        if parent.text != textView.text { parent.text = textView.text }
        measure(textView)
      }

      /// Fit the height to the text, up to `maxLines`; past that the view scrolls. Applied on the
      /// next turn of the run loop, because SwiftUI does not take a state change in the middle of
      /// an update.
      func measure(_ view: UITextView) {
        let font = view.font ?? parent.font
        let width = view.bounds.width > 0 ? view.bounds.width : 240
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let ceiling = ceil(font.lineHeight * CGFloat(parent.maxLines))
        let next = max(ceil(font.lineHeight), min(ceil(fitting), ceiling))
        view.isScrollEnabled = fitting > ceiling
        guard abs(next - parent.height) > 0.5 else { return }
        Task { @MainActor [weak self] in
          self?.parent.height = next
        }
      }
    }
  }

  /// The files waiting to go: a thumbnail or an icon, the name and size, the upload's progress, and
  /// a way to take each one back out.
  struct CnctUploadTray: View {
    @ObservedObject var model: CnctChatModel
    @Environment(\.cnctTheme) var theme

    var body: some View {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(model.uploads) { upload in
            CnctUploadChip(upload: upload) { model.remove(upload) }
          }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
      }
    }
  }

  struct CnctUploadChip: View {
    let upload: CnctChatModel.Upload
    let remove: () -> Void

    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words
    @Environment(\.cnctFormat) var format
    @Environment(\.layoutDirection) var direction
    @Environment(\.dynamicTypeSize) var typeSize

    var body: some View {
      HStack(spacing: 8) {
        thumbnail
        VStack(alignment: .leading, spacing: 2) {
          CnctUserText(
            text: upload.filename, style: .footnote, weight: .medium, color: theme.text,
            lineLimit: typeSize.isAccessibilitySize ? 3 : 1
          )
          .frame(maxWidth: typeSize.isAccessibilitySize ? 200 : 140, alignment: .leading)
          Text(status)
            .font(theme.font(.caption2))
            .foregroundColor(upload.status == .failed ? theme.danger.color : theme.textMuted.color)
        }
        if upload.status == .uploading {
          ring
        }
        Button(action: remove) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 18))
            .foregroundColor(theme.textMuted.color)
            .frame(width: 32, height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(words("removeFile", ["name": upload.filename]))
      }
      .padding(.leading, 6)
      .padding(.trailing, 2)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.background.color))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(upload.status == .failed ? theme.danger.color : theme.border.color, lineWidth: 1)
      )
      .accessibilityElement(children: .contain)
    }

    private var status: String {
      switch upload.status {
      case .uploading: return words("uploading")
      case .failed: return words("uploadFailed", ["name": ""]).trimmingCharacters(in: .whitespaces)
      case .done: return format.size(upload.attachment?.bytes ?? upload.bytes)
      }
    }

    @ViewBuilder private var thumbnail: some View {
      let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
      if let data = upload.preview, let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 96, height: 96)) {
        Image(uiImage: image).resizable().scaledToFill().frame(width: 40, height: 40).clipShape(shape)
          .accessibilityHidden(true)
      } else {
        Text(verbatim: Self.fileExtension(upload.filename))
          .font(.system(size: 10, weight: .bold))
          .foregroundColor(theme.primaryText.color)
          .frame(width: 40, height: 40)
          .background(shape.fill(theme.primary.opacity(0.12).color))
          .accessibilityHidden(true)
      }
    }

    /// The upload's progress, as a ring that fills the way the interface reads.
    private var ring: some View {
      ZStack {
        Circle().stroke(theme.border.color, lineWidth: 3)
        Circle()
          .trim(from: 0, to: max(0.04, upload.progress))
          .stroke(theme.primary.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .scaleEffect(x: direction == .rightToLeft ? -1 : 1, y: 1)
      }
      .frame(width: 20, height: 20)
      .accessibilityElement()
      .accessibilityLabel(words("uploading"))
      .accessibilityValue(Text(verbatim: "\(Int((upload.progress * 100).rounded()))%"))
    }

    static func fileExtension(_ name: String) -> String {
      guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "FILE" }
      return String(name[name.index(after: dot)...].prefix(4)).uppercased()
    }
  }

  /// The paperclip: the photo library, the camera where there is one, and files.
  struct CnctAttachMenu: View {
    @ObservedObject var model: CnctChatModel
    @Environment(\.cnctTheme) var theme
    @Environment(\.cnctWords) var words

    var body: some View {
      Menu {
        Button {
          model.picker = .photos
        } label: {
          Label(words("attachPhotos"), systemImage: "photo.on.rectangle")
        }
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button {
            model.camera = true
          } label: {
            Label(words("attachCamera"), systemImage: "camera")
          }
        }
        Button {
          model.picker = .files
        } label: {
          Label(words("attachFiles"), systemImage: "doc")
        }
      } label: {
        Image(systemName: "paperclip")
          .font(.system(size: 20, weight: .medium))
          .foregroundColor(theme.textMuted.color)
          .frame(width: 40, height: 44)
          .contentShape(Rectangle())
      }
      .accessibilityLabel(words("attach"))
      .sheet(item: $model.picker) { picker in
        switch picker {
        case .photos:
          CnctPhotoPicker(limit: CnctChatAttachments.maxFiles - model.uploads.count) { picked in
            model.picker = nil
            model.add(picked)
          }
          .ignoresSafeArea()
        case .files:
          CnctDocumentPicker { picked in
            model.picker = nil
            model.add(picked)
          }
          .ignoresSafeArea()
        }
      }
      .fullScreenCover(isPresented: $model.camera) {
        CnctCameraPicker { picked in
          model.camera = false
          model.add(picked)
        }
        .ignoresSafeArea()
      }
    }
  }
#endif
