# Grokbot (= "Grok Bot", SpaceXAI / xAI + Cursor) - iPhone app notes, 16 Nov 2026

## What "Grokbot" is
- Confidence ~92%: it is **Grok Bot**, a standalone iPhone/iPad/Android/desktop app (App Store id6794501026, separate from the regular Grok app id6670324846) of "AI teammates" with their own cloud computer. Beta launched 11 Aug 2026. [1][2][3]
- Evidence: name match, "message a Bot like texting a colleague", "feeling like iMessage" (Shumer, via VentureBeat), App Store subtitle "AI agents that do real work", 4.9 from ~24K ratings. [1][4]
- Gap: no independent hands-on iPhone review or demo-video transcript found. Almost all UI detail below comes from xAI's own help docs (strong for facts, silent on look and feel). Anything not in a source is marked "not found".

## 1. Screens and navigation
- Home = list of Bots and Group Chats (synced); "+" creates New Bot or New Group Chat; pin/hide chats. [5]
- Global search across Messages, Bots, Group Chats, Files, Routines. [5]
- Tap a Bot's name = its profile: routines (schedule, next run, run history), Library (pages/images/videos/files/links grouped Today / This week / Older), per-Bot notification toggle. [5][6]
- Settings: Connect apps, Bot Computer (reset to snapshot, disk), Manage devices, Usage, Import Memory, Haptics toggle, appearance, time zone. [5]
- Shared cloud computer viewable from a conversation (watch, take over for logins/CAPTCHA, "I'm done" hands back). [5]
- Tab bar / exact layout: not found. Primary Bot gets a star badge (desktop sidebar). [6]

## 2. Chat / composer
- Text, dictation, voice chat, photos, files, @-mentions (Bot, group, routine, app; @everyone in groups), threaded replies, reactions, per-conversation saved drafts. [5][7]
- You can send a new message while work runs; it redirects the current turn. [7]
- Long-press message: Select Text, Add to Chat. [5]
- Buttons inside messages: email/Slack drafts (Send / Discard), voice memo play/pause, phone-call card (Call / Cancel), order card (pay / Cancel, "Check price again" when expired), "Reconnect" card for signed-out apps (max once a day). [6][7]
- Share sheet: photos, files, links, text from other apps; fallback "Open in Grok Bot". [5]
- Suggestion chips: not found. Full-screen photo preview, multi-photo layout, LaTeX and diagram rendering (v1.8/1.11). [4]

## 3. Voice
- Dictation ("Start dictation"); waveform button appears only when composer is empty and starts a voice chat. [5][7]
- Call UI: "Calling..." then Bot speaks; persistent "Voice chat" control under the header; Mute, Hang up, Show transcript, settings (Voice, Speed 0.5x-2x, Language/auto-detect). [5][6][7]
- Calls draw on earlier calls and recent chat; survive network drops; Bot can answer while you are muted; one call at a time. A phone call/FaceTime ends it. [6][7]
- After the call: a card with length + transcript, optional "How was the call?" Good/Bad; Bot may follow up in chat. [7]
- Bot voice memos are playable in thread. [5][7]
- Push-to-talk / walkie-talkie: not found. Spoken replies outside a call: only voice memos found.
- Reviewer (App Store): voice "good for prompting, not conversations", dropped calls, summarized not full transcripts. [8]

## 4. Thinking / working
- Slack-style thread with "Thinking" indicator while a Bot works (x.ai/bot marketing page). [9]
- Transcript interleaves tool activity, computer use, created files, questions, approval requests. [7]
- Live phone-call card: status + running transcript, later "Ended" + duration. [7]
- Live view of the cloud computer's screen. [5]
- New Bot slow to create shows "Still creating", typed text stays in box. [6]
- Turns with nothing to report no longer post a "done" message. [6]
- Step-list / progress bar UI: not found.

## 5. Background tasks
- Work continues in the cloud when the app is closed; results come back as messages + push. [5][6]
- Routines: schedule, next run, instructions, history, Active toggle, swipe to delete, "Edit routine" via chat. Editing schedule, testing, full history, teach-by-demonstration are desktop only. [5][6]
- Caps: 300 routine runs/hour total, 200 per routine. [6]
- Phone-app tools (Calendar, Reminders, etc.) only work while Grok Bot is open on the phone; otherwise the Bot asks you to open it. [5]

## 6. Memory
- Per-Bot memory and conversation; learns preferences, edge cases; "Saved to memory" confirmation; suggestions to improve a Bot. [1][6][9]
- Import Memory from another assistant: Settings > General > Start Import > Add to Memory. [6]
- Vault (logins, cards, contact info) with a Hints field telling Bots when to use each item. [6][10]
- Team: teammates' teaching is suggested; owner approves under "Review learnings". [6]
- A browsable/editable memory list on iPhone: not found.

## 7. Notifications and approvals
- Approval = card in chat with operation + inputs; warnings ("This can't be undone", "shares your data outside this chat"); buttons Allow once / Always allow (saves rule, "Saved to Custom Rules") / Deny; tap card on phone for full request. [11]
- Auto Review vets actions first; most run with no card. Background-origin emails wait as drafts until Send. Background cards expire after 30 min ("Expired"). New message closes open cards. Chat-started cards wait with no timer. [11]
- Phone permission card "Grok Bot needs permission": Allow once / Deny; or pre-allow per app. [5]
- Purchases: one-time card with merchant, items, total. Phone calls: card naming callee, Call/Cancel. [6]
- Push: per-Bot or global toggle; if desktop app is in use, finished replies skip the phone and needs-input pings reach phone ~3 min later. [5][6]
- Sound/banner design: not found.

## 8. System integration
- Siri/Shortcuts: List Bots, Send Message, Start Dictation, Start Voice Chat (dictation works without opening app, only while unlocked). [5]
- Live Activities: dictation and voice chat on Lock Screen + Dynamic Island. [5]
- Action Button: Shortcut > Grok Bot > Start Voice Chat; press again to hang up. [5]
- Share sheet: yes (see 2). Widgets, Control Center, keyboard extension: not found.
- Phone-app access: Calendar, read-only Contacts, Location, Alarms/Timers, iPhone-only Reminders + Apple Home; one app at a time under Connect apps. [5][6]
- Unofficial "Hey Grok" via Shortcut + Vocal Shortcuts (user post on X). [12]

## 9. Onboarding
- Sign in with Apple/Google/email; first-run tour; pick a first Bot; wait while the shared computer is set up; notifications optional. v1.16 "quicker onboarding". [4][5]
- Paywalled: Premium/Super/Ultra of The X Subscription, SuperGrok/Premium+ link ("Link Grok Account" + "Refresh My Status"); in-app monthly only. [5]

## 10. Motion and haptics
- Haptics toggle exists in Settings. Animation, transitions, specific haptic moments: not found.

## 11. Perceived speed
- v1.16 (18 Oct): "Faster message sending and bot replies". [4]
- Reviewer: model routing "not great" once; no latency numbers anywhere. [1]
- Bot's browser types one character at a time (slow by design). [6]

## 12. Empty / error / offline
- Internet required; no offline mode. [5]
- Library load fail: "Try Again". Computer unreachable: troubleshooting, desktop needed. Notifications off / permission denied: "Open Settings". [5]
- Voice: auto-reconnect, else "Voice chat failed" + Dismiss. [7]
- Signed-out app: Reconnect card. Expired order: "Check price again". Failed save: Retry. [6][7]
- Empty-state copy/visuals: not found.

## 13. Ideas worth borrowing (single-thread iMessage-style app)
- Approval card inline in thread with Allow once / Always allow / Deny, a danger label line, and a visible expiry for background-origin requests.
- Background-origin outbound actions land as editable drafts (Send/Discard) instead of auto-sending.
- Voice call stays as a thin persistent bar under the header, and ends as a thread card with duration, transcript and a one-tap rating.
- Let a new message redirect the running turn rather than queueing.
- Waveform button replaces send only when composer is empty; Action Button/Shortcut toggles the call (press again = hang up).
- Live Activity for dictation/voice only, with a tap-through "watch/take over" view for the agent's work (login/CAPTCHA handoff, "I'm done").

## Sources
1. https://venturebeat.com/orchestration/spacexais-grok-bot-turns-agents-into-persistent-digital-coworkers-that-can-operate-your-apps-for-120-per-month
2. https://www.unite.ai/xai-launches-grok-bot-always-on-ai-teammates-with-their-own-cloud-computers/
3. https://alternativeto.net/news/2026/8/spacexai-launches-grok-bot-a-new-ai-agent-app-for-autonomous-tasks-on-iphone-and-mac/
4. https://apps.apple.com/us/app/grok-bot/id6794501026
5. https://docs.x.ai/grok-bot/mobile
6. https://flaviocopes.com/grok-bot/ (page text reads like xAI release notes/docs; x.ai/changelog/bot itself returned 403, so treat [6] as secondary)
7. https://docs.x.ai/grok-bot/chat-and-collaboration
8. https://apps.apple.com/us/app/grok-bot/id6794501026?see-all=reviews
9. https://x.ai/bot
10. https://alternativeto.net/news/2026/10/grok-bot-adds-saved-logins-1password-and-phone-app-access/
11. https://docs.x.ai/grok-bot/approvals-security-and-privacy
12. https://x.com/MichaelGannotti/status/2114447997400682913
Also: https://aifirehosepodcast.com/episodes/grok-bot-halloween-update.html (one-button voice update, 19 Oct, no detail)
