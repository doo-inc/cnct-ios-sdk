# cnct-ios-sdk — working notes

The native iOS SDK for CNCT. Swift Package with two products and modules, `CNCT` and `CNCTUI`, no
dependencies, iOS 15 / macOS 12, Swift 6 language mode (strict concurrency — everything public in
`CNCT` is `Sendable`).

## What it is

The native iOS SDK for CNCT, in two libraries: **`CNCT`**, the headless client, a port of the
Flutter SDK (same concepts, same names with a `Cnct` prefix, same error codes verbatim); and
**`CNCTUI`**, a ready-made, brandable chat screen on top of it. The UI is built only on `CNCT`'s
public API — if it needs something the headless client does not expose, add it to the headless
client first.

**The 1.0 contract is `docs/chat-ui/SPEC.md`**, shared word for word with `doo-inc/cnct-web-sdk` and
`doo-inc/cnct-android-sdk`: the same option names, theme tokens and words on all three.
`docs/chat-ui/strings.json` is the English/Arabic table. The behavioural reference for the visitor
API and the screen is CNCT's hosted chat page (`https://app.doo.ooo/chat-assets/chat.js`, or the
`reference/hosted-widget` branch — read it, never merge it, never copy it in).

**The headless reference is `doo-inc/cnct-flutter-sdk` (public).** Clone it and port from it
behaviour for behaviour, test for test:

```sh
git clone https://github.com/doo-inc/cnct-flutter-sdk.git ../cnct-flutter-sdk
```

`doo-inc/cnct-web-sdk` (public) is the second reference, for anything the Dart is unclear about.
The Android twin is `doo-inc/cnct-android-sdk`; keep the public surfaces parallel.

## What is here (tested)

`CnctConfig` / `CnctHosts`, `CnctChatPublicKey` / `CnctApiKey` / `CnctKeyMode`, `Cnct` /
`CnctModule` / `CnctClient`, `CnctError` / `CnctErrorCode`, `CnctJSON`, `CnctTokenStore` + memory
store + `CnctKeychainTokenStore`, `CnctTransport` (URLSession, the Flutter transport's error mapping,
and multipart uploads with progress). Build on these — do not add a second HTTP path or a second
error type.

- **Agent client** (`Sources/CNCT/Agent`): `CnctAgentClient` — `catalogue()`, `bookings`, `tickets`,
  `call` / `callOrThrow` on `/api/tools`. Ports `lib/src/agent/` and `test/agent_client_test.dart`.
- **Chat client** (`Sources/CNCT/Chat`): `CnctChatClient`, an actor; `state` / `states` / `events`
  are `nonisolated` (`AsyncStream`s via `CnctBroadcast`). The socket is `CnctURLSessionSocket` behind
  `CnctSocket` / `CnctSocketFactory`. Ports `lib/src/chat/` and both chat test files, plus the 1.0
  visitor API from the spec: widget/team/availability, the full message (sender, flow, suggestions,
  replyTo), `upload` (HEIC → JPEG and 2560 px with ImageIO, checks before upload), `identify`,
  `conversations` / `conversation`, `markRead`, `rate`, `updateProfile`, `chat.message.updated`,
  `chat.read`.
- **Chat UI** (`Sources/CNCTUI`): `CnctChatView` / `CnctChatViewController`, `CnctChatTheme`,
  `CnctChatLanguage` / `CnctChatStrings` / `CnctChatWords`, `CnctBidi`, `CnctChatRow` (the thread as
  rows), `CnctChatFixture`. The screen (`Sources/CNCTUI/iOS`) is `#if os(iOS)`; everything else in
  the target builds and is tested on macOS and Linux. `Resources/*.lproj/Localizable.strings` are
  generated from `strings.json` by `scripts/generate-strings.py` — never edit them by hand.
- **Tests**: `Tests/CNCTTests/Support` has `FakeServer` (a `URLProtocol` routed by host, so suites
  run in parallel), `VisitorServer` (the 1.0 visitor API on it), `FakeSocket` / `FakeSocketFactory`,
  `EventLog` and `eventually`. `URLSessionSocketTests` runs a real loopback WebSocket (Network.framework,
  Apple only). The Keychain suite skips itself where the test process has no Keychain (the iOS
  Simulator, in CI). `Tests/CNCTUITests/ScreenshotTests` (XCTest, simulator only) renders the
  fixture to PNGs; CI uploads them as the `screenshots` artifact.
- **Example app**: `Examples/ChatDemo` — Xcode 16 project (synchronized folder, local package
  reference to the repo root), `CnctChatView` with switches for language, appearance and the custom
  theme, a headless tab, and a fixture mode that needs no key. CI builds it.

Where the Swift port deliberately differs from the Dart, the pull requests that added it say why
(doo-inc/cnct-ios-sdk#1, #2, #3), and the 1.0 pull requests (#4, #5, #6) say where it departs from
the spec.

A Linux box can run `swift test` with a swift.org toolchain: everything but the Network, Security,
ImageIO and SwiftUI suites builds there. Linux's libcurl has no WebSocket support, so the real
socket is CI-only.

## What is left

The hosted page's home screen, conversation list, emoji tray and streaming drafts (`chat.draft`) are
not in the UI: the spec asks for the conversation view only. New visitor features belong in the
spec first, so the three SDKs add them together.

## Rules

- Comments say **why**, in full sentences, in the voice of the Flutter SDK's doc comments. Port
  them, adapted to Swift; do not drop them.
- Never print a secret. Credentials redact themselves; keep it that way in every new type that holds
  one (session tokens and identity hashes included).
- Never name a client in the repository, commits or pull requests. Fixtures and themes are generic
  ("Demo Café", "custom").
- Error codes are the server's strings. Never rename one.
- `swift test` must pass on macOS and `xcodebuild test -scheme CNCT-Package` on an iOS Simulator —
  CI runs both. If you have no Xcode (a Linux cloud box), push the branch and read the CI result; do
  not claim a pass you did not see. A UI change is not done until you have looked at the
  `screenshots` artifact.
- The version lives in `CnctConfig.sdkVersion`, the newest CHANGELOG heading and the README's
  install line; `VersionTests` and the release workflow hold them together.
- Bump `CnctConfig.sdkVersion` and the CHANGELOG together. Do not tag — releases are Isa's call.
- Open a pull request into `main`; do not merge it.
