import CNCT
import Foundation
import Testing

@testable import CNCTUI

@Suite("Thread rows")
struct ThreadRowsTests {
  private func rows(_ state: CnctChatState, justNamed: String? = nil) -> [CnctChatRow] {
    CnctChatRow.rows(for: state, day: { _ in "Today" }, justNamed: justNamed)
  }

  private func groups(_ rows: [CnctChatRow]) -> [CnctChatGroup] {
    rows.compactMap { if case .group(let group) = $0 { return group } else { return nil } }
  }

  @Test("the fixture reads as the spec's steps: a day, the greeting centred, five runs, the choices")
  func fixture() async throws {
    let chat = CnctChatFixture.client(language: .en)
    _ = try await chat.boot()
    try await chat.start()
    _ = try? await chat.send(CnctChatFixture.failedText(.en))
    let rows = rows(chat.state)
    guard case .day = rows.first else {
      Issue.record("no day heading first")
      return
    }
    guard case .system(let greeting) = rows[1] else {
      Issue.record("the greeting is not a centred line")
      return
    }
    #expect(greeting.body == "Hello. How can we help?")
    let runs = groups(rows)
    // The visitor, the assistant, the visitor's photo, Sara, then the visitor's two lines together.
    #expect(runs.map(\.mine) == [true, false, true, false, true])
    #expect(runs[1].sender?.name == "Assistant")
    #expect(runs[3].sender?.name == "Sara")
    #expect(runs[4].messages.count == 2)
    #expect(runs[4].messages.last?.failed == true)
    let choices = rows.compactMap { row -> Bool? in if case .choices(_, _, let active) = row { return active } else { return nil } }
    // Offered, and answered since: still shown, no longer tappable.
    #expect(choices == [false])
    await chat.dispose()
  }

  @Test("a person and the assistant are different voices, and so are two people")
  func voices() {
    let ai = CnctChatSender(kind: .ai, name: "Assistant")
    let sara = CnctChatSender(kind: .person, name: "Sara")
    let omar = CnctChatSender(kind: .person, name: "Omar")
    func message(_ id: String, _ speaker: CnctSpeaker, _ sender: CnctChatSender?) -> CnctChatMessage {
      CnctChatMessage(id: id, speaker: speaker, type: .text, rawType: "TEXT", body: id, createdAt: Date(), sender: sender)
    }
    let state = CnctChatState(
      status: .live,
      messages: [
        message("1", .ai, ai), message("2", .ai, ai), message("3", .operator, sara), message("4", .operator, omar),
        message("5", .operator, omar),
      ])
    #expect(groups(rows(state)).map { $0.messages.map(\.id) } == [["1", "2"], ["3"], ["4", "5"]])
  }

  @Test("a new conversation opens with the greeting before anything is sent")
  func greeting() {
    let state = CnctChatState(inbox: CnctChatInbox(business: "Demo", inbox: "App", isActive: true, greeting: "Hello.", requirePhone: false))
    guard case .system(let line) = rows(state).last else {
      Issue.record("no greeting")
      return
    }
    #expect(line.body == "Hello.")
  }

  @Test("an anonymous visitor who has said something is asked for a name, and thanked for it")
  func details() {
    let mine = CnctChatMessage(json: ["id": "1", "speaker": "CALLER", "body": "Hi", "createdAt": "2026-09-08T10:00:00Z"])
    let state = CnctChatState(
      status: .live, conversation: CnctChatConversation(id: "c", status: .open, startedAt: Date(), withPerson: false),
      visitor: CnctChatVisitor(displayName: "Visitor 12", anonymous: true), messages: [mine])
    #expect(rows(state).last == .details)
    #expect(rows(state, justNamed: "Layla").last == .thanks(name: "Layla"))
  }

  @Test("an ended conversation ends with the divider and, when it can be rated, the faces")
  func ended() {
    let closed = CnctChatConversation(id: "c", status: .closed, startedAt: Date(), withPerson: false, ratable: true)
    let state = CnctChatState(status: .ended, conversation: closed, theyAreTyping: true)
    let built = rows(state)
    #expect(built.suffix(2) == [.ended, .rating(closed)])
    #expect(!built.contains(.typing))
    #expect(!CnctChatRow.rows(for: state, day: { _ in "" }, askForRating: false).contains(.rating(closed)))
  }
}
