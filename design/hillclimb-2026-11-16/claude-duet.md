# Claude Duet: iPhone app research (2026-11-16)

Research preview announced 21 Oct 2026, Opus 5.5, waitlist, US Pro/Max/Ultra. iOS 26+. No screenshots or videos were reachable: the App Store page has placeholder art only, so everything below is from text. Nobody has published a hands-on of the UI; most reviews restate Anthropic's page. Treat visual details as "not found".

## 1. Screens and navigation
- One main thread ("picks up where you left off") plus optional topic "channels" (finance, hiring) that share memory. [9to5mac, DataCamp, App Store]
- A Tasks tab: ongoing work and items needing you. Only the user can mark a task complete; Duet can only suggest it. [9to5mac, DataCamp]
- A Make tab: finished deliverables (briefs, models, decks, dashboards) as editable files; figures link back to the source email/file/sheet. [9to5mac, DataCamp]
- Tab bar layout, icons, order: not found. Settings regrouped into cards (App Store What's New).
- Separate app from the main Claude app. [Anthropic article]

## 2. Chat / composer
- Message "the way you'd message a person": type or record a voice message. [9to5mac]
- Share into the app from other apps: photos, links, text, PDFs. [App Store What's New]
- Touch-and-hold to select reply text; full-screen code with line numbers. [App Store]
- Claude Code sessions can be followed, messaged and answered from the phone. [App Store]
- Early user: it "dumped Cards into the chat" while looking up tickets and felt busy. [eesel]
- Suggestion chips, attachment menu, in-message buttons: not found.

## 3. Voice
- Listing: "hold-to-talk and spoken conversations"; voice conversations have a mute button and keep going with the phone locked. [App Store]
- Conflict: DataCamp says voice input is transcription only, not a live spoken conversation. The App Store listing is newer and first-party, so it is likelier right. Unverified.
- Voice messages as a thread item (record and send): [9to5mac]. Dictation UX details: not found.

## 4. Thinking and working
- Anthropic's product page has a panel "You see what it's doing" (labelled in eesel's screenshots). Contents not found.
- Tasks tab shows what it has done and is working on, but no live view of the cloud browser; you cannot watch or take over. [eesel, DataCamp, TechCrunch]
- Step lists, streaming text, spinners: not found.

## 5. Background tasks
- Runs on its own cloud VM with its own browser; keeps going after you close the app, phone/laptop need not be on. [Anthropic article, 9to5mac]
- Result comes back as a post in the main thread when a task finishes, is blocked or needs a decision, plus a phone notification. [9to5mac, Anthropic article]
- Polls connected accounts every few hours (frequency adjustable), not live; urgent items can wait until the next check. [DataCamp, Beebom]
- Follows up on stalled threads and flags things "gone quiet". [App Store, 9to5mac]
- Background checks and big tasks count against plan limits. Reviews: quota burn, plans lost mid-task. [App Store reviews]
- A user said the agent is "so slow" to use. [eesel, one comment]

## 6. Memory
- Inherits your Claude memory, skills, connectors; can search past Duet and Claude chats (toggle: Settings > Your Claude). [DataCamp]
- Disconnecting an app stops access, but stored memory stays until reset. [DataCamp]
- Viewing or editing learned rules in the app: not found (reviewer says it is an open question). [botsinproduction]

## 7. Notifications and approvals
- Morning brief: short list of what needs a decision, with context and a draft where possible. [App Store, Anthropic article]
- User picks what to hear about and how often. [Anthropic article]
- Before send / post / pay / sign / delete it shows the exact action: destination, content, every recipient. [DataCamp, Anthropic article]
- While an approval waits, it keeps working on the rest; if you cannot respond, it finishes the rest and brings the approval back later. [DataCamp, eesel]
- Some actions always blocked (trading, moving money), some always ask even with "don't ask me again". [DataCamp]
- Payments: Link virtual card; amount approved in the Link app. Passwords typed into a separate form on the phone, never seen by Duet. [DataCamp, eesel]
- Product page panels: "You approve", "Safety built in". Approve/Deny button layout, sheet vs inline card: not found.
- Disconnect any app. [Anthropic article]

## 8. System integration
- Home Screen widget listing open tasks. [App Store What's New]
- Share sheet: yes (see 2). Keyboard extension: not found.
- Live Activities, Siri/App Intents/Shortcuts, Action Button, Control Center: not found.

## 9. Onboarding
- Waitlist by email that must match the Claude account and Apple ID; invites in waves; app may take minutes to appear. Signing into the app does not join the waitlist. [eesel, DataCamp, App Store]
- Existing Claude users get memory, skills, connectors already in place, so near-zero setup. [Beebom]
- In-app first-run screens: not found.

## 10. Motion and haptics
- Not found anywhere.

## 11. Perceived speed
- Only one comment ("so slow"). Slowness partly by design: polling every few hours. No streaming or latency measurements. [eesel, DataCamp]
- 4.4/5 from 156 ratings; praise for proactive check-ins, criticism for unreliability and quota use. [App Store]

## 12. Empty, error, offline
- Anthropic says it "may misread a thread or miscalibrate what's urgent". Early user: it pushed ahead on missing data instead of asking. [eesel, Anthropic article]
- Prompt-injection caveat: "no defense is perfect". No error-screen or offline UI described.

## 13. Ideas worth borrowing
- A Tasks view separate from the thread: what's running, what waits on you; only the human can close an item.
- Approval card shows destination, full content and every recipient, so there is nothing to miss.
- Approval waits while the agent keeps working on the rest, then re-surfaces the card later.
- Results land as a post in the thread plus a notification, with a pointer to an editable file.
- Numbers in answers carry a tap-through to their source (email, file, sheet).
- Voice that survives screen lock, with a mute button (hold-to-talk plus spoken conversation in one place).

## Sources
- https://claude.com/blog/claude-duet (and https://claude.com/resources/articles/claude-duet)
- https://techcrunch.com/2026/10/22/claude-duet-app-is-anthropics-bet-on-agents/
- https://apps.apple.com/us/app/claude-duet-by-anthropic/id6803276000
- https://9to5mac.com/2026/10/21/anthropic-takes-on-chatgpt-dots-and-meta-muse-with-claude-duet/
- https://www.datacamp.com/blog/claude-duet
- https://www.eesel.ai/blog/claude-duet-review
- https://gadgets.beebom.com/guides/claude-duet-app-explained
- https://www.androidauthority.com/claude-duet-android-app-launch-capabilities-features-3726465/
- https://botsinproduction.com/blog/claude-duet-review-from-someone-who-built-one-by-hand/
