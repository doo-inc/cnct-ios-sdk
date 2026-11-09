# ChatDemo

The CNCT SDK in an app: the ready-made chat screen, a screen of your own on the headless client, and
the switches that show what the screen does.

| Tab | What it is |
| --- | --- |
| **Chat** | `CnctChatView` — the whole integration is one view |
| **Your own UI** | A SwiftUI screen built on the headless `CnctChatClient`, for an app with a design system of its own |
| **Settings** | Language (device, English, Arabic), appearance (the console's, the device's, light, dark), the custom theme, and the scripted conversation |

| File | What it is |
| --- | --- |
| [`ChatDemoApp.swift`](ChatDemo/ChatDemoApp.swift) | Reads the key and host from the build, makes the client once, and lays out the tabs |
| [`DemoSettings.swift`](ChatDemo/DemoSettings.swift) | The switches |
| [`ChatModel.swift`](ChatDemo/ChatModel.swift) | The `@Observable` wrapper a screen of your own wants: `states` and `events` into a model |
| [`ChatScreen.swift`](ChatDemo/ChatScreen.swift) | That screen: status line, transcript, cards, attachments, retry, typing, composer |

## Run it

```sh
open Examples/ChatDemo/ChatDemo.xcodeproj
```

Run the **ChatDemo** scheme on a simulator. **With no key it plays the scripted conversation** —
`CnctChatFixture`, the same one the SDK's screenshots are rendered from — with no network at all:
the greeting, a question, the assistant's answer with choices, a photo, a reply with an invoice, a
line with a phone number in it, a message that failed, the team typing, and two files in the
composer. Anything you send is echoed back as stored.

To chat with your own inbox, put its public key in `Local.xcconfig`, which git ignores:

```sh
echo 'CNCT_PUBLIC_KEY = your-inbox-public-key' > Examples/ChatDemo/Local.xcconfig
```

The scripted conversation is then a switch in **Settings**. Without a host the app talks to CNCT
production, `https://app.doo.ooo`. To point it somewhere else, add `CNCT_BASE_URL` to
`Local.xcconfig`. An xcconfig reads `//` as the start of a comment, so write the URL with an empty
variable between the slashes:

```
CNCT_BASE_URL = http:/$()/localhost:3001
```

Both are ordinary build settings, so a CI build can pass them instead:
`xcodebuild … CNCT_PUBLIC_KEY=your-inbox-public-key`.

## What it shows

- **One view is the integration.** `CnctChatView(client:theme:language:)`; everything else on the
  Chat tab is the console's settings, or the switches overriding them.
- **Arabic is the whole screen, mirrored**, and each message keeps its own direction.
- **The custom theme** is `CnctChatFixture.customTheme`: `#D7262E`, corner radius 8, Georgia and a
  logo of its own.
- **Your own UI is the same client.** The headless tab renders `CnctChatState` and nothing else, with
  failed words kept on screen for a retry and cards that degrade to their `body`.
- **The visitor comes back.** On a real inbox the token is in the Keychain, so a relaunch picks up
  their own thread.

The app sets `NSCameraUsageDescription`, which an app offering the camera needs; the photo library
and Files need no permission. It needs Xcode 16 and iOS 17 (for `@Observable` and
`ContentUnavailableView`); the SDK itself needs only iOS 15. The project refers to the package at
the repository root, so it always builds against the SDK as it is on your branch, and CI builds it
on every pull request.
