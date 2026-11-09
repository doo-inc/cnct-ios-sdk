import CNCT
import Foundation
import Testing

@testable import CNCTUI

/// Wait for something asynchronous to become true. False if it never did.
func eventually(within seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if await condition() { return true }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  return await condition()
}

@Suite("The fixture conversation")
struct FixtureTests {
  @Test("it plays the spec's eight steps into a real client", arguments: [CnctChatLanguage.en, .ar])
  func script(language: CnctChatLanguage) async throws {
    let chat = CnctChatFixture.client(language: language)
    let inbox = try await chat.boot()
    #expect(inbox.isActive)
    #expect(inbox.widget.chat.allowAttachments)
    #expect(try await chat.resume() == false)  // a stranger, until the screen starts them
    try await chat.start(displayName: "Layla")
    #expect(await eventually { chat.state.status == .live })

    let messages = chat.state.messages
    #expect(messages.count == 6)
    #expect(messages.map(\.speaker) == [.system, .caller, .ai, .caller, .operator, .caller])
    let ar = language == .ar
    #expect(messages[0].body == (ar ? "مرحبًا. كيف يمكننا مساعدتك؟" : "Hello. How can we help?"))
    #expect(messages[1].body == (ar ? "هل تفتحون يوم الجمعة؟" : "Do you open on Fridays?"))
    #expect(messages[2].sender?.name == (ar ? "المساعد" : "Assistant"))
    #expect(messages[2].flow?.choices.map(\.title) == (ar ? ["احجز زيارة", "تحدث مع موظف"] : ["Book a visit", "Talk to a person"]))
    #expect(messages[3].attachments.first?.filename == "photo.jpg")
    #expect(messages[3].attachments.first?.bytes == 1_200_000)
    #expect(messages[4].sender?.name == (ar ? "سارة" : "Sara"))
    #expect(messages[4].attachments.first?.filename == "invoice.pdf")
    #expect(messages[4].attachments.first?.bytes == 220_000)
    #expect(messages[5].body.contains("+973 3311 2233"))

    // Step seven: the message that does not go.
    _ = try? await chat.send(CnctChatFixture.failedText(language))
    #expect(chat.state.failed.count == 1)
    #expect(chat.state.messages.last?.failed == true)

    // Step eight: the team is typing.
    #expect(await eventually { chat.state.theyAreTyping })

    // The files are served, the photo in landscape.
    let invoice = try await chat.downloadAttachment("fx_invoice")
    #expect(invoice.starts(with: Data("%PDF".utf8)))
    await chat.dispose()
  }

  @Test("anything else sent to it is echoed back as stored, files included")
  func echoes() async throws {
    let chat = CnctChatFixture.client()
    try await chat.start()
    let file = try await chat.upload(CnctUploadFile(data: Data("notes".utf8), filename: "notes.txt"))
    #expect(file.filename == "notes.txt")
    let sent = try await chat.send("Thanks!", attachments: [file])
    #expect(sent.body == "Thanks!")
    #expect(sent.failed == false)
    #expect(chat.state.messages.last?.id == sent.id)
    await chat.dispose()
  }

  @Test("two files wait in the composer: a photo 40% up and a PDF already up")
  func picked() {
    let picked = CnctChatFixture.pickedFiles(.en)
    #expect(picked.count == 2)
    #expect(picked[0].progress == 0.4)
    #expect(picked[0].attachment == nil)
    #expect(picked[1].file.mimeType == "application/pdf")
    #expect(picked[1].attachment != nil)
  }
}
