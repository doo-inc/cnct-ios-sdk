import Foundation
import Testing

@testable import CNCT

@Suite("Chat models")
struct ChatModelsTests {
  @Test("a ticket card parses into its four published fields")
  func ticketCard() {
    let message = CnctChatMessage(json: [
      "id": "m1",
      "speaker": "SYSTEM",
      "type": "TICKET_UPDATE",
      "body": "We have opened ticket #1042 for this: Refund not received",
      "createdAt": "2026-09-08T10:00:00.000Z",
      "data": [
        "ticketNumber": 1042,
        "title": "Refund not received",
        "status": "OPEN",
        "raisedAt": "2026-09-08T09:58:00.000Z",
      ],
    ])

    #expect(message.type == .ticketUpdate)
    #expect(message.ticket?.ticketNumber == 1042)
    #expect(message.ticket?.title == "Refund not received")
    #expect(message.ticket?.raisedAt == utc(2026, 9, 8, 9, 58))
    #expect(message.booking == nil)
  }

  @Test("a booking card carries where and when, and nothing internal")
  func bookingCard() {
    let message = CnctChatMessage(json: [
      "id": "m2",
      "speaker": "AI",
      "type": "BOOKING_UPDATE",
      "body": "Booked for Tuesday at 19:30.",
      "createdAt": "2026-09-08T10:00:00.000Z",
      "data": [
        "title": "Dinner",
        "startsAt": "2026-09-15T16:30:00.000Z",
        "endsAt": "2026-09-15T18:00:00.000Z",
        "status": "CONFIRMED",
        "locationName": "Adliya",
        "partySize": 4,
      ],
    ])

    #expect(message.booking?.partySize == 4)
    #expect(message.booking?.locationName == "Adliya")
    // The instant itself, for the device to format in the customer's own clock.
    #expect(message.booking?.startsAt == utc(2026, 9, 15, 16, 30))
    #expect(message.booking?.endsAt == utc(2026, 9, 15, 18, 0))
  }

  @Test("a card type this SDK has never met degrades to text with a readable body")
  func unknownCard() {
    let message = CnctChatMessage(json: [
      "id": "m3",
      "speaker": "AI",
      "type": "DELIVERY_UPDATE",
      "body": "Your order is out for delivery.",
      "createdAt": "2026-09-08T10:00:00.000Z",
      "data": ["courier": "Aramex"],
    ])

    #expect(message.type == .other)
    #expect(message.rawType == "DELIVERY_UPDATE")
    #expect(message.body == "Your order is out for delivery.")
    // The fields are still there for an app that wants to opt in early.
    #expect(message.data?["courier"]?.stringValue == "Aramex")
  }

  @Test("a malformed card does not take the message down with it")
  func malformedCard() {
    let message = CnctChatMessage(json: [
      "id": "m4",
      "speaker": "SYSTEM",
      "type": "TICKET_UPDATE",
      "body": "A ticket was raised.",
      "createdAt": "2026-09-08T10:00:00.000Z",
      "data": ["title": "no number here"],
    ])

    #expect(message.ticket == nil)
    #expect(message.body == "A ticket was raised.")
  }

  @Test("an unknown speaker is a speaker, not an error")
  func speakers() {
    #expect(CnctSpeaker.parse("MARTIAN") == .unknown)
    #expect(!CnctSpeaker.parse("CALLER").isFromBusiness)
    #expect(CnctSpeaker.parse("OPERATOR").isFromBusiness)
  }

  @Test("conversation status parses the three the platform has")
  func conversationStatus() {
    #expect(CnctConversationStatus.parse("OPEN") == .open)
    #expect(CnctConversationStatus.parse("SNOOZED") == .snoozed)
    #expect(CnctConversationStatus.parse("CLOSED") == .closed)
    #expect(CnctConversationStatus.parse("ARCHIVED") == .unknown)
  }

  @Test("attachments arrive typed")
  func attachments() {
    let message = CnctChatMessage(json: [
      "id": "m5",
      "speaker": "OPERATOR",
      "type": "TEXT",
      "body": "Here is the quote.",
      "createdAt": "2026-09-08T10:00:00.000Z",
      "attachments": [
        ["id": "att_1", "kind": "DOCUMENT", "mimeType": "application/pdf", "filename": "quote.pdf", "bytes": 20480]
      ],
    ])

    #expect(message.attachments.count == 1)
    #expect(message.attachments.first?.kind == .document)
    #expect(message.attachments.first?.filename == "quote.pdf")
    #expect(message.attachments.first?.bytes == 20480)
  }

  @Test("state reports what a composer should do")
  func canSend() {
    let idle = CnctChatState()
    #expect(!idle.canSend)

    let live = CnctChatState(
      status: .live,
      conversation: CnctChatConversation(status: .open, startedAt: utc(2026, 9, 8, 0, 0), withPerson: false)
    )
    #expect(live.canSend)

    var ended = live
    ended.status = .ended
    #expect(!ended.canSend)

    let closed = CnctChatState(
      status: .live,
      conversation: CnctChatConversation(status: .closed, startedAt: utc(2026, 9, 8, 0, 0), withPerson: false)
    )
    #expect(!closed.canSend)
  }

  // MARK: Beyond the Dart suite

  @Test("a message with no type is text, and timestamps parse with or without milliseconds")
  func defaults() {
    let message = CnctChatMessage(json: ["id": "m6", "speaker": "AI", "body": "Hi", "createdAt": "2026-09-08T10:00:00Z"])
    #expect(message.type == .text)
    #expect(message.rawType == "TEXT")
    #expect(message.createdAt == utc(2026, 9, 8, 10, 0))
    #expect(message.attachments.isEmpty)
    #expect(message.data == nil)
  }

  @Test("an optimistic bubble is the visitor's own, pending, and keyed")
  func optimistic() {
    let bubble = CnctChatMessage.optimistic(clientKey: "k1", body: "Hello")
    #expect(bubble.id == "pending_k1")
    #expect(bubble.speaker == .caller)
    #expect(bubble.pending)
    #expect(!bubble.failed)
  }
}
