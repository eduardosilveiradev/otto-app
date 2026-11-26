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
- Coding jobs Otto hands to an agent on the Mac: a card under the message that
  started each one, and a sheet to answer its question, steer or stop it, and
  merge its pull request
- Otto's helpers (the subagents it hands parts of a job to): a row each in
  the typing bubble with what it's doing and for how long. If they're still
  going after Otto replies, a small "3 working" capsule over the composer
  opens them in a sheet. Waiting on the server's `helpers` frame; until a
  server sends it, nothing new shows
- The day at a glance: calendar, inbox, open loops, armed triggers
- The web dashboard's pages, in the contact card: loops and tonight's hygiene
  pass, memory (search, topics, the summary), people, money, trips, activity,
  status and paired devices. They read the server's `/app/dash/*` API with the
  app's own token.
- People in iPhone Search: once the People page has loaded, type a name in
  Search to see who that person is to you (relationship, where they work, their
  city). Their notes and memories stay out of it. Tap the result to open their
  page. They leave Search when you forget a memory (until People loads again),
  when the Mac revokes this phone's token, and when the app is paired with
  another Mac or none
- Web calls to Otto through [Vapi](https://vapi.ai), if you have it set up
- Local notifications while the app is in the background
- Talk mode: hands-free voice with Otto. You talk, a pause ends your turn,
  Otto answers out loud, and talking over it cuts it off. Each turn streams to
  the Mac as you talk, so your words show as it hears them and Otto's voice
  plays as it's made; with a Mac that has no talk stream, or a dropped
  connection, the turn goes up as a voice note instead. Open it from the phone button's menu (a tap then opens whichever
  of Call Otto and Talk you picked last), the "Talk with Otto" shortcut on the
  Action Button, the Lock Screen widget or the Control Center control
- Widgets: a small one for the Home Screen that opens the chat and shows an
  approval waiting on you, and a round one for the Lock Screen that opens talk
  mode. "Arriving today", on the Home Screen or the Lock Screen, shows a
  package that's out for delivery or due today and who's bringing it, never
  its tracking number. A tap opens Packages; it clears once the package is
  marked delivered, or at midnight. A web call or a talk shows on the Lock
  Screen and in the Dynamic Island while it lasts. So does a flight leaving
  today, with its gate, terminal, seat and a countdown. It picks up any delay
  or gate change the app hears of, and goes an hour after departure
- An approval put off with Later waits over the composer with the time the
  Mac still holds it
- PDFs: shared from any app, or from the composer's + menu; they go as
  pictures of their pages
- Pairing from a link: an `otto://pair` link tapped anywhere (the Camera's QR
  banner, a message), pasted into the card's address field, or scanned there.
  A link that opened the app from outside always asks before it's used
- A web call leaves a line in the thread with how long it ran; tap it for
  what was said. During the call, tap the caption for the same
- Voice notes play at 1×, 1.5× or 2×
- A schedule's page has Change and Stop: both open the chat with the words
  ready, since Otto is the one who changes its schedules
- What you were typing is still in the box after the app is closed
- Built here and waiting on the server
  (`design/hillclimb-2026-11-16/server-contract.md`): a yes that lasts for the
  task or for good, with a page in the contact card to take it back; who a
  message Otto wants to send goes to, on its approval; approvals kept right
  while the phone was asleep; Forget on a memory's page without a chat
  message; the app's own alert for an approval; taking over the page Otto
  has open in Chrome when it's stuck at a sign-in; and Stop on the bubble
  that shows what Otto is doing. Until the server sends
  them, none of these shows. `Scripts/contract-server.ts` stands in for that
  server on the simulator.
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

Optional, also in the contact card: a phone number for Otto's line, and under
"Calls in the app" the Vapi public key and assistant id that in-app calls
need. `ownerNumber` (for caller recognition) is still read from the app's
defaults only.

## How it talks to the server

Everything goes through `LiveBackend.swift`: a websocket at `/app` plus a few
HTTP endpoints, all with `Authorization: Bearer <token>`. The wire protocol is
documented at the top of that file and in the "App transport" block in
`otto/server.ts`.
It is not stable yet.

## Debug launch flags

Debug builds accept a few arguments for checking layout without a server:
`-seedThread`, `-thinking`, `-keyboardDemo`, `-growDraft`, `-seedDraft`,
`-seedAttachments`, `-approvalDemo` (an approval sheet; `-approvalDemo scopes` for one
that offers a longer yes, `-approvalScope always` to open with it picked,
`-approvalDemo draft` for an email to approve), `-jobsThread` (coding jobs; `-jobsThread worst` for the
awkward ones, `-jobOpen <id>` to open one), `-helpers <live|after|mixed|one|eight|worst|sequence>`
(Otto's helpers; `-helpersOpen` opens their sheet, `-helpersStepsOpen` one row's steps, `sequence`
plays a turn through), and `-details -screen <Loops|Memory|People|Money|Trips|Activity|Status|Devices|Rules>`
to open the contact card on one of its pages, or `-details -checkServer` to open it on the
server fields and check them. For recording motion: `-faceBeat glance` or `-faceBeat cheer` (Otto's face
does that on every idle beat), `-drowsy YES` or `NO` (the quiet-hours face, whatever the clock says),
`-quickReply` (the sample backend answers a message in 1.5 s) and, with `-jobsThread`, `-jobsMerge`
(the running job merges 8 s in). `-openPerson <name>` opens a person's page as a tap in iPhone Search
does (`-openPersonAfter 5` waits that long first).

A Release build with `OTHER_SWIFT_FLAGS='$(inherited) -DPERFDEMO'` also takes `-perfDemo`
(sends, typing steps, tapbacks and replies in a loop, then prints how many frames ran late)
and `-scrollDemo` (pages up the thread and back, printing the window). Run either with
`xcrun simctl launch --console-pty`.

## License

MIT, see [LICENSE](LICENSE).
