import Foundation

/// One of the operations the account's credential may perform, as the platform advertises it.
///
/// The catalogue is filtered per account — a client without ticketing is not shown four tools that
/// would refuse — so read it rather than assuming. A catalogue is a promise, and something that has
/// read one will try to keep it.
public struct CnctTool: Sendable, Hashable {
  public let name: String
  public let description: String

  /// JSON Schema for the arguments.
  public let parameters: [String: CnctJSON]

  public init(name: String, description: String, parameters: [String: CnctJSON] = [:]) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }

  public init(json: CnctJSON) {
    self.init(
      name: json["name"]?.stringValue ?? "",
      description: json["description"]?.stringValue ?? "",
      parameters: json["parameters"]?.objectValue ?? json["inputSchema"]?.objectValue ?? [:]
    )
  }
}

/// The booking rules this account works under: its clock, its week, its services and what it will
/// let a caller ask for.
///
/// Worth fetching once at startup and showing: the hours are the difference between an app that
/// offers a time and one that offers a time the business will accept.
public struct CnctBookingRules: Sendable, Hashable {
  /// The business's clock. Every human-readable time this API returns is already in it.
  public let timezone: String
  public let capacity: Int

  /// The step between offered start times.
  public let slotMinutes: Int
  public let services: [CnctService]
  public let resources: [CnctBookableResource]

  /// Everything, unmodelled — `hours`, `locations`, `policy`. Exposed raw rather than pinned to a
  /// shape this SDK would have to break to widen: the parts above are the ones an app renders, and
  /// the rest is here when you need it.
  public let raw: [String: CnctJSON]

  public init(
    timezone: String,
    capacity: Int,
    slotMinutes: Int,
    services: [CnctService],
    resources: [CnctBookableResource],
    raw: [String: CnctJSON] = [:]
  ) {
    self.timezone = timezone
    self.capacity = capacity
    self.slotMinutes = slotMinutes
    self.services = services
    self.resources = resources
    self.raw = raw
  }

  public init(json: CnctJSON) {
    self.init(
      timezone: json["timezone"]?.stringValue ?? "UTC",
      capacity: json["capacity"]?.truncatedInt ?? 0,
      slotMinutes: json["slotMinutes"]?.truncatedInt ?? 0,
      services: json.objects("services").map(CnctService.init(rules:)),
      resources: json.objects("resources").map(CnctBookableResource.init(rules:)),
      raw: json.objectValue ?? [:]
    )
  }
}

/// What ``CnctAgentClient/catalogue()`` answers: the tools this account offers, and the rules it
/// books under.
public struct CnctCatalogue: Sendable, Hashable {
  public let tools: [CnctTool]
  public let rules: CnctBookingRules

  public init(tools: [CnctTool], rules: CnctBookingRules) {
    self.tools = tools
    self.rules = rules
  }
}

/// Something the business can be booked for.
public struct CnctService: Sendable, Hashable {
  public let serviceId: String
  public let name: String

  /// How long it takes. Nil where the business books generically.
  public let minutes: Int?
  public let description: String?

  public init(serviceId: String, name: String, minutes: Int? = nil, description: String? = nil) {
    self.serviceId = serviceId
    self.name = name
    self.minutes = minutes
    self.description = description
  }

  public init(json: CnctJSON) {
    self.init(
      serviceId: json["serviceId"]?.stringValue ?? "",
      name: json["name"]?.stringValue ?? "",
      minutes: json["minutes"]?.truncatedInt,
      description: json["description"]?.stringValue
    )
  }

  /// The same thing under the keys the catalogue's `rules` use for it.
  public init(rules json: CnctJSON) {
    self.init(
      serviceId: json["id"]?.stringValue ?? json["serviceId"]?.stringValue ?? "",
      name: json["name"]?.stringValue ?? "",
      minutes: json["durationMinutes"]?.truncatedInt ?? json["minutes"]?.truncatedInt,
      description: json["description"]?.stringValue
    )
  }
}

/// A named person or table that can be asked for.
///
/// An empty list is a real answer rather than a missing one: a business that assigns whoever is free
/// has switched named preference off deliberately, and an app must not offer a choice it has been
/// told not to offer.
public struct CnctBookableResource: Sendable, Hashable {
  public let resourceId: String
  public let name: String

  /// `person`, `table`, `room`… lower-cased by the platform.
  public let kind: String?
  public let seats: Int?

  public init(resourceId: String, name: String, kind: String? = nil, seats: Int? = nil) {
    self.resourceId = resourceId
    self.name = name
    self.kind = kind
    self.seats = seats
  }

  public init(json: CnctJSON) {
    self.init(
      resourceId: json["resourceId"]?.stringValue ?? "",
      name: json["name"]?.stringValue ?? "",
      kind: json["kind"]?.stringValue,
      seats: json["seats"]?.truncatedInt
    )
  }

  /// The same thing under the keys the catalogue's `rules` use for it.
  public init(rules json: CnctJSON) {
    self.init(
      resourceId: json["id"]?.stringValue ?? json["resourceId"]?.stringValue ?? "",
      name: json["name"]?.stringValue ?? "",
      kind: json["kind"]?.stringValue?.lowercased(),
      seats: json["seats"]?.truncatedInt
    )
  }
}

/// A free time.
public struct CnctSlot: Sendable, Hashable {
  /// The label to show — already in the business's clock, e.g. "19:30".
  public let time: String

  /// **Pass this back exactly as given.** It is the token a booking matches a slot on; reformatting
  /// it, or rebuilding it from a parsed `Date`, is how a booking lands on a time that was never
  /// offered. ``startsAtUtc`` is for display arithmetic only.
  public let startsAt: String

  /// Who or what is free then. Only present when a specific person or table was asked for.
  public let resourceName: String?

  public init(time: String, startsAt: String, resourceName: String? = nil) {
    self.time = time
    self.startsAt = startsAt
    self.resourceName = resourceName
  }

  public init(json: CnctJSON) {
    self.init(
      time: json["time"]?.stringValue ?? "",
      startsAt: json["startsAt"]?.text ?? "",
      resourceName: json["with"]?.stringValue
    )
  }

  /// The instant, parsed. Convenient for sorting and grouping; never send it back — send
  /// ``startsAt``.
  public var startsAtUtc: Date? { CnctDates.parse(startsAt) }
}

/// What a day looks like.
public struct CnctAvailability: Sendable, Hashable {
  public let date: String

  /// Empty means closed or full. ``note`` says which, and it is worth showing: "nothing is free" and
  /// "no table seats six" send a customer to different places.
  public let free: [CnctSlot]
  public let note: String?

  public init(date: String, free: [CnctSlot], note: String? = nil) {
    self.date = date
    self.free = free
    self.note = note
  }

  public init(json: CnctJSON) {
    self.init(
      date: json["date"]?.stringValue ?? "",
      free: json.objects("free").map(CnctSlot.init(json:)),
      note: json["note"]?.stringValue
    )
  }

  public var isEmpty: Bool { free.isEmpty }
}

/// A booking that now exists.
public struct CnctBookingConfirmation: Sendable, Hashable {
  /// True when a sandbox key made it: it is kept so it can be found, moved and cancelled, but it
  /// holds no slot, nobody was told, and the business will never see it.
  public let sandbox: Bool

  public let bookingId: String

  /// In the business's clock and its words — "Tuesday 12 August at 19:30". Ready to read back.
  public let when: String

  /// The name the booking is under, which is not always the customer's.
  public let name: String?
  public let partySize: Int?

  /// The person or table allocated, where the business names them.
  public let resourceName: String?

  public init(
    bookingId: String,
    when: String,
    name: String? = nil,
    partySize: Int? = nil,
    resourceName: String? = nil,
    sandbox: Bool = false
  ) {
    self.bookingId = bookingId
    self.when = when
    self.name = name
    self.partySize = partySize
    self.resourceName = resourceName
    self.sandbox = sandbox
  }

  public init(json: CnctJSON) {
    self.init(
      bookingId: json["bookingId"]?.stringValue ?? "",
      when: json["when"]?.stringValue ?? "",
      name: json["name"]?.stringValue,
      partySize: json["partySize"]?.truncatedInt,
      resourceName: json["with"]?.stringValue,
      sandbox: json["sandbox"]?.boolValue ?? false
    )
  }
}

/// One of a customer's upcoming bookings.
public struct CnctBookingSummary: Sendable, Hashable {
  public let bookingId: String
  public let when: String
  public let name: String?
  public let partySize: Int?

  public init(bookingId: String, when: String, name: String? = nil, partySize: Int? = nil) {
    self.bookingId = bookingId
    self.when = when
    self.name = name
    self.partySize = partySize
  }

  public init(json: CnctJSON) {
    self.init(
      bookingId: json["bookingId"]?.stringValue ?? "",
      when: json["when"]?.stringValue ?? "",
      name: json["name"]?.stringValue,
      partySize: json["partySize"]?.truncatedInt
    )
  }
}

/// A kind of work the business hands over.
public struct CnctTicketType: Sendable, Hashable {
  public let ticketTypeId: String
  public let name: String
  public let description: String?

  public init(ticketTypeId: String, name: String, description: String? = nil) {
    self.ticketTypeId = ticketTypeId
    self.name = name
    self.description = description
  }

  public init(json: CnctJSON) {
    self.init(
      ticketTypeId: json["ticketTypeId"]?.stringValue ?? "",
      name: json["name"]?.stringValue ?? "",
      description: json["description"]?.stringValue
    )
  }
}

/// One field a ticket type still needs.
public struct CnctTicketField: Sendable, Hashable {
  /// Use this exact key in `fields` when raising the ticket. Never invent one.
  public let key: String
  public let isRequired: Bool

  /// Already phrased as a question, so it can go straight on a form label.
  public let question: String

  /// When non-empty, the only accepted values.
  public let mustBeOneOf: [String]

  public init(key: String, isRequired: Bool, question: String, mustBeOneOf: [String] = []) {
    self.key = key
    self.isRequired = isRequired
    self.question = question
    self.mustBeOneOf = mustBeOneOf
  }

  public init(json: CnctJSON) {
    self.init(
      key: json["key"]?.stringValue ?? "",
      isRequired: json["required"]?.boolValue ?? false,
      question: json["question"]?.stringValue ?? "",
      mustBeOneOf: (json["mustBeOneOf"]?.arrayValue ?? []).map(\.text)
    )
  }
}

/// What one ticket type needs before it can be raised.
public struct CnctTicketTypeDetail: Sendable, Hashable {
  public let ticketTypeId: String
  public let name: String

  /// What the platform already has for this customer. Do not ask for these again.
  public let alreadyKnown: [String: CnctJSON]

  /// What is still missing. The subtraction is done on the server, so this list is exactly the
  /// questions worth putting in front of somebody.
  public let askFor: [CnctTicketField]

  public init(ticketTypeId: String, name: String, alreadyKnown: [String: CnctJSON] = [:], askFor: [CnctTicketField]) {
    self.ticketTypeId = ticketTypeId
    self.name = name
    self.alreadyKnown = alreadyKnown
    self.askFor = askFor
  }

  public init(json: CnctJSON) {
    self.init(
      ticketTypeId: json["ticketTypeId"]?.stringValue ?? "",
      name: json["name"]?.stringValue ?? "",
      alreadyKnown: json.object("alreadyKnown"),
      askFor: json.objects("askFor").map(CnctTicketField.init(json:))
    )
  }
}

/// A ticket that now exists.
public struct CnctRaisedTicket: Sendable, Hashable {
  /// What a customer quotes back. A sandbox has its own numbering, from 1.
  public let ticketNumber: Int
  public let note: String?

  /// True when a sandbox key raised it: it is in no queue and nobody will work it.
  public let sandbox: Bool

  public init(ticketNumber: Int, note: String? = nil, sandbox: Bool = false) {
    self.ticketNumber = ticketNumber
    self.note = note
    self.sandbox = sandbox
  }

  public init(json: CnctJSON) {
    self.init(
      ticketNumber: json["ticketNumber"]?.truncatedInt ?? 0,
      note: json["note"]?.stringValue,
      sandbox: json["sandbox"]?.boolValue ?? false
    )
  }
}

/// One of a customer's tickets.
public struct CnctTicketSummary: Sendable, Hashable {
  public let ticketNumber: Int
  public let title: String
  public let status: String

  /// The date it was raised, `YYYY-MM-DD`.
  public let raised: String?

  public init(ticketNumber: Int, title: String, status: String, raised: String? = nil) {
    self.ticketNumber = ticketNumber
    self.title = title
    self.status = status
    self.raised = raised
  }

  public init(json: CnctJSON) {
    self.init(
      ticketNumber: json["ticketNumber"]?.truncatedInt ?? 0,
      title: json["title"]?.stringValue ?? "",
      status: json["status"]?.stringValue ?? "",
      raised: json["raised"]?.stringValue
    )
  }
}

/// One line of a ticket's story, in words a customer can be told. Never who did it.
public struct CnctTicketMilestone: Sendable, Hashable {
  /// `YYYY-MM-DD`.
  public let on: String

  /// "Raised", "Being worked on", "Waiting on the customer", "The customer added: …".
  public let what: String

  public init(on: String, what: String) {
    self.on = on
    self.what = what
  }

  public init(json: CnctJSON) {
    self.init(on: json["on"]?.stringValue ?? "", what: json["what"]?.stringValue ?? "")
  }
}

/// One of a ticket type's own fields, as it was filled in, labelled by its display name.
public struct CnctTicketDetailField: Sendable, Hashable {
  public let name: String

  /// Whatever was filled in — usually a string, but a field can hold a number, a yes/no or a list.
  /// ``CnctJSON/null`` when it was left empty.
  public let value: CnctJSON

  public init(name: String, value: CnctJSON) {
    self.name = name
    self.value = value
  }

  public init(json: CnctJSON) {
    self.init(name: json["name"]?.stringValue ?? "", value: json["value"] ?? .null)
  }
}

/// One of a customer's tickets, as the customer may see it.
///
/// What is missing is deliberate: no person's name anywhere, no team, and none of the notes a
/// business writes for its own staff. It is safe to show to the customer it belongs to — and only
/// to them.
public struct CnctTicketDetail: Sendable, Hashable {
  public let ticketNumber: Int
  public let title: String

  /// The kind of work, by the business's own name for it.
  public let kind: String?

  /// `OPEN`, `IN_PROGRESS`, `WAITING`, `RESOLVED`, `CLOSED` or `CANCELLED`.
  public let status: String

  /// True when the business is waiting on the customer — for an answer, a photo, a time. Ask them
  /// what is needed and pass it on with ``CnctTickets/addTo(customerPhone:ticketNumber:note:)``,
  /// which starts the ticket moving again.
  public let waitingOnCustomer: Bool

  /// `YYYY-MM-DD`.
  public let raised: String?
  public let resolved: String?
  public let closed: String?
  public let customerRequest: String?
  public let desiredOutcome: String?

  /// The ticket type's own fields, labelled by their display names.
  public let details: [CnctTicketDetailField]
  public let history: [CnctTicketMilestone]

  /// How to talk about it — worth following, it is written for exactly that.
  public let note: String?

  public init(
    ticketNumber: Int,
    title: String,
    kind: String? = nil,
    status: String,
    waitingOnCustomer: Bool = false,
    raised: String? = nil,
    resolved: String? = nil,
    closed: String? = nil,
    customerRequest: String? = nil,
    desiredOutcome: String? = nil,
    details: [CnctTicketDetailField] = [],
    history: [CnctTicketMilestone] = [],
    note: String? = nil
  ) {
    self.ticketNumber = ticketNumber
    self.title = title
    self.kind = kind
    self.status = status
    self.waitingOnCustomer = waitingOnCustomer
    self.raised = raised
    self.resolved = resolved
    self.closed = closed
    self.customerRequest = customerRequest
    self.desiredOutcome = desiredOutcome
    self.details = details
    self.history = history
    self.note = note
  }

  public init(json: CnctJSON) {
    self.init(
      ticketNumber: json["ticketNumber"]?.truncatedInt ?? 0,
      title: json["title"]?.stringValue ?? "",
      kind: json["kind"]?.stringValue,
      status: json["status"]?.stringValue ?? "",
      waitingOnCustomer: json["waitingOnCustomer"]?.boolValue ?? false,
      raised: json["raised"]?.stringValue,
      resolved: json["resolved"]?.stringValue,
      closed: json["closed"]?.stringValue,
      customerRequest: json["customerRequest"]?.stringValue,
      desiredOutcome: json["desiredOutcome"]?.stringValue,
      details: json.objects("details").map(CnctTicketDetailField.init(json:)),
      history: json.objects("history").map(CnctTicketMilestone.init(json:)),
      note: json["note"]?.stringValue
    )
  }
}

/// What happened to a follow-up passed on with
/// ``CnctTickets/addTo(customerPhone:ticketNumber:note:)``.
public struct CnctTicketFollowUp: Sendable, Hashable {
  public let ticketNumber: Int

  /// True when the ticket was waiting on the customer and is now being worked on again.
  public let resumed: Bool
  public let note: String?

  public init(ticketNumber: Int, resumed: Bool, note: String? = nil) {
    self.ticketNumber = ticketNumber
    self.resumed = resumed
    self.note = note
  }

  public init(json: CnctJSON) {
    self.init(
      ticketNumber: json["ticketNumber"]?.truncatedInt ?? 0,
      resumed: json["resumed"]?.boolValue ?? false,
      note: json["note"]?.stringValue
    )
  }
}

/// A list, plus what the platform said about it.
///
/// The note is not decoration: an empty list of people means "this business assigns whoever is
/// free — never offer a choice", and an empty list of times means the day is closed, or full, or
/// that no table seats six. Dropping the sentence loses the difference.
public struct CnctListing<Item: Sendable>: Sendable {
  public let items: [Item]
  public let note: String?

  /// Present when the platform refused rather than answered — no ticket types configured, say. The
  /// list will be empty.
  public let refusal: String?

  public init(items: [Item], note: String? = nil, refusal: String? = nil) {
    self.items = items
    self.note = note
    self.refusal = refusal
  }

  public var isEmpty: Bool { items.isEmpty }
  public var count: Int { items.count }
}

extension CnctListing: Equatable where Item: Equatable {}
extension CnctListing: Hashable where Item: Hashable {}
