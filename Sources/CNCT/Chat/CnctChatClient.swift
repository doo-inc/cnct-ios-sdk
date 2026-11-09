import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Live chat with a CNCT inbox, as a visitor.
///
/// **Headless on purpose.** There is no view in here, not one, and that is the reason to reach for
/// this rather than an embedded web view: a business building their own app has a design system
/// already, and shipping them a bubble to restyle answers a question they did not ask. This ships
/// state and events; the interface is yours.
///
/// Three properties are load-bearing and you get them without having to know:
///
/// **A reconnect reloads.** The platform's fan-out replays nothing after a drop — deliberately — so
/// this client refetches the whole transcript on every reconnect rather than splicing a gap it
/// cannot measure. A UI that renders ``state`` is always rendering the truth.
///
/// **A send is idempotent.** Every message carries a `clientKey` that is unique per conversation on
/// the server, so a frame replayed across a reconnect returns the row it already wrote instead of
/// writing a second one. That is what makes ``send(_:clientKey:)`` safe to reject on a timeout and
/// ``retry(_:)`` safe to call.
///
/// **It degrades rather than breaks.** The server announces what it accepts on the handshake. Sends
/// go over the socket where that is offered and fall back to HTTP where it is not — which covers
/// both an older server and the ordinary case of the socket being between connections.
///
/// It is an actor, so it is safe to call from anywhere. ``state``, ``states`` and ``events`` need no
/// `await`, so a view can read and subscribe synchronously.
///
/// ```swift
/// let chat = CnctChatClient(
///   config: CnctConfig(), // https://app.doo.ooo
///   credentials: try CnctChatPublicKey("the-inbox-public-key")
/// )
/// Task { for await state in chat.states { render(state) } }
/// let inbox = try await chat.boot()
/// if inbox.isActive {
///   try await chat.start(displayName: "Layla")
///   try await chat.send("Do you open on Fridays?")
/// }
/// ```
public actor CnctChatClient {
  private let config: CnctConfig
  private let publicKey: String
  /// The public key's redacted form. The client describes itself with this and the state, never
  /// with its stored properties — one of them is the visitor's session token.
  private let redacted: String
  private let store: any CnctTokenStore
  private let storageKey: String
  private let transport: CnctTransport
  private let socketFactory: CnctSocketFactory

  private let stateBroadcast = CnctBroadcast(replaying: CnctChatState())
  private let eventBroadcast = CnctBroadcast<CnctChatEvent>()

  /// Frame id → the sends waiting for its `ack`. More than one when a retry is pressed while the
  /// first attempt is still in flight; one ack answers both.
  private var awaiting: [String: [CheckedContinuation<CnctChatMessage, any Error>]] = [:]
  private var awaitingTimers: [String: Task<Void, Never>] = [:]

  private var current = CnctChatState()
  private var token: String?
  private var tokenLoaded = false
  private var socket: (any CnctSocket)?
  /// Bumped whenever a socket is opened or torn down, so a frame from a socket this client has
  /// already let go of is recognised and ignored.
  private var socketGeneration = 0
  private var readerTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private var typingClearTask: Task<Void, Never>?
  private var lastTypingSentAt: Date?
  private var reconnectAttempt = 0
  private var socketSendSupported = false
  private var closedByUs = false
  private var disposed = false
  /// The start in flight, shared by everything that needs a session at once — a message and a file
  /// picked in the same moment start one conversation, not two.
  private var starting: Task<Void, any Error>?
  /// The `replyId` each unsent message carries, so a retry sends the same choice again.
  private var replyIds: [String: String] = [:]
  /// Per conversation, the newest reply already reported as read — so each is reported once.
  private var reportedRead: [String: String] = [:]
  /// Attachment bytes by id, fetched or sent from this device. A thread is redrawn whenever anything
  /// moves, and without this every photo in it would be downloaded again each time.
  private var attachmentCache: [String: Data] = [:]
  private var attachmentCacheOrder: [String] = []
  private var attachmentCacheBytes = 0
  private static let attachmentCacheLimit = 64 * 1024 * 1024

  /// - Parameters:
  ///   - tokenStore: Where the visitor's session token is kept between launches. The default keeps
  ///     it in memory, which means a returning customer arrives as a stranger — pass a
  ///     `CnctKeychainTokenStore` in an app.
  ///   - storageKey: The key the token is stored under. Defaults to one per inbox.
  ///   - transport: Defaults to one on `URLSession.shared` for `config`.
  ///   - socketFactory: Defaults to ``CnctURLSessionSocket``. Swappable so tests can drive a fake one
  ///     without a server.
  public init(
    config: CnctConfig,
    credentials: CnctChatPublicKey,
    tokenStore: (any CnctTokenStore)? = nil,
    storageKey: String? = nil,
    transport: CnctTransport? = nil,
    socketFactory: CnctSocketFactory? = nil
  ) {
    self.config = config
    self.publicKey = credentials.publicKey
    self.redacted = credentials.redacted
    self.store = tokenStore ?? CnctMemoryTokenStore()
    self.storageKey = storageKey ?? "cnct_chat_\(credentials.publicKey)"
    self.transport = transport ?? CnctTransport(config: config)
    self.socketFactory = socketFactory ?? { request in CnctURLSessionSocket(request: request) }
  }

  deinit {
    readerTask?.cancel()
    reconnectTask?.cancel()
    keepAliveTask?.cancel()
    typingClearTask?.cancel()
    for timer in awaitingTimers.values { timer.cancel() }
    socket?.close(code: 1000, reason: "Client closed")
    stateBroadcast.finish()
    eventBroadcast.finish()
  }

  /// The current snapshot. Never half-applied.
  public nonisolated var state: CnctChatState { stateBroadcast.latest ?? CnctChatState() }

  /// Every state change, starting with the current snapshot. Each access is a new stream of its
  /// own: subscribe from as many views as you like. Ends after ``dispose()``.
  ///
  /// The current snapshot comes first because an `AsyncStream` has nothing like a Flutter
  /// `StreamBuilder`'s `initialData`, and reading ``state`` and then subscribing would leave a gap
  /// between the two for a change to fall into.
  public nonisolated var states: AsyncStream<CnctChatState> { stateBroadcast.stream() }

  /// Things that happened, for the parts of a UI that act rather than render. Only what happens
  /// after you subscribe; each access is a new stream of its own. Ends after ``dispose()``.
  public nonisolated var events: AsyncStream<CnctChatEvent> { eventBroadcast.stream() }

  /// True when a session token is held — the visitor has been here before and ``resume()`` will
  /// work.
  public var hasSession: Bool { token != nil }

  // MARK: - The front door

  /// What this inbox says before anybody has typed: the greeting, whether it is switched on, and
  /// whether it wants a phone number first.
  ///
  /// Readable without a session, and worth calling before you draw anything — an inbox with
  /// ``CnctChatInbox/isActive`` false will refuse a session, and saying so up front is better than
  /// letting somebody type into a composer that cannot deliver.
  @discardableResult
  public func boot() async throws -> CnctChatInbox {
    let json = try await transport.get("/api/chat/public/\(CnctConfig.pathSegment(publicKey))")
    let inbox = CnctChatInbox(json: .object(try json.requireObject()))
    var next = current
    next.inbox = inbox
    next.error = nil
    patch(next)
    return inbox
  }

  /// Begin, or come back as the same person.
  ///
  /// Sending a stored token reuses that visitor rather than minting a stranger, so somebody who
  /// chatted last week is still attached to the contact record the business has for them.
  ///
  /// Pass `phone` whenever you know it. A visitor is anonymous until they volunteer a number: if
  /// your app has already signed this person in, passing the number you hold is the difference
  /// between a thread that joins their history and one that starts a second record for them.
  public func start(displayName: String? = nil, phone: String? = nil) async throws {
    try await loadToken()
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let number = phone?.trimmingCharacters(in: .whitespacesAndNewlines)
    let body: [String: CnctJSON?] = [
      "displayName": name.flatMap { $0.isEmpty ? nil : .string($0) },
      "phone": number.flatMap { $0.isEmpty ? nil : .string($0) },
      // The visitor's own clock, so the team's "back at nine" and the business's hours are said in
      // it rather than in the server's.
      "timezone": .string(Self.timeZone),
    ]
    let json = try await transport.post(
      "/api/chat/public/\(CnctConfig.pathSegment(publicKey))/session",
      body: .object(body.compacted()),
      headers: tokenHeader()
    )
    await adoptSession(try json.requireObject())
    connect()
  }

  /// Pick up where a restart left off. Answers false when there is no session to pick up — which is
  /// not an error, just a first-time visitor.
  ///
  /// A refused token is cleared here rather than thrown: the visitor's thirty days ran out or the
  /// business closed the conversation, and neither is something an app can act on beyond going back
  /// to its pre-chat screen.
  @discardableResult
  public func resume() async throws -> Bool {
    try await loadToken()
    guard token != nil else { return false }
    do {
      let json = try await transport.get(
        "/api/chat/public/session", query: ["timezone": Self.timeZone], headers: tokenHeader())
      await adoptSession(try json.requireObject())
      if current.conversation?.status == .closed {
        var next = current
        next.status = .ended
        patch(next)
      } else {
        connect()
      }
      return true
    } catch let error as CnctError where error.isUnauthenticated {
      await forgetSession()
      return false
    }
  }

  /// Make sure there is a conversation to write in, starting one if there is not.
  ///
  /// For an inbox that lets visitors type first: the conversation starts with their first message
  /// or their first file, whichever comes first, and the two share one start rather than racing to
  /// make two. A no-op while a live conversation is open.
  public func ensureSession(displayName: String? = nil, phone: String? = nil) async throws {
    if token != nil, let conversation = current.conversation, conversation.isLive,
      current.status != .idle, current.status != .ended
    {
      return
    }
    if let starting { return try await starting.value }
    let task = Task { try await self.start(displayName: displayName, phone: phone) }
    starting = task
    defer { starting = nil }
    try await task.value
  }

  /// Sign the visitor in as one of your app's users.
  ///
  /// The current session token goes with the call, so a chat this person started anonymously before
  /// signing in moves across to them. The token that comes back replaces it, in the store as well.
  /// If a conversation was open it is picked up again under the new token.
  ///
  /// Fails with ``CnctErrorCode/conflict`` (`409`) when the inbox has no identity secret set up, and
  /// ``CnctErrorCode/unauthenticated`` (`401`) when `userHash` did not verify. Neither touches the
  /// session this client already had, so an app can carry on with an anonymous chat.
  @discardableResult
  public func identify(_ identity: CnctChatIdentity) async throws -> CnctChatVisitor {
    try await loadToken()
    let json = try await transport.post(
      "/api/chat/public/\(CnctConfig.pathSegment(publicKey))/identify",
      body: identity.json,
      headers: tokenHeader()
    )
    let data = try json.requireObject()
    guard let token = data["token"]?.stringValue, !token.isEmpty else {
      throw CnctError("The server signed the visitor in without a session token.", code: .badResponse)
    }
    let visitor = data["visitor"].flatMap { $0.objectValue == nil ? nil : CnctChatVisitor(json: $0) }
    let hadConversation = current.conversation != nil || socket != nil

    teardownSocket()
    reportedRead = [:]
    self.token = token
    tokenLoaded = true
    do {
      try await store.write(storageKey, value: token)
    } catch {
      config.logger?(.warning, "Could not store the chat session token", error)
    }
    var next = CnctChatState(inbox: current.inbox, visitor: visitor ?? current.visitor)
    next.status = .idle
    patch(next)
    if hadConversation { _ = try? await resume() }
    return visitor ?? current.visitor ?? CnctChatVisitor(displayName: "")
  }

  // MARK: - Saying something

  /// Say something — words, files, or both. Answers once the server has it.
  ///
  /// The optimistic bubble goes into ``state`` immediately and is replaced in place when the real
  /// row arrives — matched on `clientKey`, which is also the frame id and also the server's
  /// idempotency key, so the three can never disagree about which message this is.
  ///
  /// On failure the bubble stays, marked ``CnctChatMessage/failed``, and the error is thrown. Do not
  /// clear it: the words somebody typed vanishing is worse than a retry button.
  ///
  /// - Parameters:
  ///   - attachments: Files already uploaded with ``upload(_:progress:)``. Up to ten.
  ///   - replyId: The ``CnctChatFlow/Choice/id`` of a flow choice the visitor tapped, with the
  ///     choice's title as `body`. The flow then follows the button exactly rather than reading the
  ///     title as typing.
  @discardableResult
  public func send(
    _ body: String = "",
    attachments: [CnctChatAttachment] = [],
    replyId: String? = nil,
    clientKey: String? = nil
  ) async throws -> CnctChatMessage {
    try await loadToken()
    guard token != nil else {
      throw CnctError("Start a conversation first.", code: .noSession)
    }
    let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !attachments.isEmpty else {
      throw CnctError("Nothing to send.", code: .empty)
    }
    if text.utf16.count > Self.maxBody {
      throw CnctError("A message can be up to \(Self.maxBody) characters.", code: .tooLarge)
    }
    if attachments.count > CnctChatAttachments.maxFiles {
      throw CnctError("Up to \(CnctChatAttachments.maxFiles) files at a time.", code: .tooMany)
    }
    let key = clientKey ?? Self.uid()
    if let replyId { replyIds[key] = replyId }

    var next = current
    if let existing = next.messages.firstIndex(where: { $0.clientKey == key }) {
      next.messages[existing].pending = true
      next.messages[existing].failed = false
    } else {
      next.messages.append(.optimistic(clientKey: key, body: text, attachments: attachments))
    }
    patch(next)

    // One body for both paths, because they are one endpoint behind two doors.
    var payload: [String: CnctJSON] = ["body": .string(text), "clientKey": .string(key)]
    if !attachments.isEmpty { payload["attachmentIds"] = .array(attachments.map { .string($0.id) }) }
    if let replyId = replyIds[key] { payload["replyId"] = .string(replyId) }

    do {
      let message: CnctChatMessage
      if socketSendSupported, socket != nil {
        message = try await sendOverSocket(key, payload)
      } else {
        // The fallback, and a real path rather than a formality: it runs against a server that
        // predates socket sends, and whenever the socket happens to be between connections. Same
        // endpoint, same idempotency key.
        let json = try await transport.post("/api/chat/public/messages", body: .object(payload), headers: tokenHeader())
        message = CnctChatMessage(json: .object(try json.requireObject()))
        absorb(message)
      }
      replyIds[key] = nil
      return message
    } catch let error as CnctError {
      markFailed(key)
      fail(
        error.status == 409
          ? CnctError(error.message, code: .conversationClosed, status: error.status, details: error.details)
          : error
      )
      throw error
    } catch {
      // A cancelled task, most often — a view that went away mid-send. The words still stay, with a
      // way back.
      markFailed(key)
      throw error
    }
  }

  /// Answer a flow's question by tapping one of its choices: the choice's title goes as the
  /// visitor's words and its id as `replyId`, so the flow follows the button exactly rather than
  /// reading the title as typing. The server keeps the id only if this conversation was offered it.
  @discardableResult
  public func choose(_ choice: CnctChatFlow.Choice) async throws -> CnctChatMessage {
    try await send(choice.title, replyId: choice.id)
  }

  /// Re-send a message that failed. The same `clientKey`, so the server cannot write it twice.
  @discardableResult
  public func retry(_ clientKey: String) async throws -> CnctChatMessage {
    guard let message = current.messages.first(where: { $0.clientKey == clientKey }) else {
      throw CnctError("No message with that key.", code: .notFound)
    }
    return try await send(message.body, attachments: message.attachments, clientKey: clientKey)
  }

  /// Tell the other side somebody is typing. Throttled to one frame every three seconds here, and
  /// again on the server — call it on every keystroke without thinking about it.
  public func typing() {
    let now = Date()
    if let last = lastTypingSentAt, now.timeIntervalSince(last) < 3 { return }
    guard socket != nil else { return }
    lastTypingSentAt = now
    say(["type": "typing"])
  }

  /// The visitor ends it. Their own conversation, so there is nothing to identify.
  public func end() async throws {
    try await loadToken()
    guard token != nil else { return }
    _ = try await transport.post("/api/chat/public/close", headers: tokenHeader())
    closedByUs = true
    closeConversation()
    teardownSocket()
    await refreshConversation()
  }

  // MARK: - After the conversation

  /// Tell the team the visitor has their reply on screen — the ticks in the business's console.
  ///
  /// Call it whenever a reply is visible and the app is in the foreground; it reports each reply
  /// once. The newest reply from the team or the assistant is remembered once reported, and the next
  /// report waits for a newer one. A report that fails is forgotten, so the next call retries it.
  /// Answers whether anything was sent.
  @discardableResult
  public func read() async -> Bool {
    guard token != nil, let conversation = current.conversation, !conversation.id.isEmpty,
      let reply = current.messages.last(where: \.isReply)
    else { return false }
    if reportedRead[conversation.id] == reply.id { return false }
    reportedRead[conversation.id] = reply.id
    do {
      try await read(conversationId: conversation.id)
      return true
    } catch {
      if reportedRead[conversation.id] == reply.id { reportedRead[conversation.id] = nil }
      return false
    }
  }

  /// The raw call behind ``read()``, for any of this visitor's conversations: `204`, nothing to
  /// read back.
  public func read(conversationId: String) async throws {
    try await loadToken()
    guard token != nil else { throw CnctError("Start a conversation first.", code: .noSession) }
    _ = try await transport.post(
      "/api/chat/public/conversations/\(CnctConfig.pathSegment(conversationId))/read",
      headers: tokenHeader()
    )
  }

  /// Rate a closed conversation, one to five, worst to best — and, in a second call with the same
  /// score, add a comment.
  ///
  /// The face is the answer, so it is worth sending the moment it is tapped: somebody who taps and
  /// closes the app has still told the business something. Answers the conversation as the server
  /// now has it. ``CnctErrorCode/conflict`` once it can no longer be rated.
  ///
  /// - Parameter conversationId: Defaults to the conversation in ``state``.
  @discardableResult
  public func rate(_ score: Int, comment: String? = nil, conversationId: String? = nil) async throws
    -> CnctChatConversation
  {
    try await loadToken()
    guard token != nil else { throw CnctError("Start a conversation first.", code: .noSession) }
    guard (1...5).contains(score) else {
      throw CnctError("A rating is from 1 to 5.", code: .invalid)
    }
    guard let id = conversationId ?? current.conversation?.id, !id.isEmpty else {
      throw CnctError("There is no conversation to rate.", code: .notFound)
    }
    var body: [String: CnctJSON] = ["score": .int(score)]
    if let comment { body["comment"] = .string(comment.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let json = try await transport.post(
      "/api/chat/public/conversations/\(CnctConfig.pathSegment(id))/rating",
      body: .object(body),
      headers: tokenHeader()
    )
    guard let raw = json["conversation"], raw.objectValue != nil else {
      throw CnctError("The server answered a rating without the conversation.", code: .badResponse)
    }
    var rated = CnctChatConversation(json: raw)
    if current.conversation?.id == id, let known = current.conversation {
      // The answer is the server's view of the conversation; laid over what is known, so a field it
      // leaves out of this answer is not wiped.
      rated = known.patched(with: raw)
      var next = current
      next.conversation = rated
      patch(next)
    }
    return rated
  }

  /// Give the visitor a name — what a UI asks for in the thread when somebody typed before saying
  /// who they are. Answers the visitor as the server now has them.
  @discardableResult
  public func updateProfile(displayName: String, phone: String? = nil) async throws -> CnctChatVisitor {
    try await loadToken()
    guard token != nil else { throw CnctError("Start a conversation first.", code: .noSession) }
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw CnctError("A name cannot be empty.", code: .invalid) }
    var body: [String: CnctJSON] = ["displayName": .string(name)]
    if let number = phone?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty {
      body["phone"] = .string(number)
    }
    let json = try await transport.post("/api/chat/public/profile", body: .object(body), headers: tokenHeader())
    guard let raw = json["visitor"], raw.objectValue != nil else {
      throw CnctError("The server answered without the visitor.", code: .badResponse)
    }
    let visitor = CnctChatVisitor(json: raw)
    var next = current
    next.visitor = visitor
    patch(next)
    return visitor
  }

  // MARK: - Past conversations

  /// The visitor's conversations, newest first, up to fifty, each with its last message in
  /// ``CnctChatConversation/preview``. Empty for somebody who has not been here before.
  public func conversations() async throws -> [CnctChatConversation] {
    try await loadToken()
    guard token != nil else { return [] }
    let json = try await transport.get("/api/chat/public/conversations", headers: tokenHeader())
    adoptVisitor(json["visitor"])
    return json.objects("conversations").map(CnctChatConversation.init(json:))
  }

  /// One of the visitor's conversations, with its messages, oldest first. Any of theirs — an old
  /// one included — but never anybody else's: a stranger's id is a `404`.
  public func conversation(_ id: String) async throws -> CnctChatTranscript {
    try await loadToken()
    guard token != nil else { throw CnctError("Start a conversation first.", code: .noSession) }
    let json = try await transport.get(
      "/api/chat/public/conversations/\(CnctConfig.pathSegment(id))", headers: tokenHeader())
    adoptVisitor(json["visitor"])
    guard let raw = json["conversation"], raw.objectValue != nil else {
      throw CnctError("The server answered without the conversation.", code: .badResponse)
    }
    return CnctChatTranscript(
      conversation: CnctChatConversation(json: raw),
      messages: json.objects("messages").map(CnctChatMessage.init(json:))
    )
  }

  // MARK: - Files

  /// The bytes of a file an operator sent. Scoped to this visitor's own conversation by the server;
  /// an id from anywhere else is a 404 rather than a refusal, so a stranger learns nothing.
  ///
  /// Any of this visitor's conversations, so a past chat's files open too. Kept in memory by id, so
  /// asking again — a thread redrawn, a photo opened full screen — is free.
  public func downloadAttachment(_ attachmentId: String) async throws -> Data {
    if let cached = attachmentCache[attachmentId] { return cached }
    try await loadToken()
    guard token != nil else {
      throw CnctError("Start a conversation first.", code: .noSession)
    }
    let data = try await transport.bytes(
      "/api/chat/public/attachments/\(CnctConfig.pathSegment(attachmentId))",
      headers: tokenHeader()
    )
    remember(data, for: attachmentId)
    return data
  }

  /// The bytes of an attachment already on this device — downloaded before, or sent from it — or
  /// nil. Never touches the network.
  public func cachedAttachment(_ attachmentId: String) -> Data? {
    attachmentCache[attachmentId]
  }

  /// Upload one file, for a message to carry with ``send(_:attachments:replyId:clientKey:)``.
  ///
  /// **Photos are made ready first** — HEIC converted to JPEG, anything over 2560 px scaled down —
  /// by ``CnctChatAttachments/prepare(_:)``, and then **checked**, so a file the server would
  /// refuse is refused here before a byte of it is sent: ``CnctErrorCode/tooLarge`` over 50 MB,
  /// ``CnctErrorCode/unsupportedType`` for a kind of file the chat does not take. One file per call,
  /// as the server takes them; upload several side by side.
  ///
  /// `progress` hears 0 to 1 as the file goes, on a background queue. The server's refusals arrive
  /// as ``CnctErrorCode/attachmentsDisabled`` (the inbox or the deployment takes no files),
  /// ``CnctErrorCode/conversationClosed``, ``CnctErrorCode/tooLarge`` and
  /// ``CnctErrorCode/unsupportedType``, with the server's sentence as the message.
  public func upload(_ file: CnctUploadFile, progress: (@Sendable (Double) -> Void)? = nil) async throws
    -> CnctChatAttachment
  {
    try await loadToken()
    guard token != nil else {
      throw CnctError("Start a conversation first.", code: .noSession)
    }
    // Off the actor: redrawing a 48-megapixel photo takes long enough that a chat waiting behind it
    // would notice.
    let prepared = await Task.detached(priority: .userInitiated) { CnctChatAttachments.prepare(file) }.value
    try CnctChatAttachments.check(prepared)
    let multipart = CnctMultipart(field: "file", file: prepared)
    progress?(0)
    let json: CnctJSON
    do {
      json = try await transport.upload(
        "/api/chat/public/attachments",
        body: multipart.body,
        contentType: multipart.contentType,
        headers: tokenHeader(),
        progress: progress
      )
    } catch let error as CnctError {
      throw Self.uploadRefusal(error)
    }
    guard let raw = json["attachment"], let id = raw["id"]?.stringValue, !id.isEmpty else {
      throw CnctError("The server took the file without saying what it stored.", code: .badResponse)
    }
    // The server's copy, when it comes back on the message, is drawn from the bytes on this device.
    remember(prepared.data, for: id)
    return CnctChatAttachment(json: raw)
  }

  /// The request that fetches an attachment, with the headers it needs.
  ///
  /// What a custom image loader wants — `AsyncImage` cannot carry the session header on its own, so
  /// this hands back a request that will not 401 in a view somebody spent an afternoon debugging.
  public func attachmentRequest(_ attachmentId: String) -> URLRequest {
    var request = URLRequest(
      url: config.resolve("/api/chat/public/attachments/\(CnctConfig.pathSegment(attachmentId))"))
    for (name, value) in config.headers.merging(tokenHeader(), uniquingKeysWith: { _, ours in ours }) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    return request
  }

  // MARK: - The socket

  /// Open the socket. Called for you by ``start(displayName:phone:)`` and ``resume()``; public for
  /// an app that disconnects while backgrounded and wants to come back.
  public func connect() {
    guard !disposed, let token, socket == nil else { return }
    closedByUs = false
    var next = current
    next.status = current.status == .live ? .live : .connecting
    patch(next)

    let opened: any CnctSocket
    do {
      opened = try socketFactory(socketRequest())
    } catch {
      config.logger?(.warning, "Could not open the chat socket", error)
      scheduleReconnect()
      return
    }
    socketGeneration += 1
    let generation = socketGeneration
    socket = opened

    readerTask = Task { [weak self] in
      for await event in opened.events {
        guard let self else { return }
        await self.receive(event, generation: generation)
      }
      // A socket whose stream ended without saying how is a socket that closed.
      await self?.receive(.closed(code: nil), generation: generation)
    }

    // The handshake. Five seconds to authenticate or the server closes the connection, so this goes
    // out the moment the socket exists rather than after any await.
    say(["type": "auth", "token": .string(token)])
    startKeepAlive()
  }

  /// Close the socket and stop reconnecting. The session survives — ``resume()`` picks it up again.
  public func disconnect() {
    closedByUs = true
    teardownSocket()
    if current.status != .ended {
      var next = current
      next.status = .offline
      patch(next)
    }
  }

  /// Release everything: the socket, the timers, and the ``states`` and ``events`` streams, which
  /// end. The client is unusable afterwards.
  public func dispose() {
    disposed = true
    disconnect()
    stateBroadcast.finish()
    eventBroadcast.finish()
  }

  // MARK: - Internals

  private func receive(_ event: CnctSocketEvent, generation: Int) {
    guard generation == socketGeneration, socket != nil else { return }
    switch event {
    case .message(let text): handleFrame(text)
    case .closed(let code): handleSocketClosed(code)
    }
  }

  private func handleFrame(_ raw: String) {
    guard
      let decoded = try? JSONDecoder().decode(CnctJSON.self, from: Data(raw.utf8)),
      case .object = decoded
    else { return }
    let frame = decoded

    switch frame["type"]?.text ?? "" {
    case "authenticated":
      reconnectAttempt = 0
      socketSendSupported = (frame["accepts"]?.arrayValue ?? []).contains { $0.text == "send" }
      var next = current
      next.status = .live
      next.error = nil
      patch(next)
      // **The reload that makes this client safe to render directly.** Pub/sub replays nothing, so
      // anything said while the socket was down is missing and there is no way to know how much.
      // Refetching is the only answer that cannot be subtly wrong.
      let generation = socketGeneration
      Task { [weak self] in await self?.reloadAfterConnecting(generation) }

    case "pong":
      return

    case "ack":
      let id = frame["id"]?.stringValue
      let message = frame["message"]?.objectValue.map { CnctChatMessage(json: .object($0)) }
      if let message { absorb(message) }
      if let id {
        let waiting = awaiting.removeValue(forKey: id) ?? []
        awaitingTimers.removeValue(forKey: id)?.cancel()
        for continuation in waiting {
          if let message {
            continuation.resume(returning: message)
          } else {
            continuation.resume(
              throwing: CnctError("The server acknowledged without a message.", code: .badResponse))
          }
        }
      }

    case "error":
      let id = frame["id"]?.stringValue
      let error = CnctError(
        frame["error"]?.stringValue ?? "That did not work.",
        code: CnctErrorCode(rawValue: frame["code"]?.stringValue ?? CnctErrorCode.requestFailed.rawValue)
      )
      let waiting = id.flatMap { awaiting.removeValue(forKey: $0) } ?? []
      if let id {
        awaitingTimers.removeValue(forKey: id)?.cancel()
        // Leave the optimistic bubble in place but mark it, so a UI can offer a retry rather than
        // making the words the person typed disappear.
        markFailed(id)
      }
      if waiting.isEmpty {
        fail(error)
      } else {
        // The send that was waiting reports this itself, once, as it throws.
        for continuation in waiting { continuation.resume(throwing: error) }
      }

    case "chat.message":
      if let payload = frame["payload"]?["message"], payload.objectValue != nil {
        let message = CnctChatMessage(json: payload)
        absorb(message)
        emit(.messageReceived(message))
      }

    case "chat.typing":
      var next = current
      next.theyAreTyping = true
      patch(next)
      typingClearTask?.cancel()
      typingClearTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        await self?.clearTheirTyping()
      }
      emit(.typingReceived)

    case "chat.message.updated":
      // Edited, deleted, or a file that finished storing: the same row, changed. Replaced where it
      // stands rather than appended, so the thread does not grow a second copy.
      if let payload = frame["payload"]?["message"], payload.objectValue != nil {
        let message = CnctChatMessage(json: payload)
        if let at = current.messages.firstIndex(where: { $0.id == message.id && !message.id.isEmpty }) {
          var next = current
          next.messages[at] = message
          patch(next)
          emit(.messageUpdated(message))
        }
      }

    case "chat.read":
      if let at = CnctDates.parse(frame["payload"]?["at"]?.stringValue), var conversation = current.conversation {
        conversation.seenAt = max(conversation.seenAt ?? at, at)
        var next = current
        next.conversation = conversation
        patch(next)
        emit(.read(at))
      }

    case "chat.conversation.updated":
      // Two shapes in the wild: the change under `conversation`, and the changed fields as the
      // payload itself. Either way only what it carries moves.
      guard let payload = frame["payload"], payload.objectValue != nil else { return }
      let change = payload["conversation"].flatMap { $0.objectValue == nil ? nil : $0 } ?? payload
      let conversation = current.conversation?.patched(with: change) ?? CnctChatConversation(json: change)
      var next = current
      next.conversation = conversation
      patch(next)
      emit(.conversationUpdated(conversation))

    case "chat.closed":
      closedByUs = true
      closeConversation()
      emit(.closed)
      teardownSocket()
      // The server's view of it — above all whether it can be rated — a moment later.
      Task { [weak self] in await self?.refreshConversation() }

    default:
      // An unknown frame is a newer server talking, not an error. Ignored on purpose.
      return
    }
  }

  /// Refetch, then say so — unless the refetch found the token dead, or the socket went while it
  /// ran, in which case there is no longer a connection to announce.
  private func reloadAfterConnecting(_ generation: Int) async {
    _ = try? await resume()
    if generation == socketGeneration, socket != nil { emit(.connected) }
  }

  private func clearTheirTyping() {
    guard !disposed else { return }
    var next = current
    next.theyAreTyping = false
    patch(next)
  }

  private func handleSocketClosed(_ code: Int?) {
    stopKeepAlive()
    readerTask = nil
    socket = nil
    socketGeneration += 1
    socketSendSupported = false
    failAllAwaiting(CnctError("The connection dropped before that was sent.", code: .offline))

    // 1008 is what the server closes with when the token did not resolve. Reconnecting would loop
    // against a credential that will never work, so this is the one close that ends things rather
    // than backing off.
    if code == 1008 {
      Task { [weak self] in
        await self?.forgetSession()
        await self?.emit(.unauthenticated)
      }
      return
    }
    if current.status != .ended {
      var next = current
      next.status = .offline
      patch(next)
    }
    emit(.disconnected)
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard !closedByUs, !disposed, reconnectTask == nil else { return }
    // Exponential with a ceiling and jitter — a thousand phones recovering from the same blip
    // should not all arrive in the same millisecond.
    let base = min(30_000, 500 << min(reconnectAttempt, 16))
    let wait = Double(base) * (0.7 + Double.random(in: 0..<0.6))
    reconnectAttempt += 1
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000))
      guard !Task.isCancelled else { return }
      await self?.reconnectNow()
    }
  }

  private func reconnectNow() {
    reconnectTask = nil
    connect()
  }

  private func startKeepAlive() {
    stopKeepAlive()
    // Quiet connections get closed by proxies long before they get closed by anybody's intent.
    keepAliveTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 25_000_000_000)
        guard !Task.isCancelled, let self else { return }
        await self.say(["type": "ping"])
      }
    }
  }

  private func stopKeepAlive() {
    keepAliveTask?.cancel()
    keepAliveTask = nil
  }

  private func teardownSocket() {
    reconnectTask?.cancel()
    reconnectTask = nil
    typingClearTask?.cancel()
    typingClearTask = nil
    stopKeepAlive()
    failAllAwaiting(CnctError("Disconnected.", code: .offline))
    readerTask?.cancel()
    readerTask = nil
    socketGeneration += 1
    let closing = socket
    socket = nil
    socketSendSupported = false
    closing?.close(code: 1000, reason: "Client closed")
  }

  private func sendOverSocket(_ key: String, _ payload: [String: CnctJSON]) async throws -> CnctChatMessage {
    try await withCheckedThrowingContinuation { continuation in
      awaiting[key, default: []].append(continuation)
      awaitingTimers.removeValue(forKey: key)?.cancel()
      let timeout = config.sendTimeout
      awaitingTimers[key] = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        guard !Task.isCancelled else { return }
        await self?.sendTimedOut(key)
      }
      var frame = payload
      frame["type"] = "send"
      frame["id"] = .string(key)
      say(.object(frame))
    }
  }

  private func sendTimedOut(_ key: String) {
    awaitingTimers[key] = nil
    guard let waiting = awaiting.removeValue(forKey: key) else { return }
    markFailed(key)
    // Safe to say "retry": the clientKey means a second attempt cannot double-post.
    for continuation in waiting {
      continuation.resume(throwing: CnctError("That message has not been acknowledged yet.", code: .timeout))
    }
  }

  private func say(_ frame: CnctJSON) {
    guard let socket else { return }
    do {
      socket.send(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self))
    } catch {
      config.logger?(.warning, "Could not write to the chat socket", error)
    }
  }

  private func failAllAwaiting(_ error: CnctError) {
    for timer in awaitingTimers.values { timer.cancel() }
    awaitingTimers = [:]
    let waiting = awaiting
    awaiting = [:]
    for continuation in waiting.values.joined() { continuation.resume(throwing: error) }
  }

  /// Merge a server message in, replacing the optimistic one it answers.
  private func absorb(_ message: CnctChatMessage) {
    var next = current
    let at =
      message.clientKey != nil
      ? next.messages.firstIndex { $0.clientKey == message.clientKey }
      : next.messages.firstIndex { $0.id == message.id }
    if let at {
      next.messages[at] = message
    } else if !next.messages.contains(where: { $0.id == message.id }) {
      next.messages.append(message)
    }
    // Stable, so two messages written in the same millisecond keep the order they arrived in.
    next.messages.sort { $0.createdAt < $1.createdAt }
    next.error = nil
    patch(next)
  }

  private func markFailed(_ clientKey: String) {
    var next = current
    for index in next.messages.indices where next.messages[index].clientKey == clientKey {
      next.messages[index].pending = false
      next.messages[index].failed = true
    }
    patch(next)
  }

  private func adoptSession(_ data: [String: CnctJSON]) async {
    var next = current
    if let visitor = data["visitor"], visitor.objectValue != nil {
      next.visitor = CnctChatVisitor(json: visitor)
    }
    if let conversation = data["conversation"], conversation.objectValue != nil {
      next.conversation = CnctChatConversation(json: conversation)
    }
    if let messages = data["messages"]?.arrayValue {
      let transcript = messages.filter { $0.objectValue != nil }.map(CnctChatMessage.init(json:))
      // The transcript is the truth, with one exception: words the visitor typed that the server
      // has not got yet. A reload that lands mid-send must not take an optimistic or failed bubble
      // with it — its retry button is the only way back for what somebody typed.
      let stored = Set(transcript.compactMap(\.clientKey))
      let unsent = current.messages.filter { message in
        guard let key = message.clientKey, message.pending || message.failed else { return false }
        return !stored.contains(key)
      }
      next.messages = transcript + unsent
    }
    next.error = nil
    patch(next)

    if let token = data["token"]?.stringValue, !token.isEmpty {
      self.token = token
      tokenLoaded = true
      do {
        try await store.write(storageKey, value: token)
      } catch {
        // A store that fails to keep the token costs the visitor their thread on the next launch,
        // not this conversation — so it is not a reason to fail the call it happened during.
        config.logger?(.warning, "Could not store the chat session token", error)
      }
    }
  }

  /// The conversation is over: say so in state now, before the server has been asked anything.
  private func closeConversation() {
    var next = current
    next.status = .ended
    if var conversation = next.conversation {
      conversation.status = .closed
      conversation.closedAt = conversation.closedAt ?? Date()
      next.conversation = conversation
    }
    patch(next)
  }

  /// Read the conversation in state again — after it closed, to learn whether it can be rated. A
  /// failure leaves state as it is: the thread is already right, and the rating waits for the next
  /// load.
  private func refreshConversation() async {
    guard token != nil, let id = current.conversation?.id, !id.isEmpty,
      let transcript = try? await conversation(id), current.conversation?.id == id
    else { return }
    var next = current
    next.conversation = transcript.conversation
    let stored = Set(transcript.messages.compactMap(\.clientKey))
    next.messages = transcript.messages + current.messages.filter { message in
      guard let key = message.clientKey, message.pending || message.failed else { return false }
      return !stored.contains(key)
    }
    patch(next)
  }

  private func adoptVisitor(_ json: CnctJSON?) {
    guard let json, json.objectValue != nil else { return }
    var next = current
    next.visitor = CnctChatVisitor(json: json)
    patch(next)
  }

  private func remember(_ data: Data, for id: String) {
    if attachmentCache[id] == nil {
      attachmentCacheOrder.append(id)
      attachmentCacheBytes += data.count
    }
    attachmentCache[id] = data
    // Oldest out first, past a budget, so a long thread full of photos cannot grow without end.
    while attachmentCacheBytes > Self.attachmentCacheLimit, attachmentCacheOrder.count > 1 {
      let oldest = attachmentCacheOrder.removeFirst()
      attachmentCacheBytes -= attachmentCache.removeValue(forKey: oldest)?.count ?? 0
    }
  }

  /// The attachments endpoint's refusals, named for what they mean there. A code the server sent
  /// itself is kept as it is.
  static func uploadRefusal(_ error: CnctError) -> CnctError {
    guard let status = error.status, error.details?["code"]?.stringValue == nil else { return error }
    let code: CnctErrorCode
    switch status {
    case 403, 503: code = .attachmentsDisabled
    case 409: code = .conversationClosed
    case 413: code = .tooLarge
    case 415, 422: code = .unsupportedType
    default: return error
    }
    return CnctError(error.message, code: code, status: status, details: error.details)
  }

  private func forgetSession() async {
    reportedRead = [:]
    token = nil
    tokenLoaded = true
    teardownSocket()
    patch(CnctChatState(inbox: current.inbox))
    // A store that fails to forget is not a reason to fail the call it happened during.
    try? await store.clear(storageKey)
  }

  private func loadToken() async throws {
    if tokenLoaded { return }
    let stored = try await store.read(storageKey)
    // Another call may have adopted a session while this one waited on the store.
    if tokenLoaded { return }
    token = stored
    tokenLoaded = true
  }

  /// Never `Authorization`. The platform's rate limiter keys on `ip + authorization`, so a visitor
  /// who sent that header would be minting themselves a fresh budget by inventing one.
  private func tokenHeader() -> [String: String] {
    token.map { ["x-chat-token": $0] } ?? [:]
  }

  /// The upgrade request: `/ws/chat` under the socket origin, with the configured headers — a proxy
  /// that wants its header on every request wants it on this one too.
  private func socketRequest() -> URLRequest {
    var components = URLComponents(url: config.socketBaseURL, resolvingAgainstBaseURL: false)!
    components.percentEncodedPath += "/ws/chat"
    var request = URLRequest(url: components.url!)
    request.setValue(config.userAgent, forHTTPHeaderField: "user-agent")
    for (name, value) in config.headers { request.setValue(value, forHTTPHeaderField: name) }
    return request
  }

  private func patch(_ next: CnctChatState) {
    current = next
    stateBroadcast.yield(next)
  }

  private func fail(_ error: CnctError) {
    var next = current
    next.error = error
    patch(next)
    emit(.errored(error))
  }

  private func emit(_ event: CnctChatEvent) {
    eventBroadcast.yield(event)
  }

  /// The longest body a message can carry, in UTF-16 code units — what the server counts.
  static let maxBody = 4000

  /// The device's IANA time zone, sent with every session call.
  static var timeZone: String { TimeZone.current.identifier }

  private static func uid() -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let stamp = String(UInt64(Date().timeIntervalSince1970 * 1_000_000), radix: 36)
    let noise = String((0..<10).map { _ in alphabet.randomElement()! })
    return "k\(stamp)\(noise)"
  }
}

// MARK: - Printing without the session token

extension CnctChatClient: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public nonisolated var description: String { "CnctChatClient(\(redacted), \(state.status.rawValue))" }
  public nonisolated var debugDescription: String { description }
  public nonisolated var customMirror: Mirror {
    Mirror(self, children: ["credentials": redacted, "state": state])
  }
}
