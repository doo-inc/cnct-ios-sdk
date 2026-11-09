import Foundation
import Testing

@testable import CNCT

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Start a conversation and bring the socket up with the frames a 1.0 server accepts.
private func live(
  _ chat: CnctChatClient,
  _ sockets: FakeSocketFactory,
  accepts: [CnctJSON] = ["ping", "typing"]
) async throws -> EventLog<CnctChatEvent> {
  let log = EventLog(chat.events)
  try await chat.start(displayName: "Layla")
  sockets.last.push(["type": "authenticated", "accepts": .array(accepts)])
  #expect(await eventually { log.count { $0 == .connected } == 1 })
  sockets.last.clearSent()
  return log
}

@Suite("The inbox: widget, team, availability")
struct InboxConfigurationTests {
  @Test("boot reads the widget, the team and the availability")
  func bootReadsEverything() async throws {
    let api = VisitorServer()
    api.on("GET", "/api/chat/public/\(visitorKey)") { _ in
      (
        200,
        [
          "business": "Demo Café", "inbox": "App", "isActive": true, "greeting": "Hello.", "requirePhone": true,
          "widget": [
            "brand": [
              "color": "#D7262E", "appearance": "dark", "businessName": "Demo", "avatarUrl": "https://cdn.test/logo.png",
              "language": "ar", "showBranding": false,
            ],
            "chat": [
              "allowAttachments": false, "allowEmoji": false, "allowEndConversation": true, "start": "message",
              "askForRating": false,
            ],
            "launcher": ["side": "left"],
          ],
          "team": [["kind": "person", "name": "Sara", "avatar": "fox-clay"], ["kind": "person", "name": "Omar"]],
          "availability": ["open": false, "opensAt": "2026-09-09T05:00:00.000Z", "assistant": true, "replyMinutes": 3],
        ]
      )
    }
    let chat = api.client()
    let inbox = try await chat.boot()

    #expect(inbox.widget.brand.color == "#D7262E")
    #expect(inbox.widget.brand.appearance == .dark)
    #expect(inbox.widget.brand.avatarURL == URL(string: "https://cdn.test/logo.png"))
    #expect(inbox.widget.brand.language == .ar)
    #expect(inbox.widget.brand.showBranding == false)
    #expect(inbox.widget.chat.allowAttachments == false)
    #expect(inbox.widget.chat.allowEndConversation)
    #expect(inbox.widget.chat.start == .message)
    #expect(inbox.widget.chat.askForRating == false)
    // The sections this SDK does not model are still there for an app that wants them.
    #expect(inbox.widget.raw["launcher"]?["side"]?.stringValue == "left")
    #expect(inbox.team.map(\.name) == ["Sara", "Omar"])
    #expect(inbox.team.first?.kind == .person)
    #expect(inbox.team.first?.avatar == "fox-clay")
    #expect(inbox.availability?.open == false)
    #expect(inbox.availability?.assistant == true)
    #expect(inbox.availabilityLine == .back(at: utc(2026, 9, 9, 5, 0), assistantNow: true))
    #expect(chat.state.inbox == inbox)
    await chat.dispose()
  }

  @Test("a widget is merged over the defaults section by section, as the server merges")
  func widgetDefaults() {
    let none = CnctChatWidget(json: .null)
    #expect(none == .defaults)
    #expect(none.brand.color == "#b52d93")
    #expect(none.brand.appearance == .light)
    #expect(none.brand.language == .auto)
    #expect(none.brand.showBranding)
    #expect(none.chat.allowAttachments)
    #expect(none.chat.allowEndConversation == false)
    #expect(none.chat.start == .details)
    #expect(none.chat.askForRating)

    // One field given: only that one moves.
    let partial = CnctChatWidget(json: ["brand": ["appearance": "auto"], "chat": ["allowAttachments": false]])
    #expect(partial.brand.appearance == .auto)
    #expect(partial.brand.color == "#b52d93")
    #expect(partial.chat.allowAttachments == false)
    #expect(partial.chat.askForRating)
  }

  @Test("a colour or a logo that cannot be drawn is replaced, not passed on")
  func badValues() {
    let widget = CnctChatWidget(json: [
      "brand": ["color": "red", "avatarUrl": "javascript:alert(1)", "appearance": "sepia", "language": "fr"]
    ])
    #expect(widget.brand.color == "#b52d93")
    #expect(widget.brand.avatarURL == nil)
    #expect(widget.brand.appearance == .light)
    #expect(widget.brand.language == .auto)
  }

  @Test(
    "the availability sentence is the hosted page's, chosen honestly",
    arguments: [
      (CnctChatAvailability(open: true, replyMinutes: 0.5), CnctAvailabilityLine.replyUnder1),
      (CnctChatAvailability(open: true, assistant: true, replyMinutes: 0.5), .assistantNow),
      (CnctChatAvailability(open: true, replyMinutes: 5), .replyFew),
      (CnctChatAvailability(open: true, replyMinutes: 20), .reply20),
      (CnctChatAvailability(open: true, replyMinutes: 45), .replyHour),
      (CnctChatAvailability(open: true, replyMinutes: 240), .replyHours),
      (CnctChatAvailability(open: true, replyMinutes: 900), .replyDay),
      (CnctChatAvailability(open: nil, replyMinutes: nil), .replyUnknown),
      (CnctChatAvailability(open: nil, assistant: true), .assistantNow),
      // Closed with no time to be back at: nothing is promised beyond the measured speed.
      (CnctChatAvailability(open: false, opensAt: nil, replyMinutes: 3), .replyFew),
    ]
  )
  func availabilityLine(availability: CnctChatAvailability, line: CnctAvailabilityLine) {
    #expect(availability.line == line)
  }

  @Test("no availability from the server promises nothing")
  func noAvailability() {
    #expect(CnctChatAvailability.line(for: nil) == .replyUnknown)
    #expect(CnctChatInbox(json: ["business": "Demo"]).availability == nil)
  }
}

@Suite("The message model")
struct MessageModelTests {
  @Test("a message carries its sender, flow, suggestions and quote")
  func fullMessage() throws {
    let message = CnctChatMessage(json: [
      "id": "m1", "speaker": "AI", "type": "TEXT", "body": "1. Book a visit\n2. Talk to a person",
      "createdAt": "2026-09-08T10:00:00.000Z", "clientKey": nil,
      "sender": ["kind": "ai", "name": "Assistant", "mascot": "drop", "colour": "teal"],
      "flow": [
        "text": "Would you like to book a visit?", "layout": "buttons",
        "choices": [["id": "c1", "title": "Book a visit"], ["id": "c2", "title": "Talk to a person"], ["title": "no id"]],
        "footer": "Reply any time", "expects": nil,
        "media": ["kind": "image", "url": "https://cdn.test/menu.jpg"],
      ],
      "suggestions": ["Yes", "  ", "No", "Maybe", "Later"],
      "replyTo": ["messageId": "m0", "mine": true, "excerpt": "Do you open on Fridays?"],
    ])
    #expect(message.sender == CnctChatSender(kind: .ai, name: "Assistant", mascot: "drop", colour: "teal"))
    let flow = try #require(message.flow)
    #expect(flow.drawsAsFlow)
    #expect(flow.choices.map(\.id) == ["c1", "c2"])
    #expect(flow.footer == "Reply any time")
    #expect(flow.media?.url == URL(string: "https://cdn.test/menu.jpg"))
    #expect(flow.choicesAsRows == false)
    #expect(message.words == "Would you like to book a visit?")
    // Blanks dropped, three at most.
    #expect(message.suggestions == ["Yes", "No", "Maybe"])
    #expect(message.replyTo == CnctChatQuote(messageId: "m0", mine: true, excerpt: "Do you open on Fridays?"))
  }

  @Test("the visitor's own and the system's lines have no sender, and an unknown type reads as its body")
  func noSender() {
    let mine = CnctChatMessage(json: messageJson(speaker: "CALLER", type: "POLL", body: "Pick one: A or B"))
    #expect(mine.sender == nil)
    #expect(mine.type == .other)
    #expect(mine.rawType == "POLL")
    #expect(mine.words == "Pick one: A or B")
  }

  @Test("a quote of a file says what kind it was")
  func fileQuote() {
    let quote = CnctChatQuote(json: ["messageId": nil, "mine": false, "excerpt": "", "attachmentKind": "IMAGE"])
    #expect(quote?.excerpt == nil)
    #expect(quote?.attachmentKind == .image)
  }

  @Test("a flow stored before the server sent its words keeps its body")
  func flowWithoutText() {
    let message = CnctChatMessage(json: [
      "id": "m1", "speaker": "AI", "body": "1. Yes 2. No", "createdAt": "2026-09-08T10:00:00Z",
      "flow": ["text": nil, "choices": [["id": "y", "title": "Yes"]]],
    ])
    #expect(message.flow?.drawsAsFlow == false)
    #expect(message.words == "1. Yes 2. No")
  }

  @Test("choices with a description, or a list, are rows")
  func rows() {
    let described = CnctChatFlow(text: "Pick", choices: [.init(id: "a", title: "A", description: "The first")])
    #expect(described.choicesAsRows)
    #expect(CnctChatFlow(text: "Pick", layout: .list, choices: [.init(id: "a", title: "A")]).choicesAsRows)
  }

  @Test("a conversation carries who has it, how far they have read, and its rating")
  func conversation() {
    let conversation = CnctChatConversation(
      json: conversationJson(status: "CLOSED", ratable: true, rating: ["score": 4, "comment": "Quick"], seenAt: "2026-09-08T10:05:00Z"))
    #expect(conversation.id == "conv_1")
    #expect(conversation.status == .closed)
    #expect(conversation.closedAt == utc(2026, 9, 8, 10, 30))
    #expect(conversation.assignee?.name == "Sara")
    #expect(conversation.seenAt == utc(2026, 9, 8, 10, 5))
    #expect(conversation.ratable)
    #expect(conversation.rating == CnctChatRating(score: 4, comment: "Quick"))
    #expect(conversation.isLive == false)
    // A score out of range is no rating at all.
    #expect(CnctChatConversation(json: ["rating": ["score": 9]]).rating == nil)
  }

  @Test("a visitor says whether they have given a name, and whether the app signed them in")
  func visitor() {
    let visitor = CnctChatVisitor(json: ["displayName": "Visitor 12", "anonymous": true, "identified": false])
    #expect(visitor.anonymous)
    #expect(visitor.identified == false)
  }
}

@Suite("What the state offers a UI")
struct StateHelpersTests {
  private func ai(_ id: String, flow: CnctJSON = .null, suggestions: [CnctJSON] = []) -> CnctChatMessage {
    CnctChatMessage(json: [
      "id": .string(id), "speaker": "AI", "body": "…", "createdAt": "2026-09-08T10:00:00Z",
      "flow": flow, "suggestions": .array(suggestions),
    ])
  }

  private let choices: CnctJSON = ["text": "Book?", "choices": [["id": "c1", "title": "Book a visit"]]]

  @Test("a flow waits for an answer only while it is the last thing said")
  func awaitingFlow() {
    var state = CnctChatState(status: .live, messages: [ai("m1", flow: choices)])
    #expect(state.awaitingFlow?.id == "m1")

    state.messages.append(CnctChatMessage(json: messageJson(id: "m2", speaker: "CALLER", body: "Book a visit")))
    #expect(state.awaitingFlow == nil)

    // A question that asks for an answer rather than offering choices still waits for one.
    let asks = CnctChatState(status: .live, messages: [ai("m3", flow: ["text": "Your email?", "expects": "email"])])
    #expect(asks.awaitingFlow?.flow?.expects == .email)

    // An ended conversation is waiting for nothing.
    let ended = CnctChatState(status: .ended, messages: [ai("m1", flow: choices)])
    #expect(ended.awaitingFlow == nil)
  }

  @Test("suggestions are read back over the assistant's trailing messages, and never beside choices")
  func suggestions() {
    let picture = CnctChatMessage(json: [
      "id": "m2", "speaker": "AI", "body": "", "createdAt": "2026-09-08T10:00:01Z",
      "attachments": [["id": "a1", "kind": "IMAGE", "mimeType": "image/png"]],
    ])
    let state = CnctChatState(status: .live, messages: [ai("m1", suggestions: ["Yes", "No"]), picture])
    #expect(state.offeredSuggestions == ["Yes", "No"])

    var answered = state
    answered.messages.append(CnctChatMessage(json: messageJson(id: "m3", speaker: "CALLER", body: "Yes")))
    #expect(answered.offeredSuggestions.isEmpty)

    let both = CnctChatState(status: .live, messages: [ai("m1", flow: choices, suggestions: ["Yes"])])
    #expect(both.offeredSuggestions.isEmpty)
  }

  @Test("Seen goes under the visitor's last words once the team has read up to them")
  func seen() {
    let mine = CnctChatMessage(json: messageJson(id: "m1", speaker: "CALLER", body: "Hi", createdAt: "2026-09-08T10:00:00Z"))
    let unread = CnctChatConversation(status: .open, startedAt: Date(), withPerson: true)
    let read = CnctChatConversation(status: .open, startedAt: Date(), withPerson: true, seenAt: utc(2026, 9, 8, 10, 1))
    #expect(CnctChatState(status: .live, conversation: unread, messages: [mine]).seenMessageId == nil)
    #expect(CnctChatState(status: .live, conversation: read, messages: [mine]).seenMessageId == "m1")
    let reply = CnctChatMessage(json: messageJson(id: "m2", speaker: "OPERATOR", body: "Hello"))
    #expect(CnctChatState(status: .live, conversation: read, messages: [mine, reply]).seenMessageId == nil)
  }
}

@Suite("The visitor API")
struct VisitorAPITests {
  @Test("a session start and a resume both carry the device's time zone")
  func timezone() async throws {
    let api = VisitorServer()
    let store = CnctMemoryTokenStore()
    let chat = api.client(store: store)
    try await chat.start(displayName: "Layla")
    let start = try #require(api.requests("POST", "/api/chat/public/\(visitorKey)/session").first)
    #expect(start.json["timezone"]?.stringValue == TimeZone.current.identifier)
    #expect(start.json["displayName"]?.stringValue == "Layla")

    let again = api.client(store: store)
    #expect(try await again.resume())
    let resume = try #require(api.requests("GET", "/api/chat/public/session").first)
    let query = URLComponents(url: resume.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.first { $0.name == "timezone" }?.value == TimeZone.current.identifier)
    await chat.dispose()
    await again.dispose()
  }

  @Test("a send carries its files as attachmentIds, and the optimistic bubble shows them at once")
  func sendWithFiles() async throws {
    let api = VisitorServer()
    let chat = api.client()
    try await chat.start(displayName: "Layla")
    let photo = CnctChatAttachment(id: "att_1", kind: .image, mimeType: "image/jpeg", filename: "photo.jpg", bytes: 1_200_000)
    let pdf = CnctChatAttachment(id: "att_2", kind: .document, mimeType: "application/pdf", filename: "invoice.pdf", bytes: 220_000)

    let observed = Locked<[CnctChatAttachment]>([])
    // Subscribed before the send, so the optimistic snapshot cannot slip past.
    let states = chat.states
    let watching = Task {
      for await state in states {
        if let bubble = state.messages.last, bubble.pending {
          observed.set(bubble.attachments)
          return
        }
      }
    }
    try await chat.send("Here you are", attachments: [photo, pdf])
    _ = await watching.value

    let post = try #require(api.requests("POST", "/api/chat/public/messages").first)
    #expect(post.json["attachmentIds"] == ["att_1", "att_2"])
    #expect(post.json["body"]?.stringValue == "Here you are")
    #expect(post.json["replyId"] == nil)
    #expect(observed.get.map(\.id) == ["att_1", "att_2"])
    await chat.dispose()
  }

  @Test("files alone are a message; neither words nor files is not")
  func filesAlone() async throws {
    let api = VisitorServer()
    let chat = api.client()
    try await chat.start(displayName: "Layla")
    let photo = CnctChatAttachment(id: "att_1", kind: .image, mimeType: "image/jpeg")
    try await chat.send(attachments: [photo])
    #expect(api.requests("POST", "/api/chat/public/messages").first?.json["body"]?.stringValue == "")

    let empty = await caughtCnctError { try await chat.send("   ") }
    #expect(empty?.code == .empty)
    let many = Array(repeating: photo, count: 11)
    #expect(await caughtCnctError { try await chat.send("x", attachments: many) }?.code == .tooMany)
    #expect(await caughtCnctError { try await chat.send(String(repeating: "a", count: 4001)) }?.code == .tooLarge)
    await chat.dispose()
  }

  @Test("tapping a flow choice sends its title with its replyId, and a retry sends both again")
  func replyId() async throws {
    let api = VisitorServer()
    let failing = Locked(true)
    api.on("POST", "/api/chat/public/messages") { request in
      if failing.get { return (503, ["error": "Try again"]) }
      return (200, messageJson(id: "m9", speaker: "CALLER", body: "Book a visit", clientKey: request.json["clientKey"]?.stringValue))
    }
    let chat = api.client()
    try await chat.start(displayName: "Layla")
    let photo = CnctChatAttachment(id: "att_1", kind: .image, mimeType: "image/jpeg")
    _ = await caughtCnctError { try await chat.send("Book a visit", attachments: [photo], replyId: "choice_book") }
    let key = try #require(chat.state.failed.first?.clientKey)

    failing.set(false)
    try await chat.retry(key)
    let posts = api.requests("POST", "/api/chat/public/messages")
    #expect(posts.count == 2)
    for post in posts {
      #expect(post.json["replyId"]?.stringValue == "choice_book")
      #expect(post.json["attachmentIds"] == ["att_1"])
      #expect(post.json["clientKey"]?.stringValue == key)
    }
    await chat.dispose()
  }

  @Test("choosing a flow choice sends its title, with its id as replyId")
  func choose() async throws {
    let api = VisitorServer()
    let chat = api.client()
    try await chat.start()
    try await chat.choose(CnctChatFlow.Choice(id: "choice_book", title: "Book a visit"))
    let post = try #require(api.requests("POST", "/api/chat/public/messages").first)
    #expect(post.json["body"]?.stringValue == "Book a visit")
    #expect(post.json["replyId"]?.stringValue == "choice_book")
    await chat.dispose()
  }

  @Test("over the socket, the send frame carries the same body as the HTTP path")
  func socketFrame() async throws {
    let api = VisitorServer()
    let sockets = FakeSocketFactory()
    let chat = api.client(sockets: sockets)
    _ = try await live(chat, sockets, accepts: ["ping", "typing", "send"])
    let photo = CnctChatAttachment(id: "att_1", kind: .image, mimeType: "image/jpeg")
    let sending = Task { try await chat.send("Book a visit", attachments: [photo], replyId: "choice_book") }
    #expect(await eventually { sockets.last.sent.count == 1 })
    let frame = try #require(sockets.last.frames.first)
    #expect(frame["type"]?.stringValue == "send")
    #expect(frame["id"] == frame["clientKey"])
    #expect(frame["attachmentIds"] == ["att_1"])
    #expect(frame["replyId"]?.stringValue == "choice_book")
    sockets.last.push([
      "type": "ack", "id": frame["id"]!,
      "message": messageJson(id: "m9", speaker: "CALLER", body: "Book a visit", clientKey: frame["clientKey"]?.stringValue),
    ])
    #expect(try await sending.value.id == "m9")
    await chat.dispose()
  }

  @Test("identify sends the current token, and the token it answers replaces it")
  func identify() async throws {
    let api = VisitorServer()
    api.on("POST", "/api/chat/public/\(visitorKey)/identify") { _ in
      (200, ["token": "signed-in-token", "visitor": ["displayName": "Layla", "anonymous": false, "identified": true]])
    }
    api.on("GET", "/api/chat/public/session") { request in
      let signedIn = request.header("x-chat-token") == "signed-in-token"
      return (
        200,
        [
          "visitor": ["displayName": "Layla", "identified": .bool(signedIn)],
          "conversation": conversationJson(), "messages": .array([]),
        ]
      )
    }
    let store = CnctMemoryTokenStore()
    let chat = api.client(store: store)
    try await chat.start()
    let visitor = try await chat.identify(
      CnctChatIdentity(userId: "user_42", userHash: "abc123", name: "Layla", email: "layla@example.com"))

    let call = try #require(api.requests("POST", "/api/chat/public/\(visitorKey)/identify").first)
    // The anonymous chat moves across because the server sees whose it was.
    #expect(call.header("x-chat-token") == "visitor-token-1")
    #expect(call.json == ["userId": "user_42", "userHash": "abc123", "name": "Layla", "email": "layla@example.com"])
    #expect(visitor.identified)
    #expect(try await store.read("cnct_chat_\(visitorKey)") == "signed-in-token")
    #expect(chat.state.visitor?.identified == true)
    // The conversation that was open is picked up again, under the new token.
    #expect(await eventually { api.requests("GET", "/api/chat/public/session").last?.header("x-chat-token") == "signed-in-token" })
    await chat.dispose()
  }

  @Test("a refused identify keeps the session the client had")
  func identifyRefused() async throws {
    let api = VisitorServer()
    api.on("POST", "/api/chat/public/\(visitorKey)/identify") { _ in (401, ["error": "That signature did not verify."]) }
    let store = CnctMemoryTokenStore()
    let chat = api.client(store: store)
    try await chat.start()
    let error = await caughtCnctError { try await chat.identify(CnctChatIdentity(userId: "u", userHash: "wrong")) }
    #expect(error?.code == .unauthenticated)
    #expect(try await store.read("cnct_chat_\(visitorKey)") == "visitor-token-1")
    #expect(await chat.hasSession)

    api.on("POST", "/api/chat/public/\(visitorKey)/identify") { _ in (409, ["error": "Identity is not set up."]) }
    #expect(await caughtCnctError { try await chat.identify(CnctChatIdentity(userId: "u", userHash: "h")) }?.code == .conflict)
    await chat.dispose()
  }

  @Test("an identity never prints its hash")
  func identityRedacts() {
    let identity = CnctChatIdentity(userId: "user_42", userHash: "deadbeefcafe", email: "layla@example.com")
    for printed in [String(describing: identity), String(reflecting: identity), "\(identity)"] {
      #expect(!printed.contains("deadbeefcafe"))
      #expect(!printed.contains("layla@example.com"))
    }
    var dumped = ""
    dump(identity, to: &dumped)
    #expect(!dumped.contains("deadbeefcafe"))
  }

  @Test("the conversations list and one conversation read back with their messages")
  func conversations() async throws {
    let api = VisitorServer()
    api.on("GET", "/api/chat/public/conversations") { _ in
      var older = conversationJson(id: "conv_0", status: "CLOSED").objectValue!
      older["preview"] = messageJson(id: "m5", speaker: "OPERATOR", body: "Anything else?")
      return (200, ["visitor": ["displayName": "Layla"], "conversations": [conversationJson(), .object(older)]])
    }
    api.on("GET", "/api/chat/public/conversations/conv_0") { _ in
      (
        200,
        [
          "conversation": conversationJson(id: "conv_0", status: "CLOSED"),
          "messages": [messageJson(id: "m4", speaker: "CALLER", body: "Thanks"), messageJson(id: "m5", speaker: "OPERATOR", body: "Anything else?")],
        ]
      )
    }
    let chat = api.client()
    #expect(try await chat.conversations().isEmpty)  // a stranger has none, and nothing is asked
    #expect(api.requests("GET", "/api/chat/public/conversations").isEmpty)

    try await chat.start()
    let list = try await chat.conversations()
    #expect(list.map(\.id) == ["conv_1", "conv_0"])
    #expect(list[1].preview?.body == "Anything else?")
    let transcript = try await chat.conversation("conv_0")
    #expect(transcript.conversation.status == .closed)
    #expect(transcript.messages.map(\.id) == ["m4", "m5"])
    #expect(api.requests("GET", "/api/chat/public/conversations/conv_0").first?.header("x-chat-token") == "visitor-token-1")
    await chat.dispose()
  }

  @Test("read is posted once per reply, retried after a failure, and again for a newer reply")
  func readOncePerReply() async throws {
    let api = VisitorServer()
    let status = Locked(500)
    api.on("POST", "/api/chat/public/conversations/conv_1/read") { _ in (status.get, .null) }
    api.transcript = [
      messageJson(id: "m1", speaker: "SYSTEM", body: "Hello."),
      messageJson(id: "m2", speaker: "CALLER", body: "Hi"),
      messageJson(id: "m3", speaker: "OPERATOR", body: "How can I help?"),
    ]
    let sockets = FakeSocketFactory()
    let chat = api.client(sockets: sockets)
    try await chat.start()

    #expect(await chat.read() == false)  // the server refused: forgotten, so it is tried again
    status.set(204)
    #expect(await chat.read())
    #expect(await chat.read() == false)  // already reported
    #expect(api.requests("POST", "/api/chat/public/conversations/conv_1/read").count == 2)

    sockets.last.push(["type": "chat.message", "payload": ["message": messageJson(id: "m4", speaker: "AI", body: "Anything else?")]])
    #expect(await eventually { chat.state.messages.last?.id == "m4" })
    #expect(await chat.read())
    #expect(api.requests("POST", "/api/chat/public/conversations/conv_1/read").count == 3)
    // A POST with nothing to describe says nothing about JSON — the server refuses one that does.
    #expect(api.requests("POST", "/api/chat/public/conversations/conv_1/read").last?.header("content-type") == nil)
    await chat.dispose()
  }

  @Test("nothing from the team yet means nothing to report")
  func readNothing() async throws {
    let api = VisitorServer()
    api.transcript = [messageJson(id: "m1", speaker: "CALLER", body: "Hi")]
    let chat = api.client()
    try await chat.start()
    #expect(await chat.read() == false)
    #expect(api.requests("POST", "/api/chat/public/conversations/conv_1/read").isEmpty)
    await chat.dispose()
  }

  @Test("a rating posts the score, then the comment, and the conversation comes back rated")
  func rating() async throws {
    let api = VisitorServer()
    api.on("POST", "/api/chat/public/conversations/conv_1/rating") { request in
      let score = request.json["score"] ?? .null
      let comment = request.json["comment"] ?? .null
      return (200, ["conversation": conversationJson(status: "CLOSED", ratable: true, rating: ["score": score, "comment": comment])])
    }
    let chat = api.client()
    try await chat.start()
    let rated = try await chat.rate(4)
    #expect(rated.rating?.score == 4)
    #expect(chat.state.conversation?.rating?.score == 4)
    try await chat.rate(4, comment: " Quick and kind ")
    let posts = api.requests("POST", "/api/chat/public/conversations/conv_1/rating")
    #expect(posts.map(\.json) == [["score": 4], ["score": 4, "comment": "Quick and kind"]])
    #expect(chat.state.conversation?.rating?.comment == "Quick and kind")

    #expect(await caughtCnctError { try await chat.rate(6) }?.code == .invalid)
    api.on("POST", "/api/chat/public/conversations/conv_1/rating") { _ in (409, ["error": "Too late to rate this one."]) }
    let late = await caughtCnctError { try await chat.rate(5) }
    #expect(late?.code == .conflict)
    #expect(late?.message == "Too late to rate this one.")
    await chat.dispose()
  }

  @Test("a name given in the thread updates the visitor")
  func profile() async throws {
    let api = VisitorServer()
    api.on("POST", "/api/chat/public/profile") { request in
      (200, ["visitor": ["displayName": request.json["displayName"] ?? "", "anonymous": false]])
    }
    let chat = api.client()
    try await chat.start()
    let visitor = try await chat.updateProfile(displayName: " Layla ", phone: "+973 3311 2233")
    #expect(visitor.displayName == "Layla")
    #expect(api.requests("POST", "/api/chat/public/profile").first?.json == ["displayName": "Layla", "phone": "+973 3311 2233"])
    #expect(chat.state.visitor?.anonymous == false)
    #expect(await caughtCnctError { try await chat.updateProfile(displayName: "  ") }?.code == .invalid)
    await chat.dispose()
  }
}

@Suite("The 1.0 socket frames")
struct SocketFrameTests {
  @Test("chat.message.updated replaces the message where it stands")
  func messageUpdated() async throws {
    let api = VisitorServer()
    api.transcript = [
      messageJson(id: "m1", speaker: "OPERATOR", body: "Here is the file"),
      messageJson(id: "m2", speaker: "CALLER", body: "Thanks"),
    ]
    let sockets = FakeSocketFactory()
    let chat = api.client(sockets: sockets)
    let log = try await live(chat, sockets)

    sockets.last.push([
      "type": "chat.message.updated",
      "payload": [
        "message": messageJson(
          id: "m1", speaker: "OPERATOR", body: "Here is the file",
          attachments: [["id": "att_9", "kind": "DOCUMENT", "mimeType": "application/pdf", "filename": "invoice.pdf"]])
      ],
    ])
    #expect(await eventually { chat.state.messages.first?.attachments.count == 1 })
    #expect(chat.state.messages.map(\.id) == ["m1", "m2"])
    // The event reaches the log's own task a moment after the state changes, so it is waited for too.
    #expect(
      await eventually {
        log.count { if case .messageUpdated(let message) = $0 { return message.id == "m1" } else { return false } } == 1
      })

    // One this client has never seen is not appended: it belongs to a conversation not on screen.
    sockets.last.push(["type": "chat.message.updated", "payload": ["message": messageJson(id: "m7", speaker: "AI", body: "?")]])
    sockets.last.push(["type": "pong"])
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(chat.state.messages.count == 2)
    await chat.dispose()
  }

  @Test("chat.read records how far the team has read, and says so")
  func read() async throws {
    let api = VisitorServer()
    api.transcript = [messageJson(id: "m2", speaker: "CALLER", body: "Hi", createdAt: "2026-09-08T10:00:00.000Z")]
    let sockets = FakeSocketFactory()
    let chat = api.client(sockets: sockets)
    let log = try await live(chat, sockets)
    sockets.last.push(["type": "chat.read", "payload": ["at": "2026-09-08T10:02:00.000Z"]])
    #expect(await eventually { chat.state.conversation?.seenAt == utc(2026, 9, 8, 10, 2) })
    #expect(chat.state.seenMessageId == "m2")
    #expect(await eventually { log.count { $0 == .read(utc(2026, 9, 8, 10, 2)) } == 1 })
    await chat.dispose()
  }

  @Test("chat.conversation.updated is read in either shape, and moves only what it carries")
  func conversationUpdated() async throws {
    let api = VisitorServer()
    let sockets = FakeSocketFactory()
    let chat = api.client(sockets: sockets)
    _ = try await live(chat, sockets)
    #expect(chat.state.conversation?.assignee?.name == "Sara")

    sockets.last.push(["type": "chat.conversation.updated", "payload": ["withPerson": false, "assignee": nil]])
    #expect(await eventually { chat.state.conversation?.withPerson == false })
    #expect(chat.state.conversation?.assignee == nil)
    #expect(chat.state.conversation?.id == "conv_1")

    sockets.last.push([
      "type": "chat.conversation.updated",
      "payload": ["conversation": ["status": "SNOOZED", "assignee": ["kind": "person", "name": "Omar"]]],
    ])
    #expect(await eventually { chat.state.conversation?.status == .snoozed })
    #expect(chat.state.conversation?.assignee?.name == "Omar")
    #expect(chat.state.conversation?.startedAt == utc(2026, 9, 8, 9, 59))
    await chat.dispose()
  }

  @Test("a closed conversation is closed in state at once, and learns whether it can be rated")
  func closedThenRatable() async throws {
    let api = VisitorServer()
    api.on("GET", "/api/chat/public/conversations/conv_1") { _ in
      (200, ["conversation": conversationJson(status: "CLOSED", ratable: true), "messages": .array([])])
    }
    let sockets = FakeSocketFactory()
    let chat = api.client(sockets: sockets)
    let log = try await live(chat, sockets)
    sockets.last.push(["type": "chat.closed"])
    #expect(await eventually { log.count { $0 == .closed } == 1 })
    #expect(chat.state.status == .ended)
    #expect(chat.state.conversation?.status == .closed)
    #expect(chat.state.conversation?.closedAt != nil)
    #expect(await eventually { chat.state.conversation?.ratable == true })
    await chat.dispose()
  }

  @Test("ending it from this side does the same")
  func endThenRatable() async throws {
    let api = VisitorServer()
    api.on("GET", "/api/chat/public/conversations/conv_1") { _ in
      (200, ["conversation": conversationJson(status: "CLOSED", ratable: true), "messages": .array([])])
    }
    let chat = api.client()
    try await chat.start()
    try await chat.end()
    #expect(chat.state.status == .ended)
    #expect(chat.state.conversation?.ratable == true)
    #expect(chat.state.isLive == false)
    await chat.dispose()
  }
}
