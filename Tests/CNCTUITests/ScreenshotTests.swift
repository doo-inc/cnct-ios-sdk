#if os(iOS)
  import CNCT
  import SwiftUI
  import UIKit
  import XCTest

  @testable import CNCTUI

  /// **The fixture conversation, rendered by the real screen, as PNGs** — what a reviewer looks at
  /// to approve a release.
  ///
  /// `{en, ar} × {light, dark}` with the default theme, and `{en, ar}` with the custom one. They are
  /// written to `$CNCT_SCREENSHOTS_DIR` (CI sets it through `TEST_RUNNER_CNCT_SCREENSHOTS_DIR`), or
  /// to `cnct-screenshots` in the temporary directory — never inside the package, where a new file
  /// sets Xcode resolving the package graph again under a running test.
  ///
  /// XCTest rather than Swift Testing for this one suite: a screen that boots, loads a photo and
  /// lays itself out needs the main run loop turning while it does, and spinning it is what
  /// `RunLoop.main.run(until:)` is for.
  final class ScreenshotTests: XCTestCase {
    enum Look: String { case light, dark, custom }

    static let width: CGFloat = 390
    static let height: CGFloat = 1280

    @MainActor
    func testScreenshots() throws {
      let folder = Self.folder()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for language in [CnctChatLanguage.en, .ar] {
        for look in [Look.light, .dark, .custom] {
          let image = try render(language, look)
          let data = try XCTUnwrap(image.pngData())
          let url = folder.appendingPathComponent("chat-\(language.rawValue)-\(look.rawValue).png")
          try data.write(to: url)
          print("Wrote \(url.path) (\(data.count) bytes)")
          XCTAssertFalse(Self.isBlank(image), "\(url.lastPathComponent) is blank")
        }
      }
    }

    /// Beyond the six the spec asks for: the screens the fixture's conversation does not reach, and
    /// the largest text size, where clipping would show.
    @MainActor
    func testMoreScreens() throws {
      let folder = Self.folder()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

      // Ended, rated four, and the box for more.
      let ended = CnctChatModel(client: CnctChatFixture.client(language: .en), ownsClient: true, identity: nil, fixture: .en)
      ended.open()
      Self.spin { ended.phase == .chat && ended.state.failed.count == 1 }
      ended.end()
      Self.spin { ended.state.conversation?.ratable == true }
      ended.rate(4)
      try save(
        render(CnctChatView(model: ended, theme: CnctChatTheme(appearance: .light), language: .en, onClose: {}), height: 1400),
        "chat-en-ended", to: folder)

      // A stranger, on an inbox that asks for a name first.
      let intro = CnctChatModel(client: CnctChatFixture.client(language: .ar), ownsClient: true, identity: nil)
      try save(
        render(CnctChatView(model: intro, theme: CnctChatTheme(appearance: .light), language: .ar, onClose: {}), height: 844),
        "chat-ar-intro", to: folder)

      for language in [CnctChatLanguage.en, .ar] {
        try save(
          render(
            CnctChatView(fixture: language, theme: CnctChatTheme(appearance: .light), onClose: {}), height: 2600,
            textSize: .accessibilityExtraExtraExtraLarge),
          "chat-\(language.rawValue)-largest-text", to: folder)
      }
    }

    @MainActor
    private func save(_ image: UIImage, _ name: String, to folder: URL) throws {
      let data = try XCTUnwrap(image.pngData())
      let url = folder.appendingPathComponent("\(name).png")
      try data.write(to: url)
      print("Wrote \(url.path) (\(data.count) bytes)")
      XCTAssertFalse(Self.isBlank(image), "\(name).png is blank")
    }

    @MainActor
    private static func spin(until condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(6)
      while Date() < deadline, !condition() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
    }

    @MainActor
    private func render(_ language: CnctChatLanguage, _ look: Look) throws -> UIImage {
      let theme: CnctChatTheme
      switch look {
      case .light: theme = CnctChatTheme(appearance: .light)
      case .dark: theme = CnctChatTheme(appearance: .dark)
      case .custom: theme = CnctChatFixture.customTheme
      }
      return try render(CnctChatView(fixture: language, theme: theme, onClose: {}), dark: look == .dark)
    }

    @MainActor
    private func render(
      _ view: CnctChatView, height: CGFloat = ScreenshotTests.height, dark: Bool = false,
      textSize: UIContentSizeCategory? = nil
    ) throws -> UIImage {
      let size = CGSize(width: Self.width, height: height)
      let controller = UIHostingController(
        rootView: view.environment(\.dynamicTypeSize, textSize == nil ? .large : .accessibility5))
      let window = UIWindow(frame: CGRect(origin: .zero, size: size))
      // SwiftUI's text follows the environment; the composer, a UIKit text view, follows the
      // window's traits.
      if #available(iOS 17.0, *) {
        if let textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
      }
      window.overrideUserInterfaceStyle = dark ? .dark : .light
      window.rootViewController = controller
      window.isHidden = false
      controller.view.frame = window.bounds

      // Boot, start, the failed send, the photo and the invoice: everything the fixture does, then
      // a beat for the layout to settle.
      let deadline = Date().addingTimeInterval(6)
      while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
      }

      let format = UIGraphicsImageRendererFormat()
      format.scale = 2
      format.opaque = true
      let renderer = UIGraphicsImageRenderer(size: size, format: format)
      // The first frame of a freshly made window on a freshly booted simulator is now and then
      // empty. A few more turns of the run loop and it is not. Only `layer.render`: with no app
      // host, `drawHierarchy(afterScreenUpdates:)` can wait on the render server for minutes.
      var image = renderer.image { context in controller.view.layer.render(in: context.cgContext) }
      for _ in 0..<8 where Self.isBlank(image) {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        image = renderer.image { context in controller.view.layer.render(in: context.cgContext) }
      }
      window.isHidden = true
      window.rootViewController = nil
      return image
    }

    private static func folder() -> URL {
      if let path = ProcessInfo.processInfo.environment["CNCT_SCREENSHOTS_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
      return FileManager.default.temporaryDirectory.appendingPathComponent("cnct-screenshots", isDirectory: true)
    }

    /// True when a picture is one colour all over — a render that drew nothing.
    static func isBlank(_ image: UIImage) -> Bool {
      guard let cgImage = image.cgImage,
        let data = cgImage.dataProvider?.data,
        let bytes = CFDataGetBytePtr(data)
      else { return true }
      let perRow = cgImage.bytesPerRow
      let perPixel = max(1, cgImage.bitsPerPixel / 8)
      var seen = Set<UInt32>()
      for y in stride(from: 0, to: cgImage.height, by: max(1, cgImage.height / 40)) {
        for x in stride(from: 0, to: cgImage.width, by: max(1, cgImage.width / 20)) {
          let offset = y * perRow + x * perPixel
          let pixel = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
          seen.insert(pixel)
          if seen.count > 8 { return false }
        }
      }
      return true
    }
  }

  /// The screen's behaviour on the simulator, through the fixture: what the composer offers, and
  /// what a tap does.
  final class ChatModelTests: XCTestCase {
    @MainActor
    private func playing(_ language: CnctChatLanguage = .en) -> CnctChatModel {
      let model = CnctChatModel(
        client: CnctChatFixture.client(language: language), ownsClient: true, identity: nil, fixture: language)
      model.open()
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline, !(model.phase == .chat && model.state.failed.count == 1 && model.uploads.count == 2) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      return model
    }

    @MainActor
    private func spin(until condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline, !condition() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
    }

    @MainActor
    func testFixtureLeavesTheScreenAsTheSpecDescribes() {
      let model = playing()
      XCTAssertEqual(model.phase, .chat)
      XCTAssertEqual(model.state.messages.count, 7)
      XCTAssertEqual(model.state.failed.count, 1)
      XCTAssertEqual(model.uploads.map(\.status), [.uploading, .done])
      // A file still on its way up holds the message back.
      model.draft = "Hello"
      XCTAssertFalse(model.canSend)
      XCTAssertTrue(model.canAttach)
      XCTAssertTrue(model.canEnd)
    }

    @MainActor
    func testRemovingTheUploadLetsTheMessageGo() {
      let model = playing()
      model.remove(model.uploads[0])
      model.draft = "Here is the menu"
      XCTAssertTrue(model.canSend)
      model.send()
      XCTAssertEqual(model.draft, "")
      XCTAssertTrue(model.uploads.isEmpty)
      spin { model.state.messages.last?.body == "Here is the menu" && model.state.messages.last?.pending == false }
      XCTAssertEqual(model.state.messages.last?.attachments.map(\.id), ["fx_menu"])
    }

    @MainActor
    func testTheEleventhFileIsRefusedWithASentence() {
      let model = playing()
      let files = (0..<9).map { CnctPickedFile.file(CnctUploadFile(data: Data("x".utf8), filename: "note\($0).txt")) }
      model.add(files)
      XCTAssertEqual(model.uploads.count, 10)
      XCTAssertEqual(model.notice?.key, "tooMany")
      model.add([.tooBig("film.mov")])
      XCTAssertEqual(model.notice, CnctChatModel.Notice(key: "tooBig", values: ["name": "film.mov"]))
    }

    @MainActor
    func testAWrongTypeIsRefusedBeforeUpload() {
      let model = playing()
      model.add([.file(CnctUploadFile(data: Data([0x4d, 0x5a]), filename: "setup.exe"))])
      XCTAssertEqual(model.notice?.key, "uploadFailed")
      XCTAssertEqual(model.uploads.count, 2)
    }

    @MainActor
    func testEndingThenRating() {
      let events = EventBox()
      let model = playing()
      model.onEvent = { events.append($0) }
      model.end()
      spin { model.state.conversation?.isLive == false && model.state.conversation?.ratable == true }
      XCTAssertFalse(model.composerOpen)
      XCTAssertTrue(events.all.contains(.ended))
      model.rate(4)
      XCTAssertEqual(model.shownScore, 4)
      XCTAssertEqual(model.shownRatingStage, .comment)
      spin { model.state.conversation?.rating?.score == 4 }
      XCTAssertTrue(events.all.contains(.rated(score: 4)))
      model.ratingComment = "Quick"
      model.sendComment()
      spin { model.state.conversation?.rating?.comment == "Quick" }
      XCTAssertEqual(model.shownRatingStage, .done)
    }
  }

  @MainActor
  private final class EventBox {
    var all: [CnctChatUIEvent] = []
    func append(_ event: CnctChatUIEvent) { all.append(event) }
  }
#endif
