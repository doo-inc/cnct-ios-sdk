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
`CnctModule` / `CnctClient`, `CnctError` / `CnctErrorCode`, `CnctJSON`, `CnctTokenStore` + memory
store + `CnctKeychainTokenStore`, `CnctTransport` (URLSession, the Flutter transport's error mapping).
Build on these — do not add a second HTTP path or a second error type.

- **Agent client** (`Sources/CNCT/Agent`): `CnctAgentClient` — `catalogue()`, `bookings`, `tickets`,
  `call` / `callOrThrow` on `/api/tools`. Ports `lib/src/agent/` and `test/agent_client_test.dart`.
- **Chat client** (`Sources/CNCT/Chat`): `CnctChatClient`, an actor; `state` / `states` / `events`
  are `nonisolated` (`AsyncStream`s via `CnctBroadcast`). The socket is `CnctURLSessionSocket` behind
  `CnctSocket` / `CnctSocketFactory`. Ports `lib/src/chat/` and both chat test files.
- **Tests**: `Tests/CNCTTests/Support` has `FakeServer` (a `URLProtocol` routed by host, so suites
  run in parallel), `FakeSocket` / `FakeSocketFactory`, `EventLog` and `eventually`.
  `URLSessionSocketTests` runs a real loopback WebSocket (Network.framework, Apple only). The
  Keychain suite skips itself where the test process has no Keychain (the iOS Simulator, in CI).
- **Example app**: `Examples/ChatDemo` — Xcode 16 project (synchronized folder, local package
  reference to the repo root), key and host from `Config.xcconfig` / `Local.xcconfig`. CI builds it.

Where the Swift port deliberately differs from the Dart, the pull requests that added it say why
(doo-inc/cnct-ios-sdk#1, #2, #3).

A Linux box can run `swift test` with a swift.org toolchain: everything but the Network and Security
suites builds there. Linux's libcurl has no WebSocket support, so the real socket is CI-only.

## What is left

Newer visitor features on the server (past conversations, ratings, identity verification, visitor
uploads, "Seen") are **not** in the Flutter SDK yet. Port them once Flutter or the web SDK defines
their wire format rather than inventing one here, and keep the Android twin's surface parallel.

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
