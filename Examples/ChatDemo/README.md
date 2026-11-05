# ChatDemo

A complete chat screen on the headless CNCT client, in SwiftUI. Nothing in it comes from the SDK
except state and events: the bubbles, the cards, the composer and the retry button are all this
app's, which is the arrangement.

| File | What it is |
| --- | --- |
| [`ChatDemoApp.swift`](ChatDemo/ChatDemoApp.swift) | Reads the key and host from the build, makes the client once, with the Keychain store |
| [`ChatModel.swift`](ChatDemo/ChatModel.swift) | The `@Observable` wrapper the SDK deliberately does not ship: `states` and `events` into a model |
| [`ChatScreen.swift`](ChatDemo/ChatScreen.swift) | The screen: status line, transcript, cards, attachments, retry, typing, composer |

## Run it

```sh
echo 'CNCT_PUBLIC_KEY = your-inbox-public-key' > Examples/ChatDemo/Local.xcconfig
open Examples/ChatDemo/ChatDemo.xcodeproj
```

Then run the **ChatDemo** scheme on a simulator. `Local.xcconfig` is ignored by git, which is where
a key belongs. The inbox public key is the one credential that is meant to be inside an app, but the
habit of keeping credentials out of source is worth keeping anyway.

Without a host the app talks to CNCT production, `https://app.doo.ooo`. To point it somewhere else,
add `CNCT_BASE_URL` to `Local.xcconfig`. An xcconfig reads `//` as the start of a comment, so write
the URL with an empty variable between the slashes:

```
CNCT_BASE_URL = http:/$()/localhost:3001
```

Both are ordinary build settings, so a CI build can pass them instead:
`xcodebuild … CNCT_PUBLIC_KEY=your-inbox-public-key`.

## What it shows

- **Rendering `state` is rendering the truth.** The screen draws `CnctChatState` and nothing else —
  no local copy of the transcript to keep in step, including straight after a reconnect.
- **The visitor comes back.** The token is in the Keychain, so a relaunch `resume()`s their own
  thread; a first visit starts one.
- **Failed words stay.** A send that fails leaves its bubble on screen with a retry button, and the
  retry cannot double-post.
- **Cards degrade.** Ticket and booking cards are drawn as cards; anything else is drawn as its
  `body`, which always reads as a sentence.
- **Attachments ride on the session.** Images are fetched through `downloadAttachment`, because the
  file is only served to the visitor's own token.

It needs Xcode 16 and iOS 17 (for `@Observable`); the SDK itself needs only iOS 15. The project
refers to the package at the repository root, so it always builds against the SDK as it is on your
branch, and CI builds it on every pull request.
