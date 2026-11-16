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
| Perceived speed | 7 | 7 | 6~ | 6 | 4 | 6~ |

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

**Perceived speed.** Otto: sends morph out of the field immediately. The saved thread is read from disk at launch, but the connecting splash covers it until the socket connects (or 12 s pass offline), so a slow tunnel shows the orb, not the thread. Grok Bot: an update for faster sends and replies. Muse: slow shopping tasks. Duet: "so slow", by design checks every few hours.

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
| Perceived speed | 7 → 7 | 7 | 6~ | 6 | 4 | 6~ |

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
Otto in the chat, since there's no route to do it directly. Speed stays at 7: frame pacing and launch were measured
against main and didn't change, and the launch still waits for the connection behind the splash
(kept on purpose when the crew was removed, `763e3fa`).

## Second run, 16 Nov 2026: a blind council

The first run's scores above were given by reviewers who had been told what changed each round,
and they wandered between 8.5 and 9. This run scored the same twelve axes with two reviewers who
were told nothing: Claude Opus 5.5 (effort xhigh) and GPT-6.1-Sol. Every round was a new review
from one fixed prompt (`council-prompt.md`, sent word for word), over a folder holding only the
current screenshots, the current source, the rival notes and `server-contract.md`. No round number,
no earlier scores, no list of changes.

Each reviewer gave two overall scores. "Overall" counts a server-dependent feature as present when
the app's side is complete and safe against today's server and the contract is exact enough to
build from. "Today" is the app against a server with none of the contract.

| Round | Code reviewed | Opus overall | Opus today | Sol overall | Sol today | Contract items passing (Opus / Sol) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `2fedd46` | 8.7 | 8.3 | 8.0 | 7.3 | 6 of 6 / not noted |
| 2 | `0f83924` | 8.8 | 8.4 | 8.2 | 7.5 | 9 of 10 / 7 of 10 |
| 3 | `9c66c86` | 9.0 | 8.7 | 8.0 | 7.3 | 9 of 11 / 8 of 11 |
| 4 | `8a75f81` | 9.1 | 8.7 | 8.5 | 7.8 | 11 of 11 / 10 of 11 |

Otto's score per axis, each round (Opus / Sol):

| Axis | Round 1 | Round 2 | Round 3 | Round 4 |
| --- | --- | --- | --- | --- |
| First run and pairing | 8.5 / 7.5 | 8.6 / 8.0 | 8.7 / 8 | 7.8 / 8.5 |
| Thread and composer | 9 / 9 | 9.6 / 8.5 | 9.3 / 8.5 | 9.3 / 8.5 |
| Voice | 8.3 / 7 | 8.0 / 7.5 | 9.0 / 8 | 9.0 / 8 |
| Thinking and working | 8.8 / 8 | 9.0 / 8.5 | 9.2 / 8.5 | 9.2 / 10 |
| Background work and notifications | 8.5 / 8 | 8.5 / 8.0 | 8.3 / 8 | 7.8 / 9 |
| Memory | 8.5 / 8 | 10 / 9.0 | 9.2 / 9 | 9.4 / 9 |
| Approvals and trust | 8.8 / 8 | 8.9 / 8.5 | 9.3 / 7.5 | 9.6 / 8 |
| System integration | 9 / 9 | 9.5 / 8.5 | 9.3 / 8.5 | 9.5 / 9 |
| Motion and haptics | 9.2 / 8.5 | 9.2 / 9.0 | 9.5 / 9 | 9.6 / 10 |
| Visual craft | 8.8 / 8.5 | 9.0 / 8.5 | 9.0 / 9 | 9.4 / 10 |
| Empty, error and offline states | 9 / 7.5 | 8.5 / 8.5 | 9.5 / 8.5 | 9.5 / 8.5 |
| Perceived speed | 9.2 / 8 | 9.5 / 8.0 | 9.0 / 8.5 | 9.4 / 8.5 |

A blind reviewer's score moves by a few tenths from round to round on the same axis with no
change behind it (Opus's first-run score fell from 8.7 to 7.8 in round 4 while pairing only got
safer). Read the table for its direction, not its decimals.
