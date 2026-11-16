# Muse Agent (Meta) - rival notes, 2026-11-16

Caveat: no screenshots, App Store text or Meta UI docs were reachable. Most UI detail is secondhand (reviews, launch coverage), and some of it describes the web or Mac app. "not found" means no source confirmed it. Several details are marked [web] where the source describes the web app, not iPhone. Sources are listed at the end and cited as [S#].

## 1. Screens and navigation
- Main chat is one persistent conversation. You can interrupt it or queue several tasks before it finishes. [S3]
- Side chats (menu icon top-left, then pencil-and-note icon) keep a big project out of the main thread. [S4]
- Tabs named in reviews: Chat, Library (output files, docs, websites, images, dashboards), Goals (long-running projects), Ideas (suggested tasks, out-of-the-box prompt library), plus a personalized feed. [S4][S5][S9]
- Tapping the assistant icon at the top of the app leads to Upcoming (reminders, scheduled and recurring tasks), Activity log, Identity > Memory. [S4][S7] The Approvals queue is listed as a section by one source only. [S7]
- Settings: Permissions, Connectors, Data controls, Usage. [S4]
- Assistant has a chosen name, avatar and communication style. [S3][S10]
- Meta's own screenshot captions: Goals, Connectors, Messaging, Approvals, Browser, Secure Storage. [S10]
- Later additions: Spaces (custom mini apps), outbound phone calls for paid US subscribers, iPad support (7 Oct). [S6][S11]

## 2. Chat / composer
- Pitch: "built to feel like texting a person." Also reachable in WhatsApp. [S6][S2]
- The assistant reacts with small emojis to acknowledge messages. [S12]
- Approval cards sit in chat with accept/reject. [S3]
- Chat controls during browsing: "Open browser" (watch), "Take control of the browser", "Stop the task". [S4]
- Composer attachments, suggestion chips, input buttons: not found.
- Muse can deliver interactive Artifacts (itineraries, live dashboards). [S3]

## 3. Voice
- Real-time voice launched 5 Nov 2026 on mobile, web and Mac, US only. [S13][S14]
- Entry: phone icon top-right of a conversation. [S13][S14]
- Continuous conversation, interruptible mid-reply. Push-to-talk not found (source describes fluid continuous talk). [S13]
- Animated avatar reacts while listening and speaking (lip sync, expressions). Three layouts: voice only, avatar beside chat, full screen. [S13][S14]
- Hundreds of voices, switchable any time. [S13]
- Tasks keep running in the background while you talk. [S13]
- Live transcript in voice mode: not found. Dictation: a separate Muse Voice Transcribe exists, Mac-focused. [S15]
- Spoken replies to text chat: not found.

## 4. Thinking / working indicators
- Snippet under the avatar shows current active work. Full activity log lists actions and approved permissions. [S3]
- Activity feed is the main progress surface: tool calls and step-by-step lineage per task. A reviewer praised it. [S9]
- Avatar animates (typing at a laptop while tasks run). Not confirmed to reflect real status. [S12]
- Watch the cloud browser live via "Open browser". [S4]
- No step list or progress bar inside the chat bubble described. Streaming text: not found.

## 5. Background tasks
- Runs on Meta's cloud VM ("Muse Secure VM"), keeps working with the app closed, returns when something changes or it needs approval. [S1][S2]
- Recurring jobs run on a schedule (feed every couple of hours, eBay scan twice a day); set up in plain language, refined by follow-up messages. [S12]
- Upcoming screen lists scheduled tasks. [S4]
- It can also start messages unprompted, with controls to reduce, increase or disable that. [S3]
- Usage meter shows % of quota left, warns when free usage runs out. A reviewer burned about 6% of the weekly quota per day. [S16][S12]

## 6. Memory
- Remembers preferences, goals, details mentioned once. [S1][S7]
- Memory, Soul and Identity are editable files under Identity > Memory. [S4][S7]
- You can also ask in chat ("what do you remember about X"), and ask it to forget. [S4]
- Forget searches and removes related info. Reset wipes history, files, tasks. Deleting a chat does not necessarily erase what was learned. [S7][S17]
- No switch to turn Memory off, per one reviewer. Training opt-out is separate, on by default, under Data controls. [S17]

## 7. Notifications and approvals
- Asks before sensitive actions (send email, purchase). Approval points are built into the product, not left to the model. [S1][S8]
- Approval card has "See task details" and five choices: Allow once, Allow for this task, Allow for this site, Always allow, Deny. [S4]
- Per-connector modes: "Ask for some actions" (default, routine reads pass) vs "Always ask" (every action). Grants can be reviewed and revoked. Separate website-access controls. [S4][S7]
- Email can be read-only or send-on-your-behalf. [S1]
- Sentinel, a separate isolated agent, must approve anything leaving the VM; it allows, denies or asks you. [S1][S8]
- Payments: Link by Stripe issues a one-time card, Muse never sees real card or passwords. Checkout pauses for final approval. [S1][S8][S18]
- Push notification UI, lock-screen actions, notification settings: not found. Muse decides whether a result is worth a notification. [S3]
- A payment card is required at signup even for the free tier. [S16]

## 8. System integration
- Widgets, Live Activities, Siri/App Intents/Shortcuts, share sheet, Action Button, Control Center: not found. One reviewer says it "lives on my home screen" (an icon, not a widget). [S12]
- WhatsApp is a second front door. [S2]

## 9. Onboarding
- Requires a US or Canada adult, iOS 18+, no invite code. [S4][S7]
- A mascot introduces the main functions on first launch, and can be changed. No blank page; Ideas gives starter prompts. [S12][S9]
- Suggested setup: set Permissions defaults to "Always ask" before connecting. Connect Gmail from chat ("Connect my Gmail") or Settings > Connectors. [S4]
- Reviewer saw repeated nudges to connect bank accounts, inbox and ID dates; they were prompts only. [S17]

## 10. Motion and haptics
- Animated, expressive avatar (a reviewer called it a standout design decision). [S9][S13]
- Haptics: not found. Transitions: not found.

## 11. Perceived speed
- No latency measurements for the iPhone app found. The 0.16 s figure is for Muse Voice Transcribe only, unverified. [S14]
- Shopping and browser tasks are slow and patchy (blocked by Amazon, CAPTCHAs). [S4][S9]
- Reviewer verdict: Lenny's "best-designed personal agent"; Android Authority and Clearmud less impressed. [S9][S12]

## 12. Empty, error, offline
- Reported failures: CAPTCHA or 2FA it cannot pass, kicked out of the browser, sites that block agents, stale results, calendar event created 2h40m in the past. [S4]
- Weak results are fixed by correcting in chat ("condition and sort order"). [S12]
- "Take control of the browser" is the escape hatch. [S4]
- Offline state, empty thread state: not found.

## 13. Ideas worth borrowing for a single-thread iMessage-style app
- Approval card with scope ladder: once / this task / this site / always / deny, plus "see details" first.
- One-line live status snippet pinned under the assistant's identity, tapping it opens the full activity log.
- Side chats spun out of the main thread so long projects don't bury the conversation.
- Voice call from the thread header, with avatar beside the chat, so tasks keep running while you talk.
- Per-connector "ask for some / always ask" trust modes, with grants viewable and revocable.
- Memory as plain editable text, also reachable by asking in chat.

## Sources
- S1 https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/
- S2 https://thenextweb.com/news/meta-muse-personal-ai-agent-launch
- S3 https://www.testingcatalog.com/meta-introduces-muse-as-a-proactive-personal-agent.md
- S4 https://www.datacamp.com/tutorial/meta-muse-tutorial
- S5 https://www.vktr.com/ai-platforms/meta-launches-muse-a-personal-ai-agent-that-browses-the-web-makes-purchases/
- S6 https://www.digitaltrends.com/phones/metas-new-ai-agent-muse-can-actually-get-things-done-for-you/
- S7 https://rywalker.com/research/meta-muse
- S8 https://www.fullstack.com/blog/inside-metas-muse-permissions-tools-and-personal-ai
- S9 https://www.lennysnewsletter.com/p/muse-review-the-personal-ai-agent
- S10 https://techcrunch.com/2026/09/08/meta-debuts-its-muse-ai-agent-will-consumers-trust-it/
- S11 https://letsdatascience.com/news/meta-adds-ipad-support-to-muse-3017453a
- S12 https://www.androidauthority.com/meta-muse-one-week-later-hands-on-3718233/
- S13 https://testingcatalog.com/meta-rolls-out-muse-voice-and-expressive-avatars-in-the-us
- S14 https://www.androidauthority.com/meta-muse-real-time-voice-chat-mode-3732321/
- S15 https://www.techrepublic.com/article/news-meta-muse-voice-transcribe-real-time-speech/
- S16 (TechCrunch, same as S10; usage meter and card requirement)
- S17 https://www.neoteo.com/en/a-meta-muse-hands-on-review-found-task-help-and-data-prompts
- S18 https://thepaypers.com/payments/news/meta-launches-personal-ai-agent-with-stripe-powered-checkout
