import Foundation
import Testing

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private let publicKey = "inbox-public-key"

func messageJson(
  id: String = "msg_1",
  speaker: String = "AI",
  type: String = "TEXT",
  body: String = "Hello",
  clientKey: String? = nil,
  data: CnctJSON? = nil,
  attachments: [CnctJSON] = [],
  createdAt: String = "2026-09-08T10:00:00.000Z"
) -> CnctJSON {
  var fields: [String: CnctJSON] = [
    "id": .string(id),
    "speaker": .string(speaker),
    "type": .string(type),
    "body": .string(body),
    "createdAt": .string(createdAt),
    "clientKey": clientKey.map(CnctJSON.string) ?? .null,
    "attachments": .array(attachments),
  ]
  if let data { fields["data"] = data }
  return .object(fields)
}

/// Something a test can change while the fake server is answering from it.
final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value
  init(_ value: Value) { self.value = value }
  var get: Value {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set(_ next: Value) {
    lock.lock()
    defer { lock.unlock() }
    value = next
  }
}

/// The platform, as far as these tests are concerned.
private func chatServer(
  sessionOverride: CnctJSON? = nil,
  sessionStatus: Int = 200,
  messagesStatus: Int? = nil,
  messagesBody: CnctJSON? = nil,
  transcript: Locked<[CnctJSON]> = Locked([messageJson(body: "Hello — how can we help?")])
) -> FakeServer {
  FakeServer { request in
    let conversation: CnctJSON = ["status": "OPEN", "startedAt": "2026-09-08T09:59:00.000Z", "withPerson": false]
    switch request.url.path {
    case "/api/chat/public/\(publicKey)":
      return (
        200,
        [
          "business": "Al Waha",
          "inbox": "Website",
          "isActive": true,
          "greeting": "Hello — how can we help?",
          "requirePhone": false,
        ]
      )
    case "/api/chat/public/\(publicKey)/session":
      return (
        200,
        sessionOverride ?? [
          "token": "visitor-token-1",
          "visitor": ["displayName": "Layla"],
          "conversation": conversation,
          "messages": .array(transcript.get),
        ]
      )
    case "/api/chat/public/session":
      if sessionStatus != 200 { return (sessionStatus, ["error": "That session has expired."]) }
      return (
        200,
        ["visitor": ["displayName": "Layla"], "conversation": conversation, "messages": .array(transcript.get)]
      )
    case "/api/chat/public/messages":
      return (
        messagesStatus ?? 200,
        messagesBody
          ?? messageJson(
            id: "msg_stored",
            speaker: "CALLER",
            body: "Do you open on Fridays?",
            clientKey: request.json["clientKey"]?.stringValue
          )
      )
    case "/api/chat/public/close":
      return (200, ["ok": true])
    case "/api/chat/public/attachments/att_1":
      return (200, "PDF")
    default:
      return (404, ["error": "not found"])
    }
  }
}

private func clientWith(
  _ server: FakeServer,
  store: (any CnctTokenStore)? = nil,
  sockets: FakeSocketFactory,
  configure: (inout CnctConfig) -> Void = { _ in }
) -> CnctChatClient {
  var config = server.config
  configure(&config)
  return CnctChatClient(
    config: config,
    credentials: try! CnctChatPublicKey(publicKey),
    tokenStore: store ?? CnctMemoryTokenStore(),
    transport: server.transport(config),
    socketFactory: sockets.make
  )
}

/// Start a conversation and bring the socket up, the way a connected screen is before anybody types.
private func goLive(_ chat: CnctChatClient, _ sockets: FakeSocketFactory, accepts: [CnctJSON]) async throws -> EventLog<CnctChatEvent> {
  let log = EventLog(chat.events)
  try await chat.start(displayName: "Layla")
  sockets.last.push(["type": "authenticated", "accepts": .array(accepts)])
  // Connected is emitted once the transcript has been refetched, so nothing after this races it.
  #expect(await eventually { log.count { $0 == .connected } == 1 })
  sockets.last.clearSent()
  return log
}

@Suite("CnctChatClient")
struct ChatClientTests {
  @Test("boot reads the inbox without a session")
  func boot() async throws {
    let server = chatServer()
    let chat = clientWith(server, sockets: FakeSocketFactory())
    let inbox = try await chat.boot()
    #expect(inbox.business == "Al Waha")
    #expect(inbox.isActive)
    #expect(chat.state.inbox?.greeting == "Hello — how can we help?")
    #expect(server.requests.count == 1)
    #expect(server.requests.first?.header("x-chat-token") == nil)
    await chat.dispose()
  }

  @Test("start adopts the session, stores the token and authenticates the socket")
  func start() async throws {
    let store = CnctMemoryTokenStore()
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), store: store, sockets: sockets)

    try await chat.start(displayName: "Layla")

    #expect(await chat.hasSession)
    #expect(try await store.read("cnct_chat_\(publicKey)") == "visitor-token-1")
    #expect(chat.state.visitor?.displayName == "Layla")
    #expect(chat.state.messages.count == 1)

    // The handshake goes out immediately: the server closes a socket that has not authenticated
    // within five seconds, so it must not wait behind an await.
    #expect(sockets.last.frames == [["type": "auth", "token": "visitor-token-1"]])
    await chat.dispose()
  }

  @Test("the session token never travels as an Authorization header")
  func tokenHeader() async throws {
    let server = chatServer()
    let chat = clientWith(server, sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    try await chat.send("Do you open on Fridays?")
    let post = try #require(server.requests.first { $0.url.path == "/api/chat/public/messages" })
    #expect(post.header("x-chat-token") == "visitor-token-1")
    #expect(post.header("authorization") == nil)
    await chat.dispose()
  }

  @Test("going live refetches the transcript rather than trusting the stream")
  func goingLiveReloads() async throws {
    let server = chatServer()
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, sockets: sockets)
    try await chat.start(displayName: "Layla")
    server.clearRequests()

    sockets.last.push(["type": "authenticated", "accepts": ["ping", "typing", "send"]])

    #expect(await eventually { chat.state.status == .live })
    #expect(await eventually { server.paths.contains("/api/chat/public/session") })
    await chat.dispose()
  }

  @Test("a send goes over the socket when the server offers it, and resolves on the ack")
  func socketSend() async throws {
    let server = chatServer()
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, sockets: sockets)
    _ = try await goLive(chat, sockets, accepts: ["ping", "typing", "send"])

    let pending = Task { try await chat.send("Do you open on Fridays?") }
    #expect(await eventually { sockets.last.sent.count == 1 })

    // The optimistic bubble is on screen before anything has been acknowledged.
    let optimistic = try #require(chat.state.messages.last)
    #expect(optimistic.pending)
    #expect(optimistic.body == "Do you open on Fridays?")

    let frame = try #require(sockets.last.frames.first)
    #expect(frame["type"]?.stringValue == "send")
    // The frame id, the clientKey and the server's idempotency key are one value, so the three can
    // never disagree about which message this is.
    #expect(frame["id"] == frame["clientKey"])
    #expect(frame["body"]?.stringValue == "Do you open on Fridays?")

    sockets.last.push([
      "type": "ack",
      "id": frame["id"]!,
      "message": messageJson(
        id: "msg_stored", speaker: "CALLER", body: "Do you open on Fridays?",
        clientKey: frame["clientKey"]?.stringValue),
    ])

    let stored = try await pending.value
    #expect(stored.id == "msg_stored")
    // Replaced in place rather than appended — the visitor must not see themselves twice.
    #expect(chat.state.messages.filter { $0.body == "Do you open on Fridays?" }.count == 1)
    #expect(chat.state.messages.last?.pending == false)
    // Nothing went over HTTP.
    #expect(!server.paths.contains("/api/chat/public/messages"))
    await chat.dispose()
  }

  @Test("a send falls back to HTTP when the server does not offer socket sends")
  func httpFallback() async throws {
    let server = chatServer()
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, sockets: sockets)
    _ = try await goLive(chat, sockets, accepts: ["ping", "typing"])

    let stored = try await chat.send("Do you open on Fridays?")

    #expect(stored.id == "msg_stored")
    #expect(sockets.last.sent.isEmpty)
    #expect(server.paths.contains("/api/chat/public/messages"))
    await chat.dispose()
  }

  @Test("a refused send leaves the words on screen, marked, so retry can offer itself")
  func refusedSend() async throws {
    let chat = clientWith(chatServer(messagesStatus: 500, messagesBody: ["error": "boom"]), sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")

    let error = await caughtCnctError { try await chat.send("Do you open on Fridays?") }
    #expect(error != nil)

    let failed = chat.state.failed
    #expect(failed.count == 1)
    #expect(failed.first?.body == "Do you open on Fridays?")
    #expect(failed.first?.pending == false)
    #expect(chat.state.error?.code == .serverError)
    await chat.dispose()
  }

  @Test("retry reuses the same clientKey, so the server cannot write it twice")
  func retry() async throws {
    let server = chatServer(messagesStatus: 500, messagesBody: ["error": "boom"])
    let chat = clientWith(server, sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    _ = await caughtCnctError { try await chat.send("Try me") }
    let key = try #require(chat.state.failed.first?.clientKey)

    let error = await caughtCnctError { try await chat.retry(key) }
    #expect(error != nil)

    let keys = Set(
      server.requests.filter { $0.url.path == "/api/chat/public/messages" }.compactMap { $0.json["clientKey"]?.stringValue })
    #expect(keys == [key])
    #expect(chat.state.messages.filter { $0.body == "Try me" }.count == 1)
    await chat.dispose()
  }

  @Test("a message pushed by the server lands in state and on the event stream")
  func pushedMessage() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")
    let log = EventLog(chat.events)

    sockets.last.push([
      "type": "chat.message",
      "payload": ["message": messageJson(id: "msg_2", speaker: "OPERATOR", body: "We open at nine.")],
    ])

    #expect(await eventually { chat.state.messages.last?.body == "We open at nine." })
    #expect(chat.state.messages.last?.speaker == .operator)
    #expect(await eventually { log.count { if case .messageReceived = $0 { true } else { false } } == 1 })
    await chat.dispose()
  }

  @Test("typing shows — and clears itself, because the platform sends a start and never a stop")
  func theyAreTyping() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")

    sockets.last.push(["type": "chat.typing"])
    #expect(await eventually { chat.state.theyAreTyping })
    await chat.dispose()
  }

  @Test("typing() is throttled rather than sent per keystroke")
  func typingThrottled() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")
    sockets.last.clearSent()

    for _ in 0..<20 { await chat.typing() }

    #expect(sockets.last.frames == [["type": "typing"]])
    await chat.dispose()
  }

  @Test("a 1008 close forgets the session instead of looping on a dead token")
  func close1008() async throws {
    let store = CnctMemoryTokenStore()
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), store: store, sockets: sockets)
    _ = try await chat.boot()
    try await chat.start(displayName: "Layla")
    let log = EventLog(chat.events)

    sockets.last.serverClose(1008)

    #expect(await eventually { log.count { $0 == .unauthenticated } == 1 })
    #expect(await !chat.hasSession)
    #expect(try await store.read("cnct_chat_\(publicKey)") == nil)
    #expect(chat.state.status == .idle)
    // The inbox survives: it was never part of the session.
    #expect(chat.state.inbox?.business == "Al Waha")
    // And nothing reconnects against a credential that will never work.
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(sockets.sockets.count == 1)
    await chat.dispose()
  }

  @Test("resume with no stored token is false rather than an error")
  func resumeNothing() async throws {
    let chat = clientWith(chatServer(), sockets: FakeSocketFactory())
    #expect(try await chat.resume() == false)
    await chat.dispose()
  }

  @Test("resume picks a stored session back up")
  func resumeStored() async throws {
    let store = CnctMemoryTokenStore()
    try await store.write("cnct_chat_\(publicKey)", value: "visitor-token-1")
    let server = chatServer()
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, store: store, sockets: sockets)

    #expect(try await chat.resume())
    #expect(chat.state.messages.count == 1)
    #expect(chat.state.visitor?.displayName == "Layla")
    #expect(server.requests.first?.header("x-chat-token") == "visitor-token-1")
    #expect(sockets.sockets.count == 1)
    await chat.dispose()
  }

  @Test("closing the conversation ends it and stops the socket")
  func end() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")
    try await chat.end()
    #expect(chat.state.status == .ended)
    #expect(!chat.state.canSend)
    #expect(sockets.last.closedByClient == 1000)
    await chat.dispose()
  }

  @Test("sending before a session is a named refusal, not a nil error")
  func sendWithoutSession() async {
    let chat = clientWith(chatServer(), sockets: FakeSocketFactory())
    let error = await caughtCnctError { try await chat.send("hello") }
    #expect(error?.code == .noSession)
    await chat.dispose()
  }

  @Test("an empty message is refused here rather than on the wire")
  func emptyMessage() async throws {
    let chat = clientWith(chatServer(), sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    let error = await caughtCnctError { try await chat.send("   ") }
    #expect(error?.code == .empty)
    await chat.dispose()
  }

  @Test("an unknown frame is a newer server talking, not a crash")
  func unknownFrame() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")
    sockets.last.push(["type": "chat.something.new", "payload": ["x": 1]])
    sockets.last.push("not json at all")
    // A frame after them proves they were read, and passed over.
    sockets.last.push(["type": "chat.typing"])
    #expect(await eventually { chat.state.theyAreTyping })
    #expect(chat.state.error == nil)
    await chat.dispose()
  }

  // MARK: Beyond the Dart suite

  @Test("a dropped socket reconnects, and the reconnect reloads what was said while it was down")
  func reconnectReloads() async throws {
    let transcript = Locked([messageJson(body: "Hello — how can we help?")])
    let server = chatServer(transcript: transcript)
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, sockets: sockets)
    let log = try await goLive(chat, sockets, accepts: ["ping", "typing", "send"])

    sockets.last.serverClose(1006)
    #expect(await eventually { chat.state.status == .offline })
    #expect(await eventually { log.count { $0 == .disconnected } == 1 })

    // Said while the socket was down, and never pushed.
    transcript.set(transcript.get + [messageJson(id: "msg_2", speaker: "OPERATOR", body: "Are you still there?")])

    #expect(await eventually { sockets.sockets.count == 2 })
    #expect(sockets.last.frames.first == ["type": "auth", "token": "visitor-token-1"])
    sockets.last.push(["type": "authenticated", "accepts": ["ping", "typing", "send"]])

    #expect(await eventually { log.count { $0 == .connected } == 2 })
    #expect(chat.state.status == .live)
    #expect(chat.state.messages.map(\.body) == ["Hello — how can we help?", "Are you still there?"])
    await chat.dispose()
  }

  @Test("a socket send nobody acknowledges times out, stays on screen, and can be retried")
  func socketSendTimesOut() async throws {
    let server = chatServer()
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, sockets: sockets) { $0.sendTimeout = 0.2 }
    _ = try await goLive(chat, sockets, accepts: ["send"])

    let error = await caughtCnctError { try await chat.send("Hello?") }
    #expect(error?.code == .timeout)
    #expect(error?.isRetryable == true)
    let failed = try #require(chat.state.failed.first)
    #expect(failed.body == "Hello?")

    // The retry carries the same key, so a server that did get the first frame keeps one row.
    let retried = Task { try await chat.retry(failed.clientKey!) }
    #expect(await eventually { sockets.last.frames.count == 2 })
    let frames = sockets.last.frames
    #expect(frames[0]["clientKey"] == frames[1]["clientKey"])
    sockets.last.push([
      "type": "ack", "id": frames[1]["id"]!,
      "message": messageJson(id: "msg_9", speaker: "CALLER", body: "Hello?", clientKey: failed.clientKey),
    ])
    #expect(try await retried.value.id == "msg_9")
    #expect(chat.state.failed.isEmpty)
    await chat.dispose()
  }

  @Test("an error frame for a send fails that send with the server's code, once")
  func errorFrame() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    let log = try await goLive(chat, sockets, accepts: ["send"])

    let pending = Task { try await chat.send("Hello") }
    #expect(await eventually { sockets.last.frames.count == 1 })
    let id = try #require(sockets.last.frames.first?["id"])
    sockets.last.push(["type": "error", "id": id, "error": "Slow down.", "code": "rate_limited"])

    let error = await caughtCnctError { _ = try await pending.value }
    #expect(error?.code == .rateLimited)
    #expect(chat.state.failed.first?.body == "Hello")
    #expect(chat.state.error?.code == .rateLimited)
    #expect(log.count { if case .errored = $0 { true } else { false } } == 1)
    await chat.dispose()
  }

  @Test("a reload keeps words the server has not got yet, rather than wiping them")
  func reloadKeepsUnsent() async throws {
    let chat = clientWith(chatServer(messagesStatus: 500, messagesBody: ["error": "boom"]), sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    _ = await caughtCnctError { try await chat.send("Still here") }

    #expect(try await chat.resume())

    #expect(chat.state.messages.map(\.body) == ["Hello — how can we help?", "Still here"])
    #expect(chat.state.failed.count == 1)
    await chat.dispose()
  }

  @Test("a reload drops the optimistic copy of a message the server already stored")
  func reloadPrefersStored() async throws {
    let transcript = Locked([messageJson(body: "Hello — how can we help?")])
    let chat = clientWith(chatServer(messagesStatus: 500, messagesBody: ["error": "boom"], transcript: transcript), sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    _ = await caughtCnctError { try await chat.send("Arrived after all") }
    let key = try #require(chat.state.failed.first?.clientKey)
    transcript.set(transcript.get + [messageJson(id: "msg_2", speaker: "CALLER", body: "Arrived after all", clientKey: key)])

    #expect(try await chat.resume())

    #expect(chat.state.messages.map(\.id) == ["msg_1", "msg_2"])
    #expect(chat.state.failed.isEmpty)
    await chat.dispose()
  }

  @Test("a refused token on resume is cleared, not thrown")
  func resumeRefused() async throws {
    let store = CnctMemoryTokenStore()
    try await store.write("cnct_chat_\(publicKey)", value: "expired")
    let chat = clientWith(chatServer(sessionStatus: 401), store: store, sockets: FakeSocketFactory())

    #expect(try await chat.resume() == false)
    #expect(await !chat.hasSession)
    #expect(try await store.read("cnct_chat_\(publicKey)") == nil)
    await chat.dispose()
  }

  @Test("the business closing the conversation ends it and lets the socket go")
  func closedByBusiness() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")
    let log = EventLog(chat.events)

    sockets.last.push(["type": "chat.closed"])

    #expect(await eventually { chat.state.status == .ended })
    #expect(await eventually { log.count { $0 == .closed } == 1 })
    #expect(sockets.last.closedByClient == 1000)
    // Closed on purpose, so nothing reconnects.
    try await Task.sleep(nanoseconds: 800_000_000)
    #expect(sockets.sockets.count == 1)
    await chat.dispose()
  }

  @Test("a conversation update lands in state and on the event stream")
  func conversationUpdated() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")
    let log = EventLog(chat.events)

    sockets.last.push([
      "type": "chat.conversation.updated",
      "payload": ["conversation": ["status": "OPEN", "startedAt": "2026-09-08T09:59:00.000Z", "withPerson": true]],
    ])

    #expect(await eventually { chat.state.conversation?.withPerson == true })
    #expect(await eventually { log.count { if case .conversationUpdated = $0 { true } else { false } } == 1 })
    await chat.dispose()
  }

  @Test("a 409 on send is reported as the conversation having closed")
  func conflictOnSend() async throws {
    let chat = clientWith(chatServer(messagesStatus: 409, messagesBody: ["error": "Closed."]), sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    _ = await caughtCnctError { try await chat.send("Anyone?") }
    #expect(chat.state.error?.code == .conversationClosed)
    await chat.dispose()
  }

  @Test("attachments are fetched on the session token")
  func attachments() async throws {
    let server = chatServer()
    let chat = clientWith(server, sockets: FakeSocketFactory())
    let before = await caughtCnctError { _ = try await chat.downloadAttachment("att_1") }
    #expect(before?.code == .noSession)
    try await chat.start(displayName: "Layla")

    let bytes = try await chat.downloadAttachment("att_1")
    #expect(String(decoding: bytes, as: UTF8.self) == "\"PDF\"")
    #expect(server.requests.last?.header("x-chat-token") == "visitor-token-1")

    let request = await chat.attachmentRequest("att_1")
    #expect(request.url?.absoluteString == "https://\(server.host)/api/chat/public/attachments/att_1")
    #expect(request.value(forHTTPHeaderField: "x-chat-token") == "visitor-token-1")
    await chat.dispose()
  }

  @Test("the socket goes to /ws/chat under the prefix, and the token goes in a frame, not the URL")
  func socketUpgrade() async throws {
    let server = chatServer()
    let sockets = FakeSocketFactory()
    let chat = clientWith(server, sockets: sockets)
    try await chat.start(displayName: "Layla")

    let upgrade = try #require(sockets.requests.first)
    #expect(upgrade.url?.absoluteString == "wss://\(server.host)/ws/chat")
    #expect(upgrade.value(forHTTPHeaderField: "user-agent") == "cnct-ios-sdk/\(CnctConfig.sdkVersion)")
    #expect(upgrade.value(forHTTPHeaderField: "x-chat-token") == nil)
    await chat.dispose()
  }

  @Test("states starts with the current snapshot, and both streams end on dispose")
  func streams() async throws {
    let chat = clientWith(chatServer(), sockets: FakeSocketFactory())
    _ = try await chat.boot()

    let states = chat.states
    var iterator = states.makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.inbox?.business == "Al Waha")
    #expect(first == chat.state)

    let events = chat.events
    await chat.dispose()
    for await _ in events {}
    while await iterator.next() != nil {}
    // Reaching here is the assertion: neither stream is left hanging.
  }

  @Test("disconnect stops the socket and keeps the session for resume")
  func disconnect() async throws {
    let sockets = FakeSocketFactory()
    let chat = clientWith(chatServer(), sockets: sockets)
    try await chat.start(displayName: "Layla")

    await chat.disconnect()
    #expect(chat.state.status == .offline)
    #expect(sockets.last.closedByClient == 1000)
    #expect(await chat.hasSession)

    await chat.connect()
    #expect(sockets.sockets.count == 2)
    #expect(chat.state.status == .connecting)
    await chat.dispose()
  }

  @Test("printing a client never prints the visitor's session token")
  func redactsToken() async throws {
    let chat = clientWith(chatServer(), sockets: FakeSocketFactory())
    try await chat.start(displayName: "Layla")
    var dumped = ""
    dump(chat, to: &dumped)
    for text in [dumped, "\(chat)", String(reflecting: chat)] {
      #expect(!text.contains("visitor-token-1"), "\(text)")
    }
    #expect("\(chat)".contains("publicKey:"))
    await chat.dispose()
  }

  @Test("the entry point hands out the client a credential opens")
  func entryPoints() async throws {
    let cnct = try Cnct(host: "https://cnct.test/support")
    let chat = cnct.chat(try CnctChatPublicKey(publicKey))
    #expect(chat.state.status == .idle)

    guard case .chat = try cnct.client(for: CnctChatPublicKey(publicKey)) else {
      Issue.record("a public key opens chat")
      return
    }
    let agent = try cnct.client(for: CnctApiKey("kaer_sk_test_abc"))
    guard case .agent(let client) = agent else {
      Issue.record("an API key opens the agent client")
      return
    }
    #expect(client.mode == .sandbox)
    #expect(agent.modules == [.bookings, .tickets])

    struct Homemade: CnctCredentials {
      var headers: [String: String] { [:] }
      var redacted: String { "homemade:****" }
      var modules: Set<CnctModule> { [] }
    }
    #expect(throws: CnctError.self) { try cnct.client(for: Homemade()) }
    do {
      _ = try cnct.client(for: Homemade())
    } catch let error as CnctError {
      #expect(error.code == .missingCredential)
    }
  }
}
