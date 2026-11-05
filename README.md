# CNCT for iOS

The official CNCT SDK for iOS and Swift. Live chat, bookings and tickets against a CNCT workspace,
using the credentials CNCT issues you.

> **Status: complete, not yet released.** Live chat, bookings and tickets are here and tested, at
> parity with the [Flutter SDK](https://github.com/doo-inc/cnct-flutter-sdk) 0.2.0. There is no tag
> yet; do not depend on `main`.

**It is headless, and that is the whole point.** There is no view in this package and no web view.
A business building their own app has a design system already; shipping them a chat bubble to
restyle answers a question they did not ask. So this ships state and events, and the interface is
yours. [`Examples/ChatDemo`](Examples/ChatDemo) is a complete SwiftUI chat screen built on it, in a
few hundred lines you own and can delete. It has no dependencies either: Foundation only.

Sister SDKs, same concepts and the same error codes:
[web](https://github.com/doo-inc/cnct-web-sdk) ·
[Flutter](https://github.com/doo-inc/cnct-flutter-sdk) ·
[Android](https://github.com/doo-inc/cnct-android-sdk).

## Install

Swift Package Manager. In Xcode, **File → Add Package Dependencies…** and paste the repository URL,
or in `Package.swift`:

```swift
.package(url: "https://github.com/doo-inc/cnct-ios-sdk.git", from: "0.1.0")
```

iOS 15 and macOS 12 or later. Pin a tag once there is one: what a client ships is what their users
run, and an SDK that moves under a released app is a bug report nobody can reproduce.

## The host

CNCT runs at **`https://app.doo.ooo`**, and that is where this SDK points unless you say otherwise.
One value decides where everything goes — HTTP and the WebSocket alike, because the socket origin is
derived from it.

```swift
import CNCT

let cnct = Cnct()                                      // https://app.doo.ooo
let local = try Cnct(host: "http://localhost:3001")    // anything else
let staging = try cnct.withBaseURL("https://staging.example.com")
```

A base URL may carry a path, so fronting CNCT on your own domain works:
`https://theirdomain.com/support` puts every request under `/support`.

**Testing is not a different host.** What decides whether a booking is real is the key — a sandbox
key talks to the same `app.doo.ooo` and writes nothing real.

## Two credentials, two doors

| Credential                    | Opens                   | Where it belongs |
| ----------------------------- | ----------------------- | ---------------- |
| `CnctChatPublicKey("…")`      | Live chat, as a visitor | **Inside your app.** It identifies an inbox, not a person, and it is already public — it is in the URL of the hosted chat page. |
| `CnctApiKey("kaer_sk_…")`     | Bookings and tickets    | **On a server you control.** It is account-wide. Mint one in the CNCT console under **Settings → Developers**. |

```swift
Cnct.modules(for: try CnctChatPublicKey("inbox-key"))   // [.chat]
Cnct.modules(for: try CnctApiKey(key))                  // [.bookings, .tickets]
```

Printing a credential never prints the secret — `print`, `po` and `dump` all show the last four
characters only.

## Sandbox and production

An API key comes in two kinds, and the key says which: `kaer_sk_test_…` reads the real account and
writes nothing real; `kaer_sk_live_…` is real. Same host, same tools, same validation, same refusals
— going live is swapping the key.

```swift
let key = try CnctApiKey(ProcessInfo.processInfo.environment["CNCT_API_KEY"] ?? "")
key.mode       // .sandbox | .production
key.isSandbox  // true for kaer_sk_test_…
```

## Chat

```swift
let chat = cnct.chat(try CnctChatPublicKey("the-inbox-public-key"), tokenStore: CnctKeychainTokenStore())

Task { for await state in chat.states { render(state) } }  // every change, as an immutable snapshot
Task { for await event in chat.events { onEvent(event) } } // the things a UI does rather than shows

let inbox = try await chat.boot()   // greeting, whether it is open, whether it wants a number
if inbox.isActive {
  try await chat.start(displayName: "Layla")
  try await chat.send("Do you open on Fridays?")
}
```

`boot()` is readable without a session — it is the front door, and it is what tells you whether to
draw a composer at all. `start()` mints a visitor, or reuses the one behind a stored token, and opens
the socket. From there, `chat.state` is everything a UI renders.

The client is an `actor`, so it is safe to call from anywhere. `state`, `states` and `events` need no
`await`: a view can read the snapshot and subscribe synchronously, and `states` hands every new
subscriber the current snapshot first, so there is no gap between reading and listening for a change
to fall into. Each access to `states` or `events` is a stream of its own — subscribe from as many
places as you like. Both end after `dispose()`.

### The state

| Field           | What it is                                                                     |
| --------------- | ------------------------------------------------------------------------------ |
| `status`        | `.idle` → `.connecting` / `.live` / `.offline`, and `.ended` once closed        |
| `inbox`         | What `boot()` returned                                                         |
| `conversation`  | `status`, `startedAt`, and `withPerson` — somebody is on the thread, never who  |
| `messages`      | Oldest first, with `pending` and `failed` on the visitor's own                  |
| `theyAreTyping` | True while the other side is typing; clears itself                             |
| `error`         | The last failure, or nil                                                       |
| `canSend`       | Whether there is a conversation to type into                                   |

`.offline` is not an error state. The transcript is still true, sends still go over HTTP, and a
reconnect is already backing off towards its next attempt.

### In SwiftUI

The SDK knows nothing about SwiftUI, and an observable model over it is a handful of lines in your
app — which is where it belongs, next to the rest of your state:

```swift
@MainActor @Observable
final class ChatModel {
  private(set) var state = CnctChatState()
  let chat: CnctChatClient

  init(chat: CnctChatClient) { self.chat = chat }

  /// Call from `.task {}`: it ends when the view goes away.
  func listen() async {
    for await state in chat.states { self.state = state }
  }
}
```

`CnctChatState` is `Equatable` and every model in it is a value, so a view comparing snapshots
re-renders only when something moved. The example app's
[`ChatModel`](Examples/ChatDemo/ChatDemo/ChatModel.swift) is the longer version.

### Cards

Every message carries a `type`. It is `.text` for ordinary words, and a card for the few things a
customer is meant to read as something other than a sentence.

```swift
if let ticket = message.ticket {
  TicketCard(ticket)      // ticketNumber, title, status, raisedAt
} else if let booking = message.booking {
  BookingCard(booking)    // title, startsAt, endsAt, status, locationName, partySize
} else {
  Text(message.body)
}
```

**`body` always reads correctly on its own** — "We have opened ticket #1042 for this: Refund not
received" — so an app built before a card type existed shows something true rather than an empty
bubble. That last branch is the whole of what an older app needs, which is what makes adding a card
type a non-breaking change. An unrecognised card arrives as `.other`, with its name in `rawType` and
its fields in `data`, for an app that wants to opt in early.

Booking times arrive as a `Date` — an instant — so format them with the device's own calendar and
zone: a customer reads their own clock, not the business's.

### Three things it does for you

**A reconnect reloads.** The platform's fan-out replays nothing after a drop — deliberately — so this
client refetches the whole transcript every time it reconnects rather than splicing a gap it cannot
measure. Rendering `state.messages` is always rendering the truth. Words the visitor typed that the
server has not got yet survive the reload, still marked, so their retry button does not vanish.

**A send is idempotent.** Every message carries a `clientKey`, unique per conversation on the server,
so a frame replayed across a reconnect returns the row it already wrote instead of writing a second
one. That is what makes `send()` safe to reject on a timeout: a failed bubble stays on screen, marked
`failed`, and `retry(clientKey)` cannot double-post.

**It degrades rather than breaks.** The server announces what it accepts on the handshake. Sends go
over the socket where that is offered and fall back to `POST /api/chat/public/messages` where it is
not — which covers both an older server and the ordinary case of the socket being between
connections. Nothing in your code changes either way.

The socket is `URLSessionWebSocketTask`, behind the `CnctSocket` protocol: pass a `socketFactory` to
`CnctChatClient` to drive it with your own — a fake in a test, say.

### Keeping the visitor

A session token is a thirty-day secret scoped to one conversation. Held, somebody who chatted last
week comes back to their own thread; lost, they arrive as a stranger. The default store is memory,
which is right for a test and wrong for an app — so in an app, pass the Keychain:

```swift
let chat = cnct.chat(try CnctChatPublicKey(publicKey), tokenStore: CnctKeychainTokenStore())
try await chat.resume() // false simply means they have not been here before
```

`CnctKeychainTokenStore` keeps the token as a generic password, readable once the device has been
unlocked after starting, under a service you can name (`CnctKeychainTokenStore(service:)`) and an
access group you can share with an extension (`accessGroup:`). Anything else — an app group
container, your own storage — is three methods: conform to `CnctTokenStore`.

A refused token is cleared for you: `resume()` answers false, and a socket the server closes for a
dead token emits `.unauthenticated` rather than reconnecting against a credential that will never
work.

### Identity

A visitor is anonymous until they volunteer a phone number. If your app has already signed this
person in, **pass the number you hold**: it is the difference between a thread that joins their
history and one that starts a second record for them.

```swift
try await chat.start(displayName: user.name, phone: user.phone)
```

There is no signed identity handshake yet — no `setUser` with an HMAC — so this is the honest weak
spot of the channel, and `start(phone:)` is the way around it today.

### Files

An operator's attachments are served only to the visitor's own session, so a plain `AsyncImage`
would be refused. `chat.downloadAttachment(id)` answers the bytes; `chat.attachmentRequest(id)`
answers a `URLRequest` carrying the session header, for an image loader of your own.

---

## Bookings and tickets

Server-side, on the API key — a sandbox one (`kaer_sk_test_…`) while you build. This is for
server-side Swift, internal tools and debug builds; an app that ships this key ships it to anybody
with the binary.

```swift
let agent = Cnct().agent(try CnctApiKey(ProcessInfo.processInfo.environment["CNCT_API_KEY"] ?? ""))

let day = try await agent.bookings.checkAvailability(date: "2026-09-15", partySize: 4)
if let slot = day.free.first {
  let booking = try await agent.bookings.create(
    startsAt: slot.startsAt,   // exactly as given
    customerPhone: "+97312345678",
    name: "Layla",
    nameIsTheCaller: true
  )
  booking.sandbox // true for a sandbox key — kept so you can find, move and cancel it, never seen
} else {
  print(day.note ?? "") // "No table seats six that day." — an answer, with the reason
}
```

Three things are worth knowing before you build against it.

**Pass `startsAt` back verbatim.** It is the token a slot is matched on. Rebuilding it from a parsed
`Date` is how a booking lands on a time that was never offered — `startsAtUtc` is for sorting and
display, never for sending.

**The phone number is the authorization boundary.** There is no ambient identity out here, so the
number is what decides whose booking may be read and changed, and the platform resolves it itself.

**`nameIsTheCaller` is small and load-bearing.** A booking's name and a customer's name are different
facts about different people: somebody booking a haircut for their daughter gives their daughter's
name, and filing that against the number renames the contact permanently. Leave it false unless the
name given is the number's own owner.

`agent.catalogue()` lists exactly the tools a particular account offers, with the rules it books
under (`rules.timezone`, `rules.slotMinutes`, `rules.services`, and the rest raw in `rules.raw`).
`agent.mode` says sandbox or production before anything is sent.

Tickets follow the platform's own sequence — list the types, read what one needs, raise it:

```swift
let types = try await agent.tickets.types()
let type = try await agent.tickets.type(types.items[0].ticketTypeId)
// `askFor` is already only the questions worth asking: what the platform knows is subtracted.
let ticket = try await agent.tickets.create(
  ticketTypeId: type.ticketTypeId,
  title: "Leaking tap",
  reasonUnresolved: "Needs a plumber",
  customerPhone: "+97312345678",
  fields: Dictionary(uniqueKeysWithValues: type.askFor.map { ($0.key, CnctJSON.string(answers[$0.key] ?? "")) }),
  idempotencyKey: attemptId // retry with the same value, get the same ticket
)
```

### Following a ticket up

Most of what happens to a ticket after it is raised is the customer asking about it, or telling you
something new. All three of these are scoped to the customer's own number:

```swift
// "Any news on my refund?"
let open = try await agent.tickets.forCustomer(phone, q: "refund")
let ticket = try await agent.tickets.get(phone, open.items[0].ticketNumber)
ticket.status            // "WAITING"
ticket.waitingOnCustomer // true — the business is waiting on an answer from them
for line in ticket.history { print(line.on, line.what) }

// "The order number is 881"
let added = try await agent.tickets.addTo(
  customerPhone: phone,
  ticketNumber: ticket.ticketNumber,
  note: "The order number is 881"
)
added.resumed // true — it was waiting on them, and is being worked on again
```

**`get` is safe to show the customer it belongs to** — no person's name on any line, no team, and
none of the notes staff write for each other. Somebody else's ticket number is refused exactly as a
number that does not exist is.

**`addTo` instead of a second ticket.** A follow-up belongs on the ticket it is about. If that ticket
was waiting on the customer it goes back to being worked on; a resolved, closed or cancelled one
refuses with `.toolRefused`, and the refusal says to raise a new one. The same words twice within ten
minutes are kept once, so a retry is safe. Both need a CNCT host from 2026-09-29 or later —
`app.doo.ooo` is one.

`forCustomer` also takes `ticketNumber:` and `includeResolved: true`.

### The same tools, for an AI agent

This SDK is the REST side, at `/api/tools`. The same key opens the same tools over MCP, at
**`https://app.doo.ooo/api/mcp`** with the key as a bearer token — point any MCP client there and it
discovers them on its own. MCP also carries one tool REST does not: `request_operator`, for handing a
live phone call to a person.

### Worth knowing

**An empty list is often an instruction rather than an absence.** `bookings.people()` coming back
empty with a note means the business assigns whoever is free and you must not offer a choice of
person. Read `note`.

**A tool that declines answers `200` with a sentence.** The typed methods raise those as `CnctError`
with `.toolRefused`; `agent.call(name, args)` hands the raw answer back instead, and reaches any tool
the platform adds after this SDK was published.

---

## Errors

Everything fails with `CnctError`. Branch on `code` — it is stable, it is the server's own code where
the failure came from the server, and it is the same string the web, Flutter and Android SDKs use, so
an answer that works for one works here.

```swift
do {
  try await chat.send(text)
} catch let error as CnctError {
  if error.isUnauthenticated { return signInAgain() }
  if error.isRetryable { return scheduleRetry() }   // offline, timeout, rate_limited, server_error
  show(error.message)
}
```

A 4xx that is not `rate_limited` is not worth retrying. `details` carries the server's whole error
body — what a tool answered, the fields that failed validation. `storage_failed` is the one code that
never involved a server: the Keychain would not keep or hand back the session token.

## Limits

Thirty messages a minute per visitor, five session starts a minute per IP, four thousand characters a
message. The socket counts the same thirty the HTTP path does, so moving between them buys nothing.

## The example app

[`Examples/ChatDemo`](Examples/ChatDemo) is a SwiftUI app — a chat screen with bubbles, cards,
attachments, a retry button and a typing line — on the headless client and the Keychain store. It
builds against the package in this repository, so it is always the SDK as it is on the branch.

```sh
echo 'CNCT_PUBLIC_KEY = your-inbox-public-key' > Examples/ChatDemo/Local.xcconfig
open Examples/ChatDemo/ChatDemo.xcodeproj
```

iOS 17, for `@Observable`; the SDK itself needs only iOS 15. See its
[README](Examples/ChatDemo/README.md).

## Development

```sh
swift test                                                   # macOS, no simulator
xcodebuild test -scheme CNCT -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -project Examples/ChatDemo/ChatDemo.xcodeproj -scheme ChatDemo \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

The tests run against fakes — a `URLProtocol` that answers HTTP, and a fake socket — so the suite is
offline. One suite opens a real WebSocket on the loopback interface to prove the URLSession socket,
close codes included; the Keychain suite skips itself where the test process has no Keychain.

CI runs all three on every pull request. A tag `vX.Y.Z` must match `CnctConfig.sdkVersion`, or the
release workflow refuses it.

## Versioning

Semantic. Anything that changes the shape of a client's calls is a major, and the platform's own
`/sdk/v1/` promise is the one this mirrors: what a client ships is what their users run, and we
cannot deploy to it.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
