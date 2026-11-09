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
  /// to `screenshots/` at the root of the repository.
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

    @MainActor
    private func render(_ language: CnctChatLanguage, _ look: Look) throws -> UIImage {
      let theme: CnctChatTheme
      switch look {
      case .light: theme = CnctChatTheme(appearance: .light)
      case .dark: theme = CnctChatTheme(appearance: .dark)
      case .custom: theme = CnctChatFixture.customTheme
      }
      let size = CGSize(width: Self.width, height: Self.height)
      let controller = UIHostingController(rootView: CnctChatView(fixture: language, theme: theme, onClose: {}))
      let window = UIWindow(frame: CGRect(origin: .zero, size: size))
      window.overrideUserInterfaceStyle = look == .dark ? .dark : .light
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
      var image = renderer.image { context in
        controller.view.layer.render(in: context.cgContext)
      }
      if Self.isBlank(image) {
        image = renderer.image { _ in
          _ = controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
      }
      window.isHidden = true
      window.rootViewController = nil
      return image
    }

    private static func folder() -> URL {
      if let path = ProcessInfo.processInfo.environment["CNCT_SCREENSHOTS_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: path, isDirectory: true)
      }
      return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("screenshots", isDirectory: true)
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
