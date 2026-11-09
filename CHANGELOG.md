# Changelog

## Unreleased — 1.0.0

### The rest of the visitor API (`CNCT`)

Everything the hosted chat page does, now in the headless client, so the SDK stops lagging it.

- **The inbox** says how the business set its chat up: `CnctChatInbox.widget` (`CnctChatWidget`:
  brand colour, appearance, logo, language, "Powered by", attachments, "End chat", whether to ask
  for a name first, whether to ask for a rating — merged over the defaults section by section, as
  the server merges), `team` (first names and faces) and `availability` (`CnctChatAvailability`,
  with `line`, the hosted page's honest "usually replies in…" / "back tomorrow at…" sentence as a
  `CnctAvailabilityLine`).
- **The full message**: `sender` (`CnctChatSender`, a first name and a face), `flow`
  (`CnctChatFlow`: words, choices as buttons or a list, footer, media, and `expects` for the
  keyboard), `suggestions`, `replyTo` (`CnctChatQuote`) and `words`. The state says which flow is
  `awaitingFlow`, which `offeredSuggestions` to show, and the `seenMessageId` to write "Seen" under.
- **Attachments, sending**: `upload(_:progress:)` posts one file as `multipart/form-data` (part
  `file`) with per-file progress from a `URLSession` task delegate, after `CnctChatAttachments`
  has made photos ready — **HEIC/HEIF converted to JPEG**, anything over 2560 px scaled down, with
  ImageIO — and checked them: ten files a message, 50 MB a file, the platform's types. Refusals are
  `too_many`, `too_large`, `unsupported_type` (new) and `attachments_disabled` (new, for `403` and
  `503`). `send(_:attachments:replyId:clientKey:)` carries the ids as `attachmentIds`, and the
  optimistic bubble shows the files at once.
- **Attachments, receiving**: `downloadAttachment(_:)` keeps what it fetched in memory by id, and
  `cachedAttachment(_:)` answers without the network — including the files this device just sent.
- **Flow choices**: `send(title, replyId: choice.id)`. A retry sends the same `replyId` and files.
- **Signed-in users**: `identify(_:)` with a `CnctChatIdentity` (`userId`, `userHash` from your
  server, and optional name, email and phone). The current token goes with it, so an anonymous chat
  moves across; the token it answers replaces it. An identity never prints its hash.
- `startIfNeeded()`, for an inbox that lets visitors type first: a message and a file picked in the
  same moment start one conversation.
- `conversations()` and `conversation(_:)` (a `CnctChatTranscript`), `markRead()` (each reply
  reported once) and `markRead(conversationId:)`, `rate(_:comment:conversationId:)`,
  `updateProfile(displayName:phone:)`.
- `CnctChatConversation` gains `id`, `closedAt`, `assignee`, `seenAt`, `ratable`, `rating`,
  `lastMessageAt` and `preview`; `CnctChatVisitor` gains `anonymous` and `identified`;
  `CnctConversationStatus` gains `pending`.
- **Socket frames**: `chat.message.updated` replaces a message where it stands
  (`CnctChatEvent.messageUpdated`); `chat.read` records how far the team has read
  (`CnctChatEvent.read`); `chat.conversation.updated` is read in both shapes the server sends and
  moves only the fields it carries. A closed conversation is closed in state at once and then
  learns from the server whether it can be rated.
- Session starts and resumes send the device's IANA `timezone`.
- `CnctTransport.upload(_:body:contentType:headers:progress:)`.

## Unreleased — 0.1.0

- The foundation, matching the Flutter and web SDKs at 0.2.0: `Cnct`, `CnctConfig` (production
  `https://app.doo.ooo` by default, path prefixes kept, the socket origin derived), `CnctHosts`,
  `CnctChatPublicKey`, `CnctApiKey` with `CnctKeyMode` (sandbox / production), `CnctModule`,
  `CnctError` with the shared `CnctErrorCode` vocabulary, `CnctJSON`, `CnctTokenStore` with a memory
  store, and `CnctTransport` on URLSession.
- Credentials redact themselves in `print`, `po` and `dump`, and so do the clients that hold them:
  neither the API key nor a visitor's session token is ever printed.
- Query values are encoded strictly, so a `+` in a phone number is not read as a space.
- **Bookings and tickets** on a `kaer_sk_` API key, ported from the Flutter SDK: `CnctAgentClient`
  (and `Cnct.agent(_:)`) with `catalogue()`, `bookings` (`services`, `people`, `checkAvailability`,
  `create`, `forCustomer`, `reschedule`, `cancel`) and `tickets` (`types`, `type`, `create`,
  `forCustomer`, `get`, `addTo`), all on `/api/tools`. A tool that answers `200` with an `error`
  sentence is raised as `CnctErrorCode.toolRefused`; `call(_:_:)` is the escape hatch that hands it
  back instead, for tools added after this SDK. `CnctBookingConfirmation` and `CnctRaisedTicket`
  carry `sandbox`, and the client carries the key's `mode`.
- **Live chat** on an inbox public key, ported from the Flutter SDK: `CnctChatClient`, an actor, with
  `boot`, `start`, `resume`, `send`, `retry`, `typing`, `end`, `downloadAttachment`,
  `attachmentRequest`, `connect`, `disconnect` and `dispose`; `state`, `states` and `events` (as
  `AsyncStream`s, no `await` needed) and `hasSession`. A reconnect reloads the transcript, every send
  carries an idempotent `clientKey`, sends go over the socket when the handshake accepts `send` and
  over HTTP otherwise, the visitor token rides on `x-chat-token`, and an unauthenticated answer — or
  a 1008 close — clears the stored token. Ticket and booking cards are typed; an unknown card
  degrades to its body.
- The socket is `URLSessionWebSocketTask` behind `CnctSocket` / `CnctSocketFactory`, so a test can
  drive the client with a fake one.
- `Cnct.chat(_:tokenStore:storageKey:)` and `Cnct.client(for:)`, which answers a `CnctClient`.
- `CnctError` is `Hashable`, so `CnctChatState` can be too.
- **`CnctKeychainTokenStore`**: the visitor's session token as a Keychain generic password, readable
  after first unlock, under a configurable service and an optional access group. Its failures are
  `CnctErrorCode.storageFailed` (`storage_failed`), a new client-side code.
- **`Examples/ChatDemo`**, a SwiftUI chat screen on the headless client and the Keychain store,
  built in CI. Not part of the package product.
- The README covers chat, bookings and tickets.
