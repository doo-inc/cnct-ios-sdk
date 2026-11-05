# CNCT for iOS

The official CNCT SDK for iOS and Swift. Live chat, bookings and tickets against a CNCT workspace,
using the credentials CNCT issues you.

> **Status: in progress, not released.** The foundation is here and tested — the host, the two
> credentials, the error vocabulary and the HTTP transport. The chat and agent clients are being
> ported from the [Flutter SDK](https://github.com/doo-inc/cnct-flutter-sdk) next. There is no tag
> yet; do not depend on `main`.

**It is headless, and that is the whole point.** There is no view in this package and no web view.
A business building their own app has a design system already; shipping them a chat bubble to
restyle answers a question they did not ask. So this ships state and events, and the interface is
yours. It has no dependencies either: Foundation only.

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

## Errors

Everything fails with `CnctError`. Branch on `code` — it is the server's own code where there is
one, and the same string the web, Flutter and Android SDKs use.

```swift
do {
  // …
} catch let error as CnctError where error.isRetryable {
  // offline, timeout, rate_limited, server_error
} catch let error as CnctError where error.code == .conversationClosed {
  // start a new conversation
}
```

## Development

```sh
swift test                                                   # macOS, no simulator
xcodebuild test -scheme CNCT -destination 'platform=iOS Simulator,name=iPhone 16'
```

CI runs both on every pull request. A tag `vX.Y.Z` must match `CnctConfig.sdkVersion`, or the
release workflow refuses it.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
