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
- The web dashboard's pages, in the contact card: loops and tonight's hygiene
  pass, memory (search, topics, the summary), people, money, trips, activity,
  status and paired devices. They read the server's `/app/dash/*` API with the
  app's own token.
- Web calls to Otto through [Vapi](https://vapi.ai), if you have it set up
- Local notifications while the app is in the background
- Siri: "Ask Otto" answers out loud, and anything that would change something
  opens the chat on its confirm buttons. "Save this place in Otto" saves where
  you are with what you say about it. "Snap to Otto" files a photo (homework,
  a receipt, anything to keep): it's a Shortcuts action, so put Take Photo
  before it and give the shortcut a name or the Action Button.

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
3. The first launch walks you through setup. To pair, run
   `bun otto/apptokens.ts new iPhone --server https://your-mac.your-tailnet.ts.net`
   on the server and scan the QR code it opens (or paste its `otto://pair` link,
   or type the URL and token in). Later changes go in Otto's contact card.

Optional, also in the contact card: a phone number for Otto's line. In-app
calls need a Vapi public key and assistant id, which have no settings screen
yet: they are read from the app's defaults (`vapiPublicKey`,
`vapiAssistantId`, and `ownerNumber` for caller recognition).

## How it talks to the server

Everything goes through `LiveBackend.swift`: a websocket at `/app` plus a few
HTTP endpoints, all with `Authorization: Bearer <token>`. The wire protocol is
documented at the top of that file and in the "App transport" block in
`otto/server.ts`.
It is not stable yet.

## Debug launch flags

Debug builds accept a few arguments for checking layout without a server:
`-seedThread`, `-thinking`, `-keyboardDemo`, `-growDraft`, `-seedDraft`,
`-seedAttachments`, and `-details -screen <Loops|Memory|People|Money|Trips|Activity|Status|Devices>`
to open the contact card on one of its pages.

A Release build with `OTHER_SWIFT_FLAGS='$(inherited) -DPERFDEMO'` also takes `-perfDemo`
(sends, typing steps, tapbacks and replies in a loop, then prints how many frames ran late)
and `-scrollDemo` (pages up the thread and back, printing the window). Run either with
`xcrun simctl launch --console-pty`.

## License

MIT, see [LICENSE](LICENSE).
