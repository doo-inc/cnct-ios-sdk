import Foundation
import Testing

@testable import CNCT

/// The catalogue every client in this suite answers `GET /api/tools` with, unless a test says
/// otherwise.
private let defaultCatalogue: CnctJSON = [
  "tools": [
    ["name": "check_availability", "description": "List the free times.", "parameters": [:]]
  ],
  "rules": [
    "timezone": "Asia/Bahrain",
    "capacity": 4,
    "slotMinutes": 30,
    "services": [["id": "svc_1", "name": "Dinner", "durationMinutes": 90]],
    "resources": [["id": "res_1", "name": "Table 4", "kind": "TABLE", "seats": 6]],
    "policy": ["allowResourcePreference": true],
  ],
]

/// A client whose every tool call is answered by `answer(tool, args)`.
private func clientWith(
  catalogue: CnctJSON = defaultCatalogue,
  _ answer: @escaping @Sendable (String, CnctJSON) -> CnctJSON
) -> (CnctAgentClient, FakeServer) {
  let server = FakeServer { request in
    if request.url.path == "/api/tools" { return (200, catalogue) }
    return (200, answer(request.url.lastPathComponent, request.json))
  }
  let agent = CnctAgentClient(
    config: server.config,
    credentials: try! CnctApiKey("kaer_sk_test"),
    transport: server.transport()
  )
  return (agent, server)
}

@Suite("CnctAgentClient")
struct AgentClientTests {
  @Test("the catalogue says what this account may do, and the rules it works under")
  func catalogue() async throws {
    let (agent, server) = clientWith { _, _ in [:] }
    let answer = try await agent.catalogue()

    #expect(answer.tools.first?.name == "check_availability")
    #expect(answer.tools.count == 1)
    #expect(answer.rules.timezone == "Asia/Bahrain")
    #expect(answer.rules.services.first?.minutes == 90)
    #expect(answer.rules.resources.first?.seats == 6)
    // Lower-cased on the way in, because the platform's own spelling of an enum is not a label.
    #expect(answer.rules.resources.first?.kind == "table")
    // The unmodelled half is still reachable.
    #expect(answer.rules.raw["policy"]?["allowResourcePreference"]?.boolValue == true)
    #expect(server.requests.first?.header("authorization") == "Bearer kaer_sk_test")
    #expect(server.requests.count == 1)
  }

  @Test("a tool that declines answers 200 with a sentence, and that becomes an error")
  func refusalRaises() async {
    let (agent, _) = clientWith { _, _ in ["error": "That time is in the past."] }

    let error = await caughtCnctError { _ = try await agent.bookings.checkAvailability(date: "2020-01-01") }
    #expect(error?.code == .toolRefused)
    #expect(error?.message == "That time is in the past.")
    // Everything the tool answered rides along.
    #expect(error?.details?["error"]?.stringValue == "That time is in the past.")
  }

  @Test("the raw escape hatch hands a refusal back rather than raising it")
  func rawCall() async throws {
    let (agent, server) = clientWith { _, _ in ["error": "Nope."] }
    let result = try await agent.call("some_new_tool", ["x": 1])
    #expect(result["error"]?.stringValue == "Nope.")
    #expect(server.requests.first?.json == ["x": 1])
  }

  @Test("availability parses, and startsAt survives as the exact token to send back")
  func availability() async throws {
    let (agent, server) = clientWith { _, args in
      [
        "date": args["date"] ?? .null,
        "free": [
          ["time": "19:30", "startsAt": "2026-09-15T16:30:00.000Z"],
          ["time": "20:00", "startsAt": "2026-09-15T17:00:00.000Z", "with": "Table 4"],
        ],
        "note": "Offer only these times.",
      ]
    }

    let day = try await agent.bookings.checkAvailability(date: "2026-09-15", partySize: 4)
    #expect(day.free.count == 2)
    #expect(day.free.first?.startsAt == "2026-09-15T16:30:00.000Z")
    #expect(day.free.last?.resourceName == "Table 4")
    #expect(day.free.first?.startsAtUtc == utc(2026, 9, 15, 16, 30))

    let sent = try #require(server.requests.first).json
    #expect(sent["date"]?.stringValue == "2026-09-15")
    #expect(sent["partySize"]?.intValue == 4)
  }

  @Test("an empty day is an answer with a reason, not an error")
  func emptyDay() async throws {
    let (agent, _) = clientWith { _, args in
      [
        "date": args["date"] ?? .null,
        "free": [],
        "note": "No table seats six that day. Offer the caller another date.",
      ]
    }

    let day = try await agent.bookings.checkAvailability(date: "2026-09-15", partySize: 6)
    #expect(day.isEmpty)
    #expect(day.note?.contains("seats six") == true)
  }

  @Test("creating a booking sends startsAt verbatim and names the customer by number")
  func createBooking() async throws {
    let (agent, server) = clientWith { _, _ in
      [
        "confirmed": true,
        "bookingId": "bkg_1",
        "when": "Tuesday 15 September at 19:30",
        "partySize": 4,
        "name": "Layla",
        "with": "Table 4",
      ]
    }

    let booking = try await agent.bookings.create(
      startsAt: "2026-09-15T16:30:00.000Z",
      customerPhone: "+97312345678",
      partySize: 4,
      name: "Layla"
    )

    #expect(booking.bookingId == "bkg_1")
    #expect(booking.when == "Tuesday 15 September at 19:30")
    #expect(booking.resourceName == "Table 4")

    let sent = try #require(server.requests.first).json
    #expect(sent["startsAt"]?.stringValue == "2026-09-15T16:30:00.000Z")
    #expect(sent["customerPhone"]?.stringValue == "+97312345678")
    // Defaults false: a name given for somebody else must not rename the number's owner.
    #expect(sent["nameIsTheCaller"]?.boolValue == false)
  }

  @Test("a key knows which kind it is from its prefix")
  func keyMode() throws {
    #expect(try CnctApiKey("kaer_sk_test_abc").mode == .sandbox)
    #expect(try CnctApiKey("kaer_sk_test_abc").isSandbox)
    #expect(try CnctApiKey("kaer_sk_live_abc").mode == .production)
    // Minted before there were two kinds, and production.
    #expect(try CnctApiKey("kaer_sk_mintedbeforemodes").mode == .production)
  }

  @Test("a sandbox booking and ticket say so, and a production one does not")
  func sandbox() async throws {
    let (agent, _) = clientWith { _, _ in
      [
        "ok": true,
        "ticketNumber": 1,
        "confirmed": true,
        "bookingId": "sbx_1",
        "when": "Tuesday 15 September at 19:30",
        "sandbox": true,
      ]
    }
    let booking = try await agent.bookings.create(
      startsAt: "2026-09-15T16:30:00.000Z",
      customerPhone: "+97312345678"
    )
    let ticket = try await agent.tickets.create(
      ticketTypeId: "tt_1",
      title: "Leaking tap",
      reasonUnresolved: "Needs a plumber"
    )
    #expect(booking.sandbox)
    #expect(ticket.sandbox)
    // `kaer_sk_test` has no `test_` segment, so it is a key from before there were two kinds.
    #expect(agent.mode == .production)
    #expect(CnctAgentClient(config: CnctConfig(), credentials: try CnctApiKey("kaer_sk_test_x")).mode == .sandbox)

    let real = CnctBookingConfirmation(json: ["bookingId": "bkg_1", "when": "Today"])
    #expect(!real.sandbox)
  }

  @Test("an empty list of people keeps the sentence that says why")
  func emptyPeople() async throws {
    let (agent, _) = clientWith { _, _ in
      [
        "people": [],
        "note": "This business assigns whoever is free. Never offer the caller a choice of person.",
      ]
    }

    let people = try await agent.bookings.people()
    #expect(people.isEmpty)
    #expect(people.note?.contains("Never offer") == true)
  }

  @Test("ticket types with nothing configured come back empty and say so")
  func noTicketTypes() async throws {
    let (agent, _) = clientWith { _, _ in
      ["types": [], "error": "Not raised. No ticket types are set up on this account yet."]
    }

    let types = try await agent.tickets.types()
    #expect(types.isEmpty)
    #expect(types.refusal?.contains("No ticket types") == true)
  }

  @Test("a ticket type reports only the questions still worth asking")
  func ticketType() async throws {
    let (agent, _) = clientWith { _, _ in
      [
        "ticketTypeId": "tt_1",
        "name": "Maintenance",
        "alreadyKnown": ["flat": "12B"],
        "askFor": [
          ["key": "issue", "required": true, "question": "What is wrong?"],
          ["key": "urgency", "required": false, "question": "How urgent is it?", "mustBeOneOf": ["low", "high"]],
        ],
      ]
    }

    let type = try await agent.tickets.type("tt_1")
    #expect(type.alreadyKnown["flat"]?.stringValue == "12B")
    #expect(type.askFor.map(\.key) == ["issue", "urgency"])
    #expect(type.askFor.last?.mustBeOneOf == ["low", "high"])
    #expect(type.askFor.first?.isRequired == true)
  }

  @Test("an idempotency key travels, so a retry returns the same ticket")
  func idempotencyKey() async throws {
    let (agent, server) = clientWith { _, _ in ["ok": true, "ticketNumber": 1042, "note": "Raised as #1042."] }

    let ticket = try await agent.tickets.create(
      ticketTypeId: "tt_1",
      title: "Leaking tap",
      reasonUnresolved: "Needs a plumber",
      customerPhone: "+97312345678",
      fields: ["flat": "12B"],
      idempotencyKey: "attempt-1"
    )

    #expect(ticket.ticketNumber == 1042)
    let sent = try #require(server.requests.first).json
    #expect(sent["idempotencyKey"]?.stringValue == "attempt-1")
    #expect(sent["fields"] == ["flat": "12B"])
  }

  @Test("every call goes to /api/tools, not the old /api/booking-tools")
  func toolsPath() async throws {
    let (agent, server) = clientWith { _, _ in ["services": []] }
    _ = try await agent.catalogue()
    _ = try await agent.bookings.services()
    #expect(server.paths == ["/api/tools", "/api/tools/list_services"])
  }

  @Test("a customer’s tickets can be narrowed, and nothing unasked-for is sent")
  func narrowTickets() async throws {
    let (agent, server) = clientWith { _, _ in ["tickets": []] }

    _ = try await agent.tickets.forCustomer("+97312345678", q: "refund", includeResolved: true)
    #expect(server.requests.last?.json == ["customerPhone": "+97312345678", "q": "refund", "includeResolved": true])

    _ = try await agent.tickets.forCustomer("+97312345678")
    #expect(server.requests.last?.json == ["customerPhone": "+97312345678"])
  }

  @Test("one ticket reads as the customer may see it")
  func getTicket() async throws {
    let (agent, server) = clientWith { _, _ in
      [
        "ticketNumber": 1042,
        "title": "Refund not received",
        "kind": "Refund",
        "status": "WAITING",
        "waitingOnCustomer": true,
        "raised": "2026-09-18",
        "details": [["name": "Order number", "value": "881"]],
        "history": [
          ["on": "2026-09-18", "what": "Raised"],
          ["on": "2026-09-19", "what": "Waiting on the customer"],
        ],
        "note": "This is waiting on the customer.",
      ]
    }

    let ticket = try await agent.tickets.get("+97312345678", 1042)

    let seen = try #require(server.requests.first)
    #expect(server.requests.count == 1)
    #expect(seen.url.path == "/api/tools/get_ticket")
    #expect(seen.json == ["customerPhone": "+97312345678", "ticketNumber": 1042])
    #expect(ticket.status == "WAITING")
    #expect(ticket.waitingOnCustomer)
    #expect(ticket.kind == "Refund")
    #expect(ticket.details.count == 1)
    #expect(ticket.details.first?.name == "Order number")
    #expect(ticket.details.first?.value == "881")
    #expect(ticket.history.map(\.what) == ["Raised", "Waiting on the customer"])
    #expect(ticket.resolved == nil)
  }

  @Test("a ticket that is not theirs is a refusal, not an empty ticket")
  func notTheirs() async {
    let (agent, _) = clientWith { _, _ in ["error": "No ticket #9 belongs to them."] }

    let error = await caughtCnctError { _ = try await agent.tickets.get("+97312345678", 9) }
    #expect(error?.code == .toolRefused)
    #expect(error?.message == "No ticket #9 belongs to them.")
  }

  @Test("a follow-up lands on the ticket and says when it started it moving again")
  func followUp() async throws {
    let (agent, server) = clientWith { _, _ in ["ok": true, "resumed": true, "note": "Added."] }

    let added = try await agent.tickets.addTo(
      customerPhone: "+97312345678",
      ticketNumber: 1042,
      note: "The order number is 881"
    )

    let seen = try #require(server.requests.first)
    #expect(seen.url.path == "/api/tools/add_to_ticket")
    #expect(seen.json == ["customerPhone": "+97312345678", "ticketNumber": 1042, "note": "The order number is 881"])
    // The number comes back even when the platform's answer leaves it out.
    #expect(added.ticketNumber == 1042)
    #expect(added.resumed)
  }

  @Test("a finished ticket refuses a follow-up in the platform’s own words")
  func finishedTicket() async {
    let (agent, _) = clientWith { _, _ in ["error": "Not added. #7 is resolved."] }

    let error = await caughtCnctError {
      _ = try await agent.tickets.addTo(customerPhone: "+97312345678", ticketNumber: 7, note: "Again")
    }
    #expect(error?.code == .toolRefused)
    #expect(error?.message == "Not added. #7 is resolved.")
  }

  @Test("an HTTP failure is still an HTTP failure, not a refusal")
  func httpFailure() async throws {
    let server = FakeServer { _ in
      (401, ["error": "Send an API key as `Authorization: Bearer kaer_sk_…`"])
    }
    let agent = CnctAgentClient(
      config: server.config,
      credentials: try CnctApiKey("kaer_sk_bad"),
      transport: server.transport()
    )

    let error = await caughtCnctError { _ = try await agent.bookings.services() }
    #expect(error?.code == .unauthenticated)
    #expect(error?.isUnauthenticated == true)
  }

  // MARK: Beyond the Dart suite

  @Test("rescheduling and cancelling name the booking and the customer, and read back the time")
  func rescheduleAndCancel() async throws {
    let (agent, server) = clientWith { tool, _ in
      tool == "reschedule_booking" ? ["ok": true, "when": "Wednesday at 20:00"] : ["ok": true, "was": "Tuesday at 19:30"]
    }

    #expect(
      try await agent.bookings.reschedule(
        bookingId: "bkg_1", startsAt: "2026-09-16T17:00:00.000Z", customerPhone: "+97312345678")
        == "Wednesday at 20:00")
    #expect(try await agent.bookings.cancel(bookingId: "bkg_1", customerPhone: "+97312345678") == "Tuesday at 19:30")
    #expect(server.paths == ["/api/tools/reschedule_booking", "/api/tools/cancel_booking"])
    #expect(server.requests.last?.json == ["bookingId": "bkg_1", "customerPhone": "+97312345678"])
  }

  @Test("a customer's bookings are found by their number")
  func bookingsForCustomer() async throws {
    let (agent, server) = clientWith { _, _ in
      ["bookings": [["bookingId": "bkg_1", "when": "Tuesday at 19:30", "partySize": 2], "not an object"]]
    }

    let bookings = try await agent.bookings.forCustomer("+97312345678")
    #expect(bookings.items == [CnctBookingSummary(bookingId: "bkg_1", when: "Tuesday at 19:30", partySize: 2)])
    #expect(server.requests.first?.url.path == "/api/tools/find_my_booking")
  }

  @Test("an answer that is not an object is a bad response, not an empty one")
  func notAnObject() async {
    let (agent, _) = clientWith { _, _ in ["a", "list"] }
    let error = await caughtCnctError { _ = try await agent.call("list_services") }
    #expect(error?.code == .badResponse)
  }

  @Test("printing a client, or either half of it, never prints the key")
  func redacts() throws {
    let agent = CnctAgentClient(config: CnctConfig(), credentials: try CnctApiKey("kaer_sk_test_supersecretWXYZ"))
    var dumped = ""
    dump(agent, to: &dumped)
    dump(agent.bookings, to: &dumped)
    dump(agent.tickets, to: &dumped)
    let printed = [
      dumped, "\(agent)", "\(agent.bookings)", "\(agent.tickets)",
      String(reflecting: agent), String(reflecting: agent.bookings), String(reflecting: agent.tickets),
    ]
    for text in printed {
      #expect(!text.contains("supersecret"), "\(text)")
    }
    #expect("\(agent.bookings)".contains("apiKey:…WXYZ"))
  }

  @Test("the entry point hands out an agent on the same host")
  func entryPoint() throws {
    let cnct = try Cnct(host: "https://cnct.test")
    #expect(cnct.agent(try CnctApiKey("kaer_sk_test_abc")).mode == .sandbox)
  }
}
