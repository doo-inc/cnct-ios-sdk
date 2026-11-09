# CNCT for iOS

The official CNCT SDK for iOS and Swift: a ready-made chat screen you can brand, and the headless
client underneath it — live chat, bookings and tickets against a CNCT workspace, using the
credentials CNCT issues you.

> **1.0.0, tagged 2026-11-09.** Released together with the [web](https://github.com/doo-inc/cnct-web-sdk)
> and [Android](https://github.com/doo-inc/cnct-android-sdk) SDKs, from one spec
> ([`docs/chat-ui/SPEC.md`](docs/chat-ui/SPEC.md)): the same option names, theme tokens and words on
> every platform.

Two libraries in one package, and no dependencies:

| Library  | What it is | Needs |
| -------- | ---------- | ----- |
| `CNCTUI` | **The chat screen**: SwiftUI `CnctChatView` and UIKit `CnctChatViewController`. Branded from the CNCT console or from code, English and Arabic, photos and files both ways. | iOS 15 |
| `CNCT`   | **The headless client**: state and events, for a business that already has a design system and wants its own screen. Foundation only. | iOS 15, macOS 12 |

The screen is built only on the headless client's public API, so whatever it does, your own screen
can do too.

Sister SDKs, same concepts and the same error codes:
[web](https://github.com/doo-inc/cnct-web-sdk) ·
[Flutter](https://github.com/doo-inc/cnct-flutter-sdk) ·
[Android](https://github.com/doo-inc/cnct-android-sdk).

## Install

Swift Package Manager. In Xcode, **File → Add Package Dependencies…**, paste the repository URL, and
add **CNCTUI** for the screen (it brings `CNCT` with it) or **CNCT** alone for the headless client.
In `Package.swift`:

```swift
.package(url: "https://github.com/doo-inc/cnct-ios-sdk.git", exact: "1.0.0")
```

```swift
.target(name: "YourApp", dependencies: [.product(name: "CNCTUI", package: "cnct-ios-sdk")])
```

Pin the version: what a client ships is what their users run, and an SDK that moves under a released
app is a bug report nobody can reproduce.

If you offer the camera — the screen does wherever the device has one — your app's `Info.plist` needs
`NSCameraUsageDescription`. The photo library and Files need no permission: the system pickers hand
over only what the visitor chooses.

## Chat UI in 10 lines

```swift
import CNCTUI
import SwiftUI

struct SupportView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    CnctChatView(publicKey: try! CnctChatPublicKey("your-inbox-public-key"), onClose: { dismiss() })
  }
}
```

That is the whole integration. The screen boots the inbox, picks up the visitor's conversation from
the Keychain if they have been here before, asks for a name first if the inbox wants one, and draws
everything from there: the team's faces and first names, the assistant's choices and suggestions,
photos and files both ways, "Seen", the rating card when it ends. Colours, logo, language, whether
files are allowed and whether to ask for a rating all come from the inbox's settings in the CNCT
console — change them there and the app follows, with no release.

From UIKit:

```swift
let chat = CnctChatViewController(publicKey: try CnctChatPublicKey("your-inbox-public-key")) { [weak self] in
  self?.dismiss(animated: true)
}
present(chat, animated: true)
```

Every entry point takes the same options, named the same in every CNCT SDK:

| Option     | What it is | Default |
| ---------- | ---------- | ------- |
| `client` / `publicKey` | A `CnctChatClient` you made and keep, or the inbox's public key (the screen then makes the client, with the Keychain store, and lets it go with the screen) | required |
| `theme`    | `CnctChatTheme` — see [Theming](#theming) | the console's settings, then the defaults |
| `language` | `.auto`, `.en` or `.ar` | the console's `brand.language`, then the device |
| `strings`  | `CnctChatStrings(en: [...], ar: [...])`: your own words for any key of the [shared table](docs/chat-ui/strings.json) | none |
| `identity` | `CnctChatIdentity` — see [Signed-in users](#signed-in-users) | anonymous |
| `onClose`  | Shows a close button in the header, and is called when it is tapped | no button |
| `onEvent`  | `CnctChatUIEvent`: `.opened`, `.started`, `.sent`, `.attachmentSent(count:)`, `.ended`, `.rated(score:)` — for analytics, never carrying what anybody wrote | none |

`CnctChatView(fixture: .ar)` is the same screen on a scripted conversation, with no key and no
network — for SwiftUI previews and demos.

## Theming

**Precedence: what the app passes, then the inbox's widget settings on the server, then the built-in
defaults.** Every token is optional, so a business can brand its chat from the CNCT console with no
code at all, or pin any part of it in code:

```swift
CnctChatView(
  client: chat,
  theme: CnctChatTheme(
    primary: "#D7262E",
    cornerRadius: 8,
    font: .named("Georgia"),
    logo: .image(from: UIImage(named: "Logo")!),
    title: "Help",
    appearance: .system
  )
)
```

| Token             | Meaning | Default |
| ----------------- | ------- | ------- |
| `primary`         | Brand colour: send button, links, header accent | the console's `brand.color`, else `#b52d93` |
| `onPrimary`       | Text and icons on `primary` | black or white, whichever reads (the hosted chat's luminance rule) |
| `background`      | The screen | light `#ffffff` / dark `#0f1115` |
| `surface`         | Header, composer, cards | light `#f6f7f9` / dark `#171a21` |
| `text`            | Main text | light `#111418` / dark `#eef0f3` |
| `textMuted`       | Timestamps, hints | light `#5b6573` / dark `#9aa3af` |
| `border`          | Dividers, outlines | light `#e3e6ea` / dark `#2a2f38` |
| `visitorBubble` / `onVisitorBubble` | The customer's own messages | `primary` / `onPrimary` |
| `agentBubble` / `onAgentBubble`     | The team's and the assistant's messages | `surface` / `text` |
| `cornerRadius`    | Bubbles and cards | 18 |
| `font`            | `.system`, or `.named("…")` — scales with Dynamic Type either way | system |
| `logo`            | `.url(…)` or `.image(…)` for the header | the console's logo, else the business's first letter on `primary` |
| `title`           | Header title | the business's name |
| `appearance`      | `.light`, `.dark` or `.system` | the console's `brand.appearance` (`auto` is `.system`) |
| `showPoweredBy`   | The "Powered by CNCT" line | the console's `brand.showBranding` |

Light and dark each have their own colours. `CnctChatTheme(primary:…)` sets a token for both; to
differ, set it on one:

```swift
var theme = CnctChatTheme(primary: "#0057b8")
theme.dark.primary = "#7cb7ff"
theme.dark.background = "#000000"
```

Colours are `CnctChatColor`: a hex literal, or `CnctChatColor(UIColor)` / `CnctChatColor(Color)`.

## Arabic and right to left

Every word of the interface is in English and Arabic — the [shared table](docs/chat-ui/strings.json),
the same 129 keys in every CNCT SDK, bundled as `Localizable.strings`. `language: .auto` takes the
first of the device's preferred languages that is Arabic or English, else English. A word missing
from Arabic falls back to English, never to its key.

- **Arabic mirrors the whole screen** through SwiftUI's layout direction: header, composer, which
  side the bubbles sit on (the visitor's own are always on the trailing side), the send and chevron
  icons, the upload rings.
- **Each piece of somebody's text takes its own direction** from its first strong character,
  whatever the interface's: an Arabic message in an English chat reads right to left, and the
  reverse. The same goes for names, the greeting, choices, file names and quotes.
- **Phone numbers, emails and web addresses stay left to right** inside Arabic text, so "+973 3311
  2233" never comes out as "2233 3311 +973".
- **Digits are Latin** in Arabic (`ar-u-nu-latn`), as Gulf apps write them. Times and dates are in the
  chat's language and the visitor's own clock.
- Choosing a language never changes the business's own words — the greeting, a flow's text and
  everything the team writes are shown as written.

Your own words for any key, per language:

```swift
CnctChatView(client: chat, strings: CnctChatStrings(
  en: ["writeMessage": "Ask us anything…"],
  ar: ["writeMessage": "اسألنا عن أي شيء…"]
))
```

Three words only a phone needs are outside the shared table, overridable the same way:
`attachPhotos`, `attachCamera` and `attachFiles`, for the attach menu.

## Attachments

The screen's paperclip offers the photo library (several at once), the camera and Files; picked
files wait above the composer with a thumbnail, their size and an upload ring, and send waits for
them. Photos show inline in their own shape and open full screen with pinch to zoom; everything else
is a card that opens in Quick Look. The paperclip is there when the inbox's `chat.allowAttachments`
is.

Headless, it is two steps — upload each file, then send their ids:

```swift
let photo = try await chat.upload(CnctUploadFile(data: data, filename: "IMG_0001.HEIC")) { progress in
  print(progress) // 0…1, per file, on a background queue
}
try await chat.send("Here it is", attachments: [photo])
```

| Limit | |
| ----- | --- |
| Files per message | 10 |
| Size per file | 50 MB |
| Images | `image/jpeg`, `image/png`, `image/webp`, `image/gif` |
| Audio | `audio/aac`, `audio/mpeg`, `audio/ogg`, `audio/mp4`, `audio/amr` |
| Video | `video/mp4`, `video/3gpp`, `video/quicktime` |
| Documents | PDF, Word (`.doc`, `.docx`), Excel (`.xlsx`), `text/plain`, `text/csv` |

**HEIC is not among them**, and an iPhone takes photos in HEIC — so `upload` converts HEIC and HEIF
to JPEG first, and scales any photo over 2560 px on its long side down to it (JPEG at 0.85, never
upscaled, orientation applied, location and other metadata left behind). Everything else is sent
exactly as picked. Then it checks the limits on the device, so a refusal is a sentence before the
upload rather than after a minute of it: `too_many`, `too_large`, `unsupported_type`. The server's
own refusals arrive as `attachments_disabled` (the inbox, or the deployment, takes no files),
`conversation_closed`, `too_large` and `unsupported_type`. `CnctChatAttachments.check` and
`.prepare` are public, for a screen of your own.

## Signed-in users

If your app has accounts, sign the visitor in: their conversations follow them to a new phone, and a
chat they started anonymously before signing in moves across.

```swift
CnctChatView(client: chat, identity: CnctChatIdentity(
  userId: user.id,
  userHash: hashFromYourServer,   // never computed in the app
  name: user.firstName,
  email: user.email
))
```

Headless, it is `try await chat.identify(identity)`, then `resume()`. A failed identify — `409` when
the inbox has no identity secret set up, `401` when the hash does not verify — leaves the visitor in
an ordinary anonymous chat; the screen logs it for you and carries on.

`userHash` is `HMAC-SHA256(userId, the inbox's identity secret)` in lowercase hex, and it is
**computed on your own server**:

```js
// Node, on your server. The secret is in the CNCT console, in the inbox's settings.
import { createHmac } from 'node:crypto';

app.get('/cnct-identity', requireSignedIn, (req, res) => {
  const userId = String(req.user.id);
  const userHash = createHmac('sha256', process.env.CNCT_IDENTITY_SECRET)
    .update(userId)
    .digest('hex');
  res.json({ userId, userHash, name: req.user.firstName, email: req.user.email });
});
```

> **The identity secret never goes in an app.** It is what stops anybody from claiming to be
> anybody: whoever holds it can sign in as any of your users. An app binary is not a place to keep a
> secret — it is unpacked in minutes. The app asks your server for the hash once the user has signed
> in, and passes it on.

Printing a `CnctChatIdentity` never prints the hash.

## Accessibility

Every text scales with Dynamic Type, to the largest sizes. Every control and message has a VoiceOver
label in the chat's language — "Sara: Thanks, here is your invoice.", "You: Photo, photo.jpg,
1.2 MB" — and touch targets are 44 points. The default colours keep text at 4.5:1 or better in light
and dark. On a phone the composer rides above the keyboard, and the newest message stays in sight
when the keyboard opens.

---

# The headless client

Everything below is `CNCT`: the client the screen is built on, for an app that draws its own.

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

A visitor is anonymous until they volunteer a phone number or your app signs them in. If your app
has already signed this person in, use [`identify`](#signed-in-users) — their conversations then
follow them between devices. Without identity verification set up, **pass the number you hold**: it
is the difference between a thread that joins their history and one that starts a second record for
them.

```swift
try await chat.start(displayName: user.name, phone: user.phone)
```

### Files

Attachments are served only to the visitor's own session, so a plain `AsyncImage` would be refused.
`chat.downloadAttachment(id)` answers the bytes and keeps them in memory by id;
`chat.attachmentRequest(id)` answers a `URLRequest` carrying the session header, for an image loader
of your own. Sending is [`upload` then `send`](#attachments).

### The rest of the visitor API

```swift
try await chat.ensureSession()                    // for an inbox that lets visitors type first
let past = try await chat.conversations()         // up to 50, newest first, each with its last message
let one = try await chat.conversation(past[0].id) // with its messages
try await chat.choose(flow.choices[0])            // a flow's choice: its title, with its id as replyId
await chat.read()                                 // the team's reply is on screen; each reply once
try await chat.rate(5, comment: "Quick and kind") // once the conversation has closed
try await chat.updateProfile(displayName: "Layla")
```

`state.inbox` carries the console's `widget` settings, the `team` and the `availability`;
`availability.line` is the "usually replies in a few minutes" sentence, as a value. Messages carry
their `sender` (a first name and a face), `flow` (choices to tap, with `replyId`), `suggestions`
and `replyTo`; `state.awaitingFlow`, `offeredSuggestions` and `seenMessageId` say which to show.
`chat.message.updated` and `chat.read` arrive as `.messageUpdated` and `.read` events, already in
`state`.

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

[`Examples/ChatDemo`](Examples/ChatDemo) is an app with three tabs: **Chat** (`CnctChatView`),
**Your own UI** (a SwiftUI screen on the headless client), and **Settings** — switches for the
language, the appearance and the custom theme, and a **fixture mode** that plays the scripted
conversation with no key and no network. It builds against the package in this repository, so it is
always the SDK as it is on the branch.

```sh
open Examples/ChatDemo/ChatDemo.xcodeproj   # runs in fixture mode with no key
echo 'CNCT_PUBLIC_KEY = your-inbox-public-key' > Examples/ChatDemo/Local.xcconfig   # a real inbox
```

See its [README](Examples/ChatDemo/README.md).

## Development

```sh
swift test                                                    # macOS or Linux, no simulator
xcodebuild test -scheme CNCT-Package -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -project Examples/ChatDemo/ChatDemo.xcodeproj -scheme ChatDemo \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
python3 scripts/generate-strings.py                           # after changing docs/chat-ui/strings.json
```

The tests run against fakes — a `URLProtocol` that answers HTTP, and a fake socket — so the suite is
offline. One suite opens a real WebSocket on the loopback interface to prove the URLSession socket,
close codes included; the Keychain suite skips itself where the test process has no Keychain. The
screen's theme, words, text direction and rows are tested everywhere the headless client is; the
screen itself is tested on the simulator, where `ScreenshotTests` also renders the scripted
conversation — `{en, ar} × {light, dark}`, `{en, ar}` with a custom theme, and `{en, ar}` ended, at the
name form and at the largest text size — to
`$CNCT_SCREENSHOTS_DIR` (pass it to `xcodebuild` as `TEST_RUNNER_CNCT_SCREENSHOTS_DIR`), or to
`cnct-screenshots` in the simulator's temporary directory.

CI runs all of it on every pull request and uploads the PNGs as the **`screenshots`** artifact. A tag
`vX.Y.Z` must match `CnctConfig.sdkVersion` and the CHANGELOG, or the release workflow refuses it.

## Versioning

Semantic. Anything that changes the shape of a client's calls is a major, and the platform's own
`/sdk/v1/` promise is the one this mirrors: what a client ships is what their users run, and we
cannot deploy to it.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
