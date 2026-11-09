#if os(iOS)
  import CNCT
  import Foundation
  import SwiftUI
  import UIKit
  import os

  /// What the chat screen knows beyond the headless state: which screen it is on, the files waiting
  /// in the composer, the rating card's stage, and the words of a refusal to show.
  ///
  /// Everything it does goes through the public headless client — the screen is built on the same
  /// API an app building its own would use.
  @MainActor
  final class CnctChatModel: ObservableObject {
    enum Phase: Equatable {
      case loading
      case unavailable(title: String, body: String, values: [String: String])
      /// Asking for a name before the conversation starts.
      case intro
      case chat
    }

    /// A refusal or a failure, as words from the table — never the server's English sentence in an
    /// Arabic chat.
    struct Notice: Equatable {
      let key: String
      var values: [String: String] = [:]
    }

    enum RatingStage: Equatable { case faces, comment, done }

    enum Picker: String, Identifiable {
      case photos, files
      var id: String { rawValue }
    }

    /// A file in the composer, on its way up or waiting to go with the next message.
    struct Upload: Identifiable, Equatable {
      enum Status: Equatable { case uploading, done, failed }
      let id = UUID()
      let filename: String
      let mimeType: String
      let bytes: Int
      /// The picture itself, for an image's thumbnail.
      let preview: Data?
      var progress: Double
      var status: Status
      var attachment: CnctChatAttachment?

      var isImage: Bool { mimeType.hasPrefix("image/") }
    }

    /// A downloaded file, for the system viewer.
    struct Preview: Identifiable {
      let url: URL
      var id: URL { url }
    }

    @Published private(set) var state: CnctChatState
    @Published private(set) var phase: Phase = .loading
    @Published var draft = "" {
      didSet { if draft != oldValue, !draft.isEmpty { Task { await client.typing() } } }
    }
    @Published private(set) var uploads: [Upload] = []
    @Published var notice: Notice?
    @Published private(set) var introNotice: Notice?
    @Published private(set) var starting = false
    @Published private(set) var ratingStage: RatingStage = .faces
    @Published private(set) var ratingScore: Int?
    @Published var ratingComment = ""
    @Published private(set) var ratingNotice: Notice?
    @Published private(set) var justNamed: String?
    @Published var detailsName = ""
    @Published var detailsPhone = ""
    @Published private(set) var savingDetails = false
    @Published var confirmingEnd = false
    @Published var picker: Picker?
    @Published var camera = false
    @Published var viewing: CnctChatAttachment?
    @Published var previewing: Preview?

    let client: CnctChatClient
    var onEvent: ((CnctChatUIEvent) -> Void)?
    private let identity: CnctChatIdentity?
    private let fixture: CnctChatLanguage?
    /// Disposes the client with the screen, when the screen made it.
    private let owner: Owner?
    private var opened = false
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private var endedFor: Set<String> = []
    private let images = NSCache<NSString, UIImage>()
    private let log = Logger(subsystem: "com.cnct.sdk", category: "chat")

    init(client: CnctChatClient, ownsClient: Bool, identity: CnctChatIdentity?, fixture: CnctChatLanguage? = nil) {
      self.client = client
      self.identity = identity
      self.fixture = fixture
      self.owner = ownsClient ? Owner(client) : nil
      self.state = client.state
    }

    // MARK: - What the screen shows

    var inbox: CnctChatInbox? { state.inbox }
    var widget: CnctChatWidget { state.inbox?.widget ?? .defaults }

    /// True while there is a conversation to write in, or none yet — the first message starts one.
    var composerOpen: Bool { phase == .chat && state.isLive }

    var uploading: Bool { uploads.contains { $0.status == .uploading } }

    /// Send is offered when there is something to send and nothing still on its way up.
    var canSend: Bool {
      composerOpen && !uploading
        && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || uploads.contains { $0.status == .done })
    }

    var canAttach: Bool { composerOpen && widget.chat.allowAttachments }

    var canEnd: Bool {
      phase == .chat && widget.chat.allowEndConversation && state.conversation?.isLive == true && state.status != .ended
    }

    /// The visitor has given a name — or the app gave one for them by signing them in.
    var named: Bool { state.visitor.map { !$0.anonymous } ?? false }

    /// What a flow's question is waiting for, which picks the keyboard and the placeholder.
    var expects: CnctFlowExpects? { state.awaitingFlow?.flow?.expects }
    var awaitingChoices: Bool { !(state.awaitingFlow?.flow?.choices.isEmpty ?? true) }

    // MARK: - Opening

    /// Boot, sign in, pick up where they left off. Runs once, on its own task, so a screen that
    /// briefly disappears — under a full-screen photo, say — does not cancel it halfway.
    func open() {
      guard !opened else { return }
      opened = true
      Task { await listen() }
      Task { await listenForEvents() }
      Task { await run() }
    }

    private func run() async {
      onEvent?(.opened)
      let inbox: CnctChatInbox
      do {
        inbox = try await client.boot()
      } catch {
        let invalid = (error as? CnctError)?.status == 404
        phase = .unavailable(
          title: invalid ? "linkInvalid" : "chatUnavailable", body: invalid ? "linkInvalidBody" : "tryAgainSoon", values: [:])
        return
      }
      guard inbox.isActive else {
        phase = .unavailable(title: "notTakingChats", body: "notTakingChatsBody", values: ["business": inbox.business])
        return
      }
      // Signed in first, when the app says who this is, so the conversation read next is theirs.
      if let identity {
        do {
          try await client.identify(identity)
        } catch {
          // Said for the app's developer, and otherwise let go: the visitor still gets a working,
          // anonymous chat.
          log.warning("Could not sign this visitor in: \((error as? CnctError)?.message ?? "\(error)", privacy: .public)")
        }
      }
      if let fixture {
        await playFixture(fixture)
        return
      }
      do {
        _ = try await client.resume()
      } catch {
        phase = .unavailable(title: "chatUnavailable", body: "tryAgainSoon", values: [:])
        return
      }
      land()
    }

    /// Where a visitor arrives: their conversation if they have one, the name form if the inbox
    /// asks for one first, and otherwise a composer — the first message starts the conversation.
    private func land() {
      if state.conversation != nil || named || widget.chat.start == .message {
        phase = .chat
      } else {
        phase = .intro
      }
    }

    private func listen() async {
      for await next in client.states {
        guard !Task.isCancelled else { return }
        state = next
        noticeEnded()
      }
    }

    private func listenForEvents() async {
      for await event in client.events {
        switch event {
        case .unauthenticated:
          // Their thirty days ran out. A stranger again: back to where a stranger starts.
          resetConversation()
          land()
        default:
          break
        }
      }
    }

    private func noticeEnded() {
      guard let conversation = state.conversation, !conversation.isLive, !endedFor.contains(conversation.id) else { return }
      endedFor.insert(conversation.id)
      cancelUploads()
      onEvent?(.ended)
    }

    // MARK: - Starting

    /// The name form's button.
    func submitIntro(name: String, phone: String) {
      let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !displayName.isEmpty, !starting else { return }
      starting = true
      introNotice = nil
      Task {
        defer { starting = false }
        do {
          try await client.start(displayName: displayName, phone: phone)
          onEvent?(.started)
          phase = .chat
        } catch {
          introNotice = Notice(key: (error as? CnctError)?.code == .rateLimited ? "tooManyChats" : "genericError")
        }
      }
    }

    /// "Start a new conversation", under one that has ended.
    func startNew() {
      resetConversation()
      if !named && widget.chat.start == .details {
        phase = .intro
        return
      }
      starting = true
      Task {
        defer { starting = false }
        do {
          try await client.start()
          onEvent?(.started)
          phase = .chat
        } catch {
          notice = Notice(key: (error as? CnctError)?.code == .rateLimited ? "tooManyChats" : "genericError")
        }
      }
    }

    private func resetConversation() {
      cancelUploads()
      ratingStage = .faces
      ratingScore = nil
      ratingComment = ""
      ratingNotice = nil
      justNamed = nil
      notice = nil
    }

    /// The conversation exists on the server — started now if this is the first thing they do.
    private func ensureSession() async throws {
      let had = state.conversation?.isLive == true && state.status != .idle
      try await client.ensureSession()
      if !had { onEvent?(.started) }
    }

    // MARK: - Sending

    func send() {
      guard canSend else { return }
      let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      let files = uploads.compactMap { $0.status == .done ? $0.attachment : nil }
      draft = ""
      uploads.removeAll { $0.status != .uploading }
      notice = nil
      deliver(text, files: files, replyId: nil)
    }

    /// A tap on a flow's choice: sent as the visitor's words — the title they tapped — with the
    /// choice's id beside it, so the flow follows the button exactly.
    func choose(_ choice: CnctChatFlow.Choice) {
      guard composerOpen else { return }
      deliver(choice.title, files: [], replyId: choice.id)
    }

    /// A suggestion chip: sent as if they had typed it.
    func suggest(_ text: String) {
      guard composerOpen else { return }
      deliver(text, files: [], replyId: nil)
    }

    func retry(_ message: CnctChatMessage) {
      guard let key = message.clientKey else { return }
      notice = nil
      Task {
        do {
          try await client.retry(key)
        } catch {
          notice = sendNotice(error)
        }
      }
    }

    private func deliver(_ text: String, files: [CnctChatAttachment], replyId: String?) {
      Task {
        do {
          try await ensureSession()
        } catch {
          // Nobody to send it to yet: their words go back in the box rather than vanishing.
          if draft.isEmpty { draft = text }
          notice = Notice(key: (error as? CnctError)?.code == .rateLimited ? "tooManyChats" : "genericError")
          return
        }
        do {
          try await client.send(text, attachments: files, replyId: replyId)
          onEvent?(.sent)
          if !files.isEmpty { onEvent?(.attachmentSent(count: files.count)) }
        } catch {
          notice = sendNotice(error)
        }
      }
    }

    private func sendNotice(_ error: any Error) -> Notice {
      switch (error as? CnctError)?.code {
      case .rateLimited: return Notice(key: "slowDown")
      default: return Notice(key: "genericError")
      }
    }

    // MARK: - Files

    /// Files from a picker: checked, put in the composer, and sent up at once.
    func add(_ picked: [CnctPickedFile]) {
      guard canAttach else { return }
      notice = nil
      for item in picked {
        switch item {
        case .failed(let name):
          notice = Notice(key: "uploadFailed", values: ["name": name])
        case .tooBig(let name):
          notice = Notice(key: "tooBig", values: ["name": name])
        case .file(let file):
          if uploads.count >= CnctChatAttachments.maxFiles {
            notice = Notice(key: "tooMany")
            return
          }
          // HEIC is accepted here because it is converted on the way up; everything else is checked
          // now, so a refusal is a sentence before the upload rather than after it.
          do {
            try CnctChatAttachments.check(
              filename: file.filename, mimeType: file.isHEIC ? "image/jpeg" : file.mimeType, bytes: file.bytes,
              alreadyPicked: uploads.count)
          } catch let error as CnctError {
            notice = Notice(key: error.code == .tooLarge ? "tooBig" : error.code == .tooMany ? "tooMany" : "uploadFailed", values: ["name": file.filename])
            continue
          } catch {
            continue
          }
          let upload = Upload(
            filename: file.filename, mimeType: file.isHEIC ? "image/jpeg" : file.mimeType, bytes: file.bytes,
            preview: file.mimeType.hasPrefix("image/") ? file.data : nil, progress: 0, status: .uploading)
          uploads.append(upload)
          start(upload.id, file)
        }
      }
    }

    private func start(_ id: UUID, _ file: CnctUploadFile) {
      uploadTasks[id] = Task { [weak self] in
        guard let self else { return }
        do {
          try await self.ensureSession()
          let attachment = try await self.client.upload(file) { [weak self] progress in
            Task { @MainActor in self?.progress(id, progress) }
          }
          self.finish(id, attachment)
        } catch is CancellationError {
          return
        } catch {
          self.failUpload(id, file.filename, error)
        }
      }
    }

    private func progress(_ id: UUID, _ value: Double) {
      guard let index = uploads.firstIndex(where: { $0.id == id }), uploads[index].status == .uploading else { return }
      uploads[index].progress = max(uploads[index].progress, value)
    }

    private func finish(_ id: UUID, _ attachment: CnctChatAttachment) {
      uploadTasks[id] = nil
      guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
      uploads[index].status = .done
      uploads[index].progress = 1
      uploads[index].attachment = attachment
    }

    private func failUpload(_ id: UUID, _ name: String, _ error: any Error) {
      uploadTasks[id] = nil
      guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
      uploads[index].status = .failed
      switch (error as? CnctError)?.code {
      case .tooLarge: notice = Notice(key: "tooBig", values: ["name": name])
      case .tooMany: notice = Notice(key: "tooMany")
      case .rateLimited: notice = Notice(key: "tooManyChats")
      default: notice = Notice(key: "uploadFailed", values: ["name": name])
      }
    }

    func remove(_ upload: Upload) {
      uploadTasks.removeValue(forKey: upload.id)?.cancel()
      uploads.removeAll { $0.id == upload.id }
    }

    private func cancelUploads() {
      for task in uploadTasks.values { task.cancel() }
      uploadTasks = [:]
      uploads = []
    }

    /// The picture behind an attachment, fetched with the session token and kept in memory.
    func image(for attachment: CnctChatAttachment) async -> UIImage? {
      if let cached = images.object(forKey: attachment.id as NSString) { return cached }
      guard let data = try? await client.downloadAttachment(attachment.id), let image = UIImage(data: data) else {
        return nil
      }
      images.setObject(image, forKey: attachment.id as NSString)
      return image
    }

    /// Download a file and hand it to the system viewer, under its own name.
    func open(_ attachment: CnctChatAttachment) {
      Task {
        do {
          let data = try await client.downloadAttachment(attachment.id)
          let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnct", isDirectory: true)
            .appendingPathComponent(attachment.id, isDirectory: true)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let name = (attachment.filename?.isEmpty == false ? attachment.filename! : attachment.id)
            .replacingOccurrences(of: "/", with: "-")
          let url = folder.appendingPathComponent(name)
          try data.write(to: url, options: .atomic)
          previewing = Preview(url: url)
        } catch {
          notice = Notice(key: "couldNotLoad", values: ["name": attachment.filename ?? ""])
        }
      }
    }

    // MARK: - Read, end, rate, name

    /// A team reply is on screen and the app is in the foreground: tell the team, once per reply.
    func sawThread() {
      guard phase == .chat else { return }
      Task { await client.read() }
    }

    /// The app came back to the foreground: the socket may have gone while it was away.
    func becameActive() {
      guard phase == .chat, state.isLive else { return }
      Task {
        await client.connect()
        await client.read()
      }
    }

    func end() {
      Task {
        do {
          try await client.end()
        } catch {
          // Ending is the visitor's way out; it should never be the thing that fails.
          notice = Notice(key: "genericError")
        }
      }
    }

    /// A face tapped: saved at once — the face is the answer, and somebody who taps and leaves has
    /// still told the business something — and then a box for more.
    func rate(_ score: Int) {
      guard let conversation = state.conversation, conversation.ratable else { return }
      let before = (ratingStage, ratingScore)
      ratingScore = score
      ratingStage = .comment
      ratingNotice = nil
      Task {
        do {
          try await client.rate(score, conversationId: conversation.id)
          onEvent?(.rated(score: score))
        } catch {
          (ratingStage, ratingScore) = before
          ratingNotice = Notice(key: "genericError")
        }
      }
    }

    /// The box for more: sent as a second answer to the same question.
    func sendComment() {
      guard let score = ratingScore ?? state.conversation?.rating?.score, let conversation = state.conversation else { return }
      let comment = ratingComment.trimmingCharacters(in: .whitespacesAndNewlines)
      ratingStage = .done
      Task {
        do {
          try await client.rate(score, comment: comment, conversationId: conversation.id)
          ratingComment = ""
        } catch {
          ratingStage = .comment
          ratingNotice = Notice(key: "genericError")
        }
      }
    }

    func skipComment() {
      ratingStage = .done
    }

    /// The score on the card: the one just tapped, or the one the conversation already has.
    var shownScore: Int? { ratingScore ?? state.conversation?.rating?.score }

    var shownRatingStage: RatingStage {
      if ratingStage == .faces, state.conversation?.rating != nil { return .done }
      return ratingStage
    }

    /// The name card in the thread.
    func saveDetails() {
      let name = detailsName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !savingDetails else { return }
      savingDetails = true
      Task {
        defer { savingDetails = false }
        do {
          try await client.updateProfile(displayName: name, phone: detailsPhone)
          justNamed = name
          detailsName = ""
          detailsPhone = ""
        } catch {
          notice = Notice(key: "genericError")
        }
      }
    }

    // MARK: - The fixture

    /// The scripted conversation: started, step seven tried and failed, and two files left in the
    /// composer, one of them still on its way up.
    private func playFixture(_ language: CnctChatLanguage) async {
      do {
        try await client.start(displayName: "Layla")
      } catch {
        phase = .unavailable(title: "chatUnavailable", body: "tryAgainSoon", values: [:])
        return
      }
      phase = .chat
      _ = try? await client.send(CnctChatFixture.failedText(language))
      for picked in CnctChatFixture.pickedFiles(language) {
        uploads.append(
          Upload(
            filename: picked.file.filename, mimeType: picked.file.mimeType, bytes: picked.file.bytes,
            preview: picked.file.mimeType.hasPrefix("image/") ? picked.file.data : nil, progress: picked.progress,
            status: picked.attachment == nil ? .uploading : .done, attachment: picked.attachment))
      }
    }

    /// Owns a client the screen made, and lets it go with the screen.
    private final class Owner: Sendable {
      let client: CnctChatClient
      init(_ client: CnctChatClient) { self.client = client }
      deinit {
        let client = self.client
        Task { await client.dispose() }
      }
    }
  }

  /// What a picker handed over.
  enum CnctPickedFile: Sendable {
    case file(CnctUploadFile)
    /// Over 50 MB, known before it was read.
    case tooBig(String)
    /// The system could not hand the file over.
    case failed(String)
  }
#endif
