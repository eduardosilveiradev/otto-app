# Score sheet, 16 Nov 2026

Otto's iPhone app against five rival assistant apps, 1–10 per axis. Rival scores come from the
notes in this folder (official docs, App Store listings, launch coverage, reviews). None of the
rivals' screens could be seen first-hand, so a `~` marks a score resting on thin evidence:
"nothing found" scores 5 or lower, never higher. Otto's come from its own screens on the
simulator (light and dark) and its code.

What the names turned out to be: "Grokbot" is xAI's **Grok Bot** (App Store id6794501026, about
92% sure); "GPT Dots" is OpenAI's **ChatGPT dots**; "Muse Agent" is Meta's **Muse**; "OpenBot" is
**openbot.run** by nightly-labs (about 85% sure); "Claude Duet" is Anthropic's research preview.

Axes that only partly fit Otto: the four cloud agents run on a computer of their own, so "keeps
working with every device off" doesn't apply to an assistant that lives on your Mac (OpenBot
shares that). Push needs APNs, which the free signing team can't have; the server's Bark push
covers it.

## Before

| Axis | Otto | Grok Bot | ChatGPT dots | Muse | Claude Duet | OpenBot |
| --- | --- | --- | --- | --- | --- | --- |
| First run and pairing | 8 | 7 | 6 | 7 | 5 | 7 |
| Thread and composer | 9 | 8 | 6 | 7 | 6 | 7 |
| Voice | 8 | 8 | 7 | 8 | 6~ | 5 |
| Thinking and working | 9 | 7 | 6 | 8 | 4 | 6 |
| Background work and notifications | 8 | 9 | 8 | 8 | 7 | 6 |
| Memory | 8 | 7 | 6~ | 8 | 5 | 4~ |
| Approvals and trust | 7 | 9 | 8 | 9 | 8 | 5~ |
| System integration | 8 | 8 | 7 | 2~ | 5 | 4 |
| Motion and haptics | 9 | 5~ | 5~ | 7 | 5~ | 4~ |
| Visual craft | 9 | 6~ | 7~ | 8 | 6~ | 5~ |
| Empty, error and offline states | 8 | 7 | 4~ | 5 | 4~ | 4~ |
| Perceived speed | 8 | 7 | 6~ | 6 | 4 | 6~ |

### Why

**First run.** Otto: QR pairing with a typed fallback and a sample-data mode, then six short steps (notifications, Siri, share sheet, staying connected); the empty thread after is a bare "Say hi". Grok Bot: sign-in, a tour, pick a first Bot, a wait while its computer is set up, behind a paywall. Dots: name and colour the dot, connect apps; sources disagree on whether the phone can set one up. Muse: a mascot walks through the main parts and Ideas gives starter prompts, but a card is required at signup and connect nudges repeat. Duet: waitlist waves, and the invite email has to match the Apple ID. OpenBot: a two-minute, single-use QR from the desktop, revocable at once.

**Thread and composer.** Otto: Messages-faithful swipe to reply, tapbacks, quotes, photos, voice notes both ways, pull-down search, drafts with Send and Discard. Grok Bot: saved drafts, @mentions, threaded replies, a new message redirects the turn. Dots: one thread buried in the sidebar, no search in it. Muse: one thread plus side chats, emoji acknowledgements. Duet: thread plus channels; an early user found it busy with cards. OpenBot: @ picker for skills, pins, search.

**Voice.** Otto: hold-to-talk walkie, voice notes, web calls, Siri that answers out loud. Grok Bot: calls with live transcript and speed, a card with transcript and rating when they end. Dots: call button, type during a call. Muse: real-time interruptible voice with an animated avatar while tasks keep running. Duet: hold-to-talk and spoken conversations per the listing, transcription only per DataCamp. OpenBot: basic voice conversations and a speak-aloud button.

**Thinking and working.** Otto: a thinking face that changes with the step, the live step line, a to-do list in the bubble, a live tile of the page Otto has open in Chrome, and the step line over the composer when the bubble is scrolled away (it can't be tapped). Grok Bot: a "Thinking" indicator, tool activity in the transcript, a live view of its computer you can take over. Dots: watch or take over the cloud browser; nothing in-thread found. Muse: a one-line snippet of the current work that opens the full activity log. Duet: no live view at all. OpenBot: a Live Activity for running agents.

**Background work and notifications.** Otto: the Mac works on with the phone locked; server push through Bark, local notifications with inline Reply, a keep-awake mode for instant ones, reminders scheduled on the phone, nothing re-notified once read on the Mac. Grok Bot: per-Bot push, finished replies skip the phone while the desktop is in use. Dots: routine progress quiet, decisions loud. Muse: decides what is worth a ping. Duet: posts back plus a notification, but checks accounts only every few hours. OpenBot: needs the computer on; per-agent mute.

**Memory.** Otto: a Memory page with search, topics and the summary, and "Remembered" chips in the thread with Forget it. Grok Bot: "Saved to memory" confirmations and import, no list on the phone. Dots: saved notes with no UI found. Muse: memory as editable text, and "forget" in chat. Duet: inherits Claude's memory, can't be viewed or edited. OpenBot: server-side only.

**Approvals and trust.** Otto: a sheet behind Face ID for payments (every line, the card, the caveats, a printed receipt) and for changes to its core (each file, its tier and a few lines). But Later hides one with no way back until the app relaunches, and the Mac's 30-minute clock never shows, so one can lapse unseen. Grok Bot: inline cards with a warning line, Allow once / Always allow / Deny, a visible expiry, background sends held as drafts. Dots: allow / ask / block rules per action, money and passwords always handed back. Muse: once / this task / this site / always / deny, with details first. Duet: shows destination, content and every recipient; an approval it can't get comes back later. OpenBot: long approvals reach the phone whole; no visuals found.

**System integration.** Otto: Siri asks and answers aloud, saves places, starts the walkie, files photos and Wallet payments; share sheet; its own keyboard; Action Button through Shortcuts. No widget or Live Activity. Grok Bot: Shortcuts, Live Activities for dictation and calls, Action Button toggles a call. Dots: a small widget with message and voice buttons, three Shortcuts actions. Muse: nothing found beyond WhatsApp. Duet: a widget of open tasks, share sheet. OpenBot: a Live Activity only.

**Motion and haptics.** Otto: bubble morphs measured off Messages recordings, the moving face, haptics on send, tapbacks, walkie and quiz answers, a Reduce Motion path for each. Muse: an expressive avatar reviewers singled out. The rest: a haptics toggle or nothing found.

**Visual craft.** Otto: native Liquid Glass, one accent, tangerine only for what needs you, both appearances. Muse: called the best-designed personal agent. The rest: no screens seen; Duet's thread was called busy.

**Empty, error and offline.** Otto: "Will send when back online", "Couldn't load · Retry", pairing and server-check errors, the face asleep while the Mac is out of reach. Grok Bot: Try Again, a Reconnect card, Check price again, Voice chat failed. Muse: failures reported in reviews, take control as the escape hatch. Dots, Duet, OpenBot: none described.

**Perceived speed.** Otto: the thread opens from disk at once, sends morph out of the field immediately. Grok Bot: an update for faster sends and replies. Muse: slow shopping tasks. Duet: "so slow", by design checks every few hours.

## After

Otto rescored from this branch's screens and code. The rivals' apps didn't change, so neither did
their scores; the two council seats scored them too (see the PR), mostly a point lower on the
evidence-thin axes.

| Axis | Otto before → after | Grok Bot | ChatGPT dots | Muse | Claude Duet | OpenBot |
| --- | --- | --- | --- | --- | --- | --- |
| First run and pairing | 8 → 8 | 7 | 6 | 7 | 5 | 7 |
| Thread and composer | 9 → 9 | 8 | 6 | 7 | 6 | 7 |
| Voice | 8 → 9 | 8 | 7 | 8 | 6~ | 5 |
| Thinking and working | 9 → 9 | 7 | 6 | 8 | 4 | 6 |
| Background work and notifications | 8 → 8 | 9 | 8 | 8 | 7 | 6 |
| Memory | 8 → 8 | 7 | 6~ | 8 | 5 | 4~ |
| Approvals and trust | 7 → 9 | 9 | 8 | 9 | 8 | 5~ |
| System integration | 8 → 9 | 8 | 7 | 2~ | 5 | 4 |
| Motion and haptics | 9 → 9 | 5~ | 5~ | 7 | 5~ | 4~ |
| Visual craft | 9 → 9 | 6~ | 7~ | 8 | 6~ | 5~ |
| Empty, error and offline states | 8 → 9 | 7 | 4~ | 5 | 4~ | 4~ |
| Perceived speed | 8 → 8 | 7 | 6~ | 6 | 4 | 6~ |

### What moved

**Voice, 8 → 9.** A web call shows on the Lock Screen and in the Dynamic Island with Mute and Hang
up; the Action Button starts or ends one; the walkie-talkie is a Control Center control and a Lock
Screen widget.

**Approvals, 7 → 9.** Later keeps an approval in a pill over the composer with the minutes the Mac
still holds it; tapping it reopens the sheet. The sheet says when it expires, a lapsed one says so,
and the payment sheet shows the card and "Before you pay" under the amount, so both are on screen
when Face ID approves. Level with Grok Bot and Muse; scopes like theirs ("always allow") need the server.

**System integration, 8 → 9.** A Home Screen and Lock Screen widget that says when an approval is
waiting (what it asks is hidden while locked), the walkie in Control Center, the call's Live
Activity, and a "Call Otto" shortcut. All of them open through one door into the app.

**Empty, error and offline, 8 → 9.** "Can't reach your Mac" under the name after 3 seconds out of
reach, an empty thread that says what to check, and Memory pages that say when search is running,
couldn't reach the Mac, found nothing, or there's nothing yet.

**Unchanged.** Background work stays at 8: the cloud agents keep working with every device off, and
what Otto's phone learns while suspended still comes through Bark (an approval decided on the Mac
can't clear the widget until the app runs). Memory stays at 8: forgetting from the page goes through
Otto in the chat, since there's no route to do it directly. Speed was measured this time and didn't
change (Release builds, same simulator, alternating with main).
