#if os(iOS)
  import CNCT
  import PhotosUI
  import QuickLook
  import SwiftUI
  import UIKit
  import UniformTypeIdentifiers

  /// Reading what a picker handed over, off the main thread — a 50 MB film should not freeze the
  /// chat while it is read.
  ///
  /// `nonisolated` on purpose: the system calls these completions on queues of its own, and a
  /// closure written inside main-actor code would be expected to run on the main actor.
  enum CnctPickerFiles {
    /// Load every item a photo picker returned, in the order they were picked, then hand them over
    /// on the main actor.
    nonisolated static func load(_ providers: [NSItemProvider], then deliver: @escaping @MainActor @Sendable ([CnctPickedFile]) -> Void) {
      let collected = Collected(count: providers.count)
      let group = DispatchGroup()
      for (index, provider) in providers.enumerated() {
        group.enter()
        load(provider) { picked in
          collected.set(index, picked)
          group.leave()
        }
      }
      group.notify(queue: .main) {
        let picked = collected.all
        Task { @MainActor in deliver(picked) }
      }
    }

    private nonisolated static func load(_ provider: NSItemProvider, _ done: @escaping @Sendable (CnctPickedFile) -> Void) {
      let registered = provider.registeredTypeIdentifiers
      // The original, not a converted copy: a photo is converted and scaled once, by the SDK.
      let type =
        registered.first { UTType($0)?.conforms(to: .image) == true || UTType($0)?.conforms(to: .movie) == true }
        ?? registered.first
      let suggested = provider.suggestedName
      guard let type else {
        done(.failed(suggested ?? "file"))
        return
      }
      provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, _ in
        guard let url else {
          done(.failed(suggested ?? "file"))
          return
        }
        let utType = UTType(type)
        let ext = utType?.preferredFilenameExtension ?? url.pathExtension
        let base = suggested ?? url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty || base.lowercased().hasSuffix(".\(ext.lowercased())") ? base : "\(base).\(ext)"
        done(read(url, name: name, mimeType: utType?.preferredMIMEType))
      }
    }

    /// One file from disk: refused unread when it is over the limit, so a huge film is never pulled
    /// into memory to be thrown away.
    nonisolated static func read(_ url: URL, name: String? = nil, mimeType: String? = nil) -> CnctPickedFile {
      let filename = name ?? url.lastPathComponent
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size > CnctChatAttachments.maxBytes { return .tooBig(filename) }
      guard let data = try? Data(contentsOf: url) else { return .failed(filename) }
      let type = mimeType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
      return .file(CnctUploadFile(data: data, filename: filename, mimeType: type))
    }

    /// Results in pick order, filled from whichever queue each arrives on.
    private final class Collected: @unchecked Sendable {
      private let lock = NSLock()
      private var items: [CnctPickedFile?]

      init(count: Int) { items = Array(repeating: nil, count: count) }

      func set(_ index: Int, _ item: CnctPickedFile) {
        lock.lock()
        defer { lock.unlock() }
        items[index] = item
      }

      var all: [CnctPickedFile] {
        lock.lock()
        defer { lock.unlock() }
        return items.compactMap { $0 }
      }
    }
  }

  /// The system photo picker: several at once, no permission asked — the visitor chooses, and only
  /// what they chose is shared.
  struct CnctPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let onPick: @MainActor @Sendable ([CnctPickedFile]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
      var configuration = PHPickerConfiguration()
      configuration.selectionLimit = max(1, limit)
      configuration.filter = .any(of: [.images, .videos])
      // The photo as it is, HEIC and all: the SDK converts and scales it, once.
      configuration.preferredAssetRepresentationMode = .current
      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PHPickerViewControllerDelegate {
      let onPick: @MainActor @Sendable ([CnctPickedFile]) -> Void

      init(_ onPick: @escaping @MainActor @Sendable ([CnctPickedFile]) -> Void) {
        self.onPick = onPick
      }

      func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard !results.isEmpty else {
          onPick([])
          return
        }
        let onPick = self.onPick
        CnctPickerFiles.load(results.map(\.itemProvider)) { picked in onPick(picked) }
      }
    }
  }

  /// The camera, on a phone that has one.
  struct CnctCameraPicker: UIViewControllerRepresentable {
    let onPick: @MainActor @Sendable ([CnctPickedFile]) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
      let onPick: @MainActor @Sendable ([CnctPickedFile]) -> Void

      init(_ onPick: @escaping @MainActor @Sendable ([CnctPickedFile]) -> Void) {
        self.onPick = onPick
      }

      func imagePickerController(
        _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
      ) {
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
          onPick([])
          return
        }
        onPick([.file(CnctUploadFile(data: data, filename: "photo.jpg", mimeType: "image/jpeg"))])
      }

      func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        onPick([])
      }
    }
  }

  /// The Files picker, copying what it opens so nothing needs a security scope afterwards.
  struct CnctDocumentPicker: UIViewControllerRepresentable {
    let onPick: @MainActor @Sendable ([CnctPickedFile]) -> Void

    static let types: [UTType] = [
      .image, .movie, .audio, .pdf, .plainText, .commaSeparatedText,
      UTType("com.microsoft.word.doc"),
      UTType("org.openxmlformats.wordprocessingml.document"),
      UTType("org.openxmlformats.spreadsheetml.sheet"),
    ].compactMap { $0 }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.types, asCopy: true)
      picker.allowsMultipleSelection = true
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
      let onPick: @MainActor @Sendable ([CnctPickedFile]) -> Void

      init(_ onPick: @escaping @MainActor @Sendable ([CnctPickedFile]) -> Void) {
        self.onPick = onPick
      }

      func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let onPick = self.onPick
        Task.detached(priority: .userInitiated) {
          let picked = urls.map { CnctPickerFiles.read($0) }
          await onPick(picked)
        }
      }

      func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick([])
      }
    }
  }

  /// A downloaded file in the system viewer, with the share button the viewer brings.
  struct CnctDocumentPreview: UIViewControllerRepresentable {
    let url: URL
    let done: String

    func makeUIViewController(context: Context) -> UINavigationController {
      let preview = QLPreviewController()
      preview.dataSource = context.coordinator
      preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
        title: done, style: .done, target: context.coordinator, action: #selector(Coordinator.close))
      context.coordinator.controller = preview
      return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency QLPreviewControllerDataSource {
      let url: URL
      weak var controller: UIViewController?

      init(_ url: URL) {
        self.url = url
      }

      func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

      func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
      }

      @objc func close() {
        controller?.dismiss(animated: true)
      }
    }
  }

  /// A photo full screen: pinch or double-tap to zoom, swipe down or tap the button to close.
  struct CnctImageViewer: View {
    @ObservedObject var model: CnctChatModel
    let attachment: CnctChatAttachment

    @Environment(\.cnctWords) var words
    @Environment(\.dismiss) var dismiss
    @State var image: UIImage?

    var body: some View {
      ZStack(alignment: .topLeading) {
        Color.black.ignoresSafeArea()
        if let image {
          CnctZoomableImage(image: image) { dismiss() }
            .ignoresSafeArea()
            .accessibilityLabel(attachment.filename ?? words("quoteIMAGE"))
        } else {
          ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .padding(12)
        .accessibilityLabel(words("back"))
      }
      .task { image = await model.image(for: attachment) }
    }
  }

  /// UIKit's scroll view, for zooming that feels like Photos.
  struct CnctZoomableImage: UIViewRepresentable {
    let image: UIImage
    let close: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
      let scroll = UIScrollView()
      scroll.delegate = context.coordinator
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 5
      scroll.showsVerticalScrollIndicator = false
      scroll.showsHorizontalScrollIndicator = false
      scroll.backgroundColor = .black
      let view = UIImageView(image: image)
      view.contentMode = .scaleAspectFit
      view.translatesAutoresizingMaskIntoConstraints = false
      scroll.addSubview(view)
      NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      ])
      context.coordinator.imageView = view
      let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
      doubleTap.numberOfTapsRequired = 2
      scroll.addGestureRecognizer(doubleTap)
      let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
      swipe.direction = .down
      scroll.addGestureRecognizer(swipe)
      return scroll
    }

    func updateUIView(_ view: UIScrollView, context: Context) {
      context.coordinator.close = close
    }

    func makeCoordinator() -> Coordinator { Coordinator(close) }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
      var close: () -> Void
      weak var imageView: UIImageView?

      init(_ close: @escaping () -> Void) {
        self.close = close
      }

      func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

      @objc func zoom(_ gesture: UITapGestureRecognizer) {
        guard let scroll = gesture.view as? UIScrollView else { return }
        if scroll.zoomScale > 1 {
          scroll.setZoomScale(1, animated: true)
        } else {
          let point = gesture.location(in: imageView)
          let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
          scroll.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
      }

      /// Down to close — only when not zoomed in, where a swipe is a pan around the photo.
      @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard let scroll = gesture.view as? UIScrollView, scroll.zoomScale <= 1.01 else { return }
        close()
      }
    }
  }
#endif
