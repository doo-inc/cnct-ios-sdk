# Changelog

## Unreleased — 0.1.0

- The foundation, matching the Flutter and web SDKs at 0.2.0: `Cnct`, `CnctConfig` (production
  `https://app.doo.ooo` by default, path prefixes kept, the socket origin derived), `CnctHosts`,
  `CnctChatPublicKey`, `CnctApiKey` with `CnctKeyMode` (sandbox / production), `CnctModule`,
  `CnctError` with the shared `CnctErrorCode` vocabulary, `CnctJSON`, `CnctTokenStore` with a memory
  store, and `CnctTransport` on URLSession.
- Credentials redact themselves in `print`, `po` and `dump`.
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
