# cnct-ios-sdk — working notes

The native iOS SDK for CNCT. Swift Package, product and module `CNCT`, no dependencies, iOS 15 /
macOS 12, Swift 6 language mode (strict concurrency — everything public is `Sendable`).

## What it is

A **headless** port of the Flutter SDK. Same concepts, same names with a `Cnct` prefix, same error
codes verbatim. No UI in the library — an example app shows how to build one.

**The reference implementation is `doo-inc/cnct-flutter-sdk` (public).** Clone it and port from it
behaviour for behaviour, test for test:

```sh
git clone https://github.com/doo-inc/cnct-flutter-sdk.git ../cnct-flutter-sdk
```

`doo-inc/cnct-web-sdk` (public) is the second reference, for anything the Dart is unclear about.
The Android twin is `doo-inc/cnct-android-sdk`; keep the two public surfaces parallel.

## What is here (tested)

`CnctConfig` / `CnctHosts`, `CnctChatPublicKey` / `CnctApiKey` / `CnctKeyMode`, `Cnct` /
`CnctModule`, `CnctError` / `CnctErrorCode`, `CnctJSON`, `CnctTokenStore` + memory store,
`CnctTransport` (URLSession, the Flutter transport's error mapping). Build on these — do not add a
second HTTP path or a second error type.

## What is left to build

1. **Chat client** — port `lib/src/chat/` (`chat_client.dart`, `chat_models.dart`,
   `chat_events.dart`, `chat_state.dart`) and `test/chat_client_test.dart`.
   - `boot`, `start`, `resume`, `send`, `retry`, `typing`, `end`, `downloadAttachment`, `connect`,
     `disconnect`, `dispose`; `state`, `states`, `events`, `hasSession`.
   - Make the client an `actor` (or `@MainActor`-free final class with a lock). Expose states and
     events as `AsyncStream`s; consider an `@Observable` wrapper only in the example app.
   - Socket: `URLSessionWebSocketTask` at `socketBaseURL` + `/ws/chat`. Put it behind a protocol
     (the Flutter `CnctSocketFactory`) so tests drive a fake socket without a server.
   - Keep the load-bearing behaviours: a reconnect **reloads the transcript**; every send carries a
     `clientKey` (idempotent); sends go over the socket when the handshake `accepts` `send`, else
     HTTP; the visitor token rides on `x-chat-token`, never `Authorization`; an unauthenticated
     answer clears the stored token.
2. **Agent client** — port `lib/src/agent/` and `test/agent_client_test.dart`: `catalogue()`,
   `bookings` (`services`, `people`, `checkAvailability`, `create`, `forCustomer`, `reschedule`,
   `cancel`), `tickets` (`types`, `type`, `create`, `forCustomer`, `get`, `addTo`). Calls
   `/api/tools`. A 200 with an `error` key is `CnctErrorCode.toolRefused`. Models carry `sandbox`.
3. **`CnctKeychainTokenStore`** — Keychain generic-password, `kSecAttrAccessibleAfterFirstUnlock`,
   service name configurable. Test it only where the Keychain is available (skip on CI if it is
   not); do not let a flaky Keychain test block the suite.
4. **Entry points** — `Cnct.chat(_:tokenStore:storageKey:)`, `Cnct.agent(_:)`, `Cnct.client(for:)`.
5. **Example app** — `Examples/ChatDemo`, SwiftUI, a complete chat screen on the headless client in
   a few hundred lines, Keychain token store, public key from a build setting. Not part of the
   package product.
6. **Docs** — README sections for chat, bookings, tickets (mirror the Flutter README), CHANGELOG.

Newer visitor features on the server (past conversations, ratings, identity verification, visitor
uploads, "Seen") are **not** in the Flutter SDK yet. Parity with Flutter 0.2.0 first; list those as
follow-ups in the PR rather than inventing their wire format.

## Rules

- Comments say **why**, in full sentences, in the voice of the Flutter SDK's doc comments. Port
  them, adapted to Swift; do not drop them.
- Never print a secret. Credentials redact themselves; keep it that way in every new type that holds
  one (session tokens included).
- Error codes are the server's strings. Never rename one.
- `swift test` must pass on macOS and `xcodebuild test` on an iOS Simulator — CI runs both. If you
  have no Xcode (a Linux cloud box), push the branch and read the CI result; do not claim a pass you
  did not see.
- Bump `CnctConfig.sdkVersion` and the CHANGELOG together. Do not tag — releases are Isa's call.
- Open a pull request into `main`; do not merge it.
