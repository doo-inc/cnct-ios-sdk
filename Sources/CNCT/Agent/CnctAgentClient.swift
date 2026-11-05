import Foundation

/// The account's own operations — bookings and tickets — against the API key CNCT issued you.
///
/// **This credential is account-wide. Keep it on a server.** Everything here reads and writes on
/// behalf of the whole account, and the customer each call is about is named by phone number rather
/// than inferred from a session. An app that held this key could book for, and cancel, anybody.
/// The intended shape is: your app talks to your backend, your backend holds the key and uses this.
///
/// ```swift
/// let agent = CnctAgentClient(
///   config: CnctConfig(), // https://app.doo.ooo
///   credentials: try CnctApiKey(ProcessInfo.processInfo.environment["CNCT_API_KEY"] ?? "")
/// )
/// let day = try await agent.bookings.checkAvailability(date: "2026-09-12", partySize: 4)
/// if let slot = day.free.first {
///   try await agent.bookings.create(
///     startsAt: slot.startsAt,   // exactly as given
///     customerPhone: "+97312345678",
///     name: "Layla"
///   )
/// }
/// ```
public final class CnctAgentClient: Sendable {
  /// ``CnctKeyMode/sandbox`` for a `kaer_sk_test_` key — see ``CnctApiKey``.
  public let mode: CnctKeyMode

  /// The calendar.
  public let bookings: CnctBookings

  /// Tickets — the work a business hands to a colleague.
  public let tickets: CnctTickets

  private let tools: CnctToolCaller

  /// `transport` defaults to one on `URLSession.shared` for `config`. Pass your own to share a
  /// session, or — in a test — one that answers without a network.
  public init(config: CnctConfig, credentials: CnctApiKey, transport: CnctTransport? = nil) {
    let tools = CnctToolCaller(
      transport: transport ?? CnctTransport(config: config),
      headers: credentials.headers
    )
    self.tools = tools
    self.mode = credentials.mode
    self.bookings = CnctBookings(tools: tools)
    self.tickets = CnctTickets(tools: tools)
  }

  /// What this account's credential may actually do, and the rules it must do it within.
  ///
  /// Filtered per account: an account without ticketing is not shown ticket tools. Read this rather
  /// than assuming — it is also the cheapest way to check a key works.
  public func catalogue() async throws -> CnctCatalogue {
    let json = CnctJSON.object(try await tools.transport.get("/api/tools", headers: tools.headers).requireObject())
    return CnctCatalogue(
      tools: json.objects("tools").map(CnctTool.init(json:)),
      rules: CnctBookingRules(json: .object(json.object("rules")))
    )
  }

  /// Call any tool by name, and get back exactly what the platform sent.
  ///
  /// The escape hatch, and a supported one: a tool added to the platform after this SDK was
  /// published is reachable here on the day it ships, without waiting for a release. **It does not
  /// throw on a refusal** — a tool that declines answers `200` with an `error` sentence, and this
  /// hands that back for you to read. Use ``callOrThrow(_:_:)`` for the other behaviour.
  @discardableResult
  public func call(_ tool: String, _ args: [String: CnctJSON] = [:]) async throws -> [String: CnctJSON] {
    try await tools.call(tool, args)
  }

  /// ``call(_:_:)``, but a refusal becomes a ``CnctError`` with ``CnctErrorCode/toolRefused``.
  @discardableResult
  public func callOrThrow(_ tool: String, _ args: [String: CnctJSON] = [:]) async throws -> [String: CnctJSON] {
    try await tools.callOrThrow(tool, args)
  }
}

/// The one route every tool goes through, shared by the client and its two halves so that neither
/// half holds the client — and so a refusal is raised in exactly one place.
struct CnctToolCaller: Sendable {
  let transport: CnctTransport
  let headers: [String: String]

  func call(_ tool: String, _ args: [String: CnctJSON]) async throws -> [String: CnctJSON] {
    try await transport.post(
      "/api/tools/\(CnctConfig.pathSegment(tool))",
      body: .object(args),
      headers: headers
    ).requireObject()
  }

  func callOrThrow(_ tool: String, _ args: [String: CnctJSON]) async throws -> [String: CnctJSON] {
    let result = try await call(tool, args)
    if let refusal = result["error"]?.stringValue {
      throw CnctError(refusal, code: .toolRefused, details: .object(result))
    }
    return result
  }

  /// A list the platform answered, with whatever it said about it.
  func listing<Item>(
    _ tool: String,
    _ args: [String: CnctJSON] = [:],
    key: String,
    parse: (CnctJSON) -> Item
  ) async throws -> CnctListing<Item> {
    let result = CnctJSON.object(try await call(tool, args))
    return CnctListing(
      items: result.objects(key).map(parse),
      note: result["note"]?.stringValue,
      refusal: result["error"]?.stringValue
    )
  }
}

/// The calendar, as an account's software sees it.
///
/// Every method that is about a particular person takes `customerPhone` in full international form.
/// That is not a convenience parameter — it *is* the authorization boundary. There is no ambient
/// identity out here, so the number is what decides whose booking may be read and changed, and the
/// platform resolves it itself rather than trusting an id a caller could have guessed.
public struct CnctBookings: Sendable {
  let tools: CnctToolCaller

  /// What the business can be booked for. An empty list means it books generically.
  public func services() async throws -> CnctListing<CnctService> {
    try await tools.listing("list_services", key: "services", parse: CnctService.init(json:))
  }

  /// The people and tables that can be asked for by name.
  ///
  /// **An empty list is an instruction, not an absence.** A business that has switched named
  /// preference off is telling you not to offer a choice of person — the reason accounts turn it off
  /// is that one popular stylist absorbs every request while three others sit idle.
  /// ``CnctListing/note`` says which case you are in.
  public func people() async throws -> CnctListing<CnctBookableResource> {
    try await tools.listing("list_people", key: "people", parse: CnctBookableResource.init(json:))
  }

  /// The free times on a date. **Always call this before offering anybody a time.**
  ///
  /// `date` is `YYYY-MM-DD` in the business's own timezone — the one ``CnctBookingRules/timezone``
  /// names, which is not necessarily the device's.
  public func checkAvailability(
    date: String,
    serviceId: String? = nil,
    resourceId: String? = nil,
    partySize: Int? = nil,
    locationId: String? = nil
  ) async throws -> CnctAvailability {
    let args: [String: CnctJSON?] = [
      "date": .string(date),
      "serviceId": serviceId.map(CnctJSON.string),
      "resourceId": resourceId.map(CnctJSON.string),
      "partySize": partySize.map(CnctJSON.int),
      "locationId": locationId.map(CnctJSON.string),
    ]
    return CnctAvailability(json: .object(try await tools.callOrThrow("check_availability", args.compacted())))
  }

  /// Take a booking at a time ``checkAvailability(date:serviceId:resourceId:partySize:locationId:)``
  /// reported free.
  ///
  /// Pass `startsAt` exactly as the slot gave it. Rebuilding it from a parsed `Date` is how a booking
  /// lands on a time nobody offered.
  ///
  /// `nameIsTheCaller` is small and load-bearing. A booking's name and a customer's name are
  /// different facts about different people: somebody booking a haircut for their daughter gives
  /// their daughter's name, and filing it against the number would rename the contact permanently.
  /// Leave it false unless the name given is the phone number's own owner.
  @discardableResult
  public func create(
    startsAt: String,
    customerPhone: String,
    serviceId: String? = nil,
    resourceId: String? = nil,
    partySize: Int? = nil,
    name: String? = nil,
    nameIsTheCaller: Bool = false,
    notes: String? = nil,
    locationId: String? = nil
  ) async throws -> CnctBookingConfirmation {
    let args: [String: CnctJSON?] = [
      "startsAt": .string(startsAt),
      "customerPhone": .string(customerPhone),
      "serviceId": serviceId.map(CnctJSON.string),
      "resourceId": resourceId.map(CnctJSON.string),
      "partySize": partySize.map(CnctJSON.int),
      "name": name.map(CnctJSON.string),
      "nameIsTheCaller": .bool(nameIsTheCaller),
      "notes": notes.map(CnctJSON.string),
      "locationId": locationId.map(CnctJSON.string),
    ]
    return CnctBookingConfirmation(json: .object(try await tools.callOrThrow("create_booking", args.compacted())))
  }

  /// One customer's upcoming bookings. Call this before changing anything — you need the id, and
  /// the lookup is also what proves the booking is theirs.
  public func forCustomer(_ customerPhone: String) async throws -> CnctListing<CnctBookingSummary> {
    try await tools.listing(
      "find_my_booking",
      ["customerPhone": .string(customerPhone)],
      key: "bookings",
      parse: CnctBookingSummary.init(json:)
    )
  }

  /// Move one of that customer's bookings to a different free time. Returns when it now is, in the
  /// business's words.
  @discardableResult
  public func reschedule(bookingId: String, startsAt: String, customerPhone: String) async throws -> String {
    let result = try await tools.callOrThrow(
      "reschedule_booking",
      ["bookingId": .string(bookingId), "startsAt": .string(startsAt), "customerPhone": .string(customerPhone)]
    )
    return result["when"]?.stringValue ?? ""
  }

  /// Cancel one of that customer's bookings. Returns the time it *was* at, for the sentence you say
  /// back to them.
  @discardableResult
  public func cancel(bookingId: String, customerPhone: String) async throws -> String {
    let result = try await tools.callOrThrow(
      "cancel_booking",
      ["bookingId": .string(bookingId), "customerPhone": .string(customerPhone)]
    )
    return result["was"]?.stringValue ?? ""
  }
}

/// Tickets: the work a business could not finish in the moment and hands to a colleague.
public struct CnctTickets: Sendable {
  let tools: CnctToolCaller

  /// The kinds of work this business hands over. Start here — the type decides what facts are
  /// needed.
  ///
  /// An empty list with a ``CnctListing/refusal`` means no ticket types are configured yet, which is
  /// an account setup step rather than a failure of this call.
  public func types() async throws -> CnctListing<CnctTicketType> {
    try await tools.listing("list_ticket_types", key: "types", parse: CnctTicketType.init(json:))
  }

  /// What one type still needs before it can be raised.
  ///
  /// The subtraction happens on the server: ``CnctTicketTypeDetail/askFor`` is already only the
  /// questions worth asking, with what the platform knows about this customer removed. Ask for
  /// those and nothing else.
  public func type(_ ticketTypeId: String) async throws -> CnctTicketTypeDetail {
    CnctTicketTypeDetail(
      json: .object(try await tools.callOrThrow("get_ticket_type", ["ticketTypeId": .string(ticketTypeId)]))
    )
  }

  /// Raise one.
  ///
  /// `fields` is keyed exactly as ``type(_:)`` named them — never invent a key. `idempotencyKey` is
  /// worth sending: retry with the same value and you get the same ticket back rather than a second
  /// one. Omit it and every call raises a new ticket.
  @discardableResult
  public func create(
    ticketTypeId: String,
    title: String,
    reasonUnresolved: String,
    customerPhone: String? = nil,
    customerRequest: String? = nil,
    desiredOutcome: String? = nil,
    actionsTaken: String? = nil,
    recommendedNextAction: String? = nil,
    priority: String? = nil,
    fields: [String: CnctJSON] = [:],
    idempotencyKey: String? = nil
  ) async throws -> CnctRaisedTicket {
    let args: [String: CnctJSON?] = [
      "ticketTypeId": .string(ticketTypeId),
      "title": .string(title),
      "reasonUnresolved": .string(reasonUnresolved),
      "customerPhone": customerPhone.map(CnctJSON.string),
      "customerRequest": customerRequest.map(CnctJSON.string),
      "desiredOutcome": desiredOutcome.map(CnctJSON.string),
      "actionsTaken": actionsTaken.map(CnctJSON.string),
      "recommendedNextAction": recommendedNextAction.map(CnctJSON.string),
      "priority": priority.map(CnctJSON.string),
      "fields": fields.isEmpty ? nil : .object(fields),
      "idempotencyKey": idempotencyKey.map(CnctJSON.string),
    ]
    return CnctRaisedTicket(json: .object(try await tools.callOrThrow("create_ticket", args.compacted())))
  }

  /// One customer's tickets, found by their number — open ones unless `includeResolved`. Narrow
  /// with `q` (a word from what it is about) or `ticketNumber`. Never describe a ticket to anybody
  /// but the person it belongs to.
  public func forCustomer(
    _ customerPhone: String,
    q: String? = nil,
    ticketNumber: Int? = nil,
    includeResolved: Bool = false
  ) async throws -> CnctListing<CnctTicketSummary> {
    let args: [String: CnctJSON?] = [
      "customerPhone": .string(customerPhone),
      "q": q.map(CnctJSON.string),
      "ticketNumber": ticketNumber.map(CnctJSON.int),
      "includeResolved": includeResolved ? .bool(true) : nil,
    ]
    return try await tools.listing(
      "find_my_tickets", args.compacted(), key: "tickets", parse: CnctTicketSummary.init(json:))
  }

  /// One of this customer's tickets in detail, as the customer may see it: its status, whether it
  /// is waiting on them, what they asked for, the details on it and what has happened so far.
  ///
  /// There are no names in it — not who is handling it, not who moved it — and none of the notes
  /// the team writes for each other. Somebody else's ticket number is refused exactly as a number
  /// that does not exist is, so this cannot be used to find out whether a ticket exists.
  ///
  /// Needs a CNCT host from 2026-09-29 or later (it serves `get_ticket`).
  public func get(_ customerPhone: String, _ ticketNumber: Int) async throws -> CnctTicketDetail {
    let result = try await tools.callOrThrow(
      "get_ticket",
      ["customerPhone": .string(customerPhone), "ticketNumber": .int(ticketNumber)]
    )
    return CnctTicketDetail(json: .object(result))
  }

  /// Pass something the customer said on to whoever is handling one of their open tickets — new
  /// information, an answer to a question, "it got worse". **Use this rather than
  /// ``create(ticketTypeId:title:reasonUnresolved:customerPhone:customerRequest:desiredOutcome:actionsTaken:recommendedNextAction:priority:fields:idempotencyKey:)``**
  /// when they are following up on something already open: a second ticket splits the story in
  /// two.
  ///
  /// If the ticket was waiting on the customer, this starts it moving again
  /// (``CnctTicketFollowUp/resumed``). A resolved, closed or cancelled ticket refuses — raise a new
  /// one that mentions the old number. The same words sent twice within ten minutes are kept once,
  /// so a retry is safe.
  ///
  /// Needs a CNCT host from 2026-09-29 or later (it serves `add_to_ticket`).
  @discardableResult
  public func addTo(customerPhone: String, ticketNumber: Int, note: String) async throws -> CnctTicketFollowUp {
    let result = try await tools.callOrThrow(
      "add_to_ticket",
      ["customerPhone": .string(customerPhone), "ticketNumber": .int(ticketNumber), "note": .string(note)]
    )
    // The number comes back even when the platform's answer leaves it out.
    return CnctTicketFollowUp(json: .object(["ticketNumber": .int(ticketNumber)].merging(result) { _, answered in answered }))
  }
}
