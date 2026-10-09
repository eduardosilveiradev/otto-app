# Otto for iOS

> [!WARNING]
> **Very early beta.** This is a personal project that changes daily. Expect
> rough edges, breaking changes to the wire protocol, and features that only
> half work. There are no releases, no App Store build, and no support.
> Don't rely on it for anything important.

The iPhone app for [Otto](https://github.com/eduardosilveiradev/otto), a
proactive personal assistant that runs as a Claude Code channel on your Mac.
It is one Messages-style conversation with Otto, plus a contact card that shows
what Otto knows about your day.

## What works (mostly)

- Text, photos and voice notes to Otto; Otto's replies, photos, files and
  spoken replies back
- Swipe to reply, long-press for tapbacks, double-tap for a quick ❤️
- A live status line in the typing bubble while Otto works, and
  Delivered / Read receipts
- Otto's one-tap buttons
- The day at a glance: calendar, inbox, open loops, armed triggers
- Web calls to Otto through [Vapi](https://vapi.ai), if you have it set up
- Local notifications while the app is in the background

## Requirements

- An Otto server (`otto/server.ts` from the Otto repo) with the webhook
  listener enabled, reachable from your phone, for example over
  [Tailscale](https://tailscale.com)
- A device token: `bun otto/apptokens.ts new <device-name>` on the server
- Xcode 26 or later, iOS 26 or later (the UI uses Liquid Glass)

Without a server URL and token the app runs on built-in mock data, which is
handy for poking at the UI.

## Setup

1. Open `Otto.xcodeproj`, pick your own team under Signing & Capabilities,
   and change the bundle identifier (`dev.otto.app`) to one you own.
2. Run it on your phone.
3. Tap Otto's name, then enter the server URL (for example
   `https://your-mac.your-tailnet.ts.net`) and the token.

Optional, also in the contact card: a phone number for Otto's line. In-app
calls need a Vapi public key and assistant id, which have no settings screen
yet: they are read from the app's defaults (`vapiPublicKey`,
`vapiAssistantId`, and `ownerNumber` for caller recognition).

## How it talks to the server

Everything goes through `LiveBackend.swift`: a websocket at `/app` plus a few
HTTP endpoints, all with `Authorization: Bearer <token>`. The wire protocol is
documented at the top of that file and in the "App transport" block in
`otto/server.ts`. It is not stable yet.

## Debug launch flags

Debug builds accept a few arguments for checking layout without a server:
`-seedThread`, `-thinking`, `-keyboardDemo`, `-growDraft`, `-seedDraft`,
`-seedAttachments`.

A Release build with `OTHER_SWIFT_FLAGS='$(inherited) -DPERFDEMO'` also takes `-perfDemo`
(sends, typing steps, tapbacks and replies in a loop, then prints how many frames ran late)
and `-scrollDemo` (pages up the thread and back, printing the window). Run either with
`xcrun simctl launch --console-pty`.

## License

MIT, see [LICENSE](LICENSE).
