# ChatGPT dots on iPhone (research, 2026-11-16)

Method note: openai.com and help.openai.com returned 403; official text came via learn.chatgpt.com and chatgpt.com/features/dots. No screenshots or App Store "What's New" text were reachable, so visual details are from prose only. Every "not found" means no source confirmed it.

## 1. Screens and navigation
- A dot is one persistent conversation inside the normal ChatGPT app, not a separate app or tab. [S1,S2]
- Entry is a "puck" in the sidebar just under "New chat". [S3,S4]
- Fast Company calls reaching it via the sidebar clumsy (digging each time) but easier than Codex Remote. [S5 via search snippet; MacStories agrees it's easier than Codex Remote S3]
- Thread syncs across phone/desktop/web. In-thread search does not work; long threads are hard to scroll back through. [S3]
- Dot has a name and a customizable colorful blob avatar. [S3,S6]
- One dot per user for now. [S4,S7]
- Activity list (delegated tasks, open one for progress/results/input requests) and Scheduled list: documented for the desktop app only; iPhone equivalent not found. [S1]
- Tabs / bottom bar for dots: not found.

## 2. Chat / composer
- Plain chat thread with the dot; no model picker, effort or speed control ("just ask, the dot starts working"). [S3]
- Composer details (attachments, suggestion chips, buttons inside messages): not found.
- Dot can use other tools, asks first; MacStories praises the pacing of the first interaction. [S3]
- Texting the dot (SMS-style channel) started rolling out in beta to US Pro users on Oct 28; also reachable via Slack/Teams. [S8,S1,S4]

## 3. Voice
- Phone button inside the dot's conversation starts a call. [S1]
- You can type messages during a call; work assigned can continue after the call ends. [S1]
- Calls are user-initiated, tap-to-start, not always listening. [S9]
- Push-to-talk / walkie-talkie: not found. Spoken replies in-thread (outside calls): not found.
- Separate from dots: ChatGPT Voice supports Live Activities on iOS (needs "Background conversations"). [S10] Not confirmed to apply to dot calls.

## 4. Thinking and working indicators
- Each dot has its own cloud computer + browser; you can open it to watch the browser, "Take over" to act (e.g. sign in), then "Return control". [S1,S7]
- Task progress is inspected in Activity (desktop documented). Progress updates can be sent to chat, Slack or Teams. [S1,S11]
- In-thread streaming indicator, step list, typing state on iPhone: not found.

## 5. Background tasks
- Runs on its cloud computer with connected apps while your devices are off / laptop closed. [S1,S7]
- Without instructions it does read-only "proactive research" through connected tools. [S6]
- Examples: daily calendar summary, monitoring bug reports, keeping an analysis current. [S7]
- Results come back as messages in the thread (or Slack/Teams); you can route routine progress to ChatGPT and decisions to Slack. [S1]
- "Pause" stops the main task; stopping does not undo completed actions. [S1]
- Dot tasks don't count against plan limits unless it launches a Codex/Work session. [S3,S7]

## 6. Memory
- Uses the conversation, relevant ChatGPT memory, and its own saved notes on preferences, decisions, ongoing work; notes carry across channels. [S1,S2]
- Checks you've allowed it before sharing private-conversation info with others. [S1]
- UI to view/edit the dot's notes: not found.

## 7. Notifications and approvals
- Dot "gets in touch" when it needs approval/input or something is urgent; pings before sending messages, editing docs, or using a payment card. Frequency tied to your comfort level. [S2,S7]
- Per-dot autonomy setting: act alone vs wait for approval. Custom Rules per action: allow / require approval / block. [S2]
- Auto-review step decides proceed / ask you / hand to you; password changes and money moves stay with you. [S1,S2,S11]
- Example given: finds dinner, orders only after approval. [S2]
- Trust failure reports: one reviewer's dot sent an email unasked after an earlier send was approved on the same thread [S7]; a Reddit user says it repeatedly loses permissions [S11, anecdote].
- Visual look of an approval card/sheet on iPhone, push-notification format: not found.

## 8. System integration
- Home Screen widget (iOS, added ~Oct 16): small size only. Mode A: avatar, tap opens the thread. Mode B: turn on "Show shortcut button" in the dot's edit screen to add message + voice buttons under the avatar. [S12,S13]
- Shortcuts / Spotlight: three actions, Message, Dictate, Call your dot; params are dot name and method. Can't take input from other apps or pass output on. [S12,S13]
- Action Button: assign one of those actions (author uses Call). [S12,S13]
- Camera Button: a third-party developer showed a shortcut example. [S9]
- Lock Screen widget, Control Center control, Live Activity for dots, share sheet, keyboard: not found (MacStories and others do not mention them).

## 9. Onboarding
- Create dot on phone (latest app; mobile web unsupported), desktop app or desktop web: name it, customize appearance, connect plugins/apps (already-connected ChatGPT apps carry over), optionally Slack, set access/autonomy and ask-first rules. [S1,S7]
- Connecting your computer is desktop-app-only. [S1]
- Sources conflict: some early coverage says setup is desktop-only; the official docs say mobile works. Trust S1.
- Access: Pro, Business Premium, Enterprise opt-in; not Free/Go/Plus. [S2,S7]

## 10. Motion and haptics
- Not found. Only visual note: blob avatar with "rounded, bubbly" look. [S6]

## 11. Perceived speed
- No latency measurements found. Reddit anecdotes call it "slow and lazy", "gives up quickly" (via vendor page, weak). [S11]
- MacStories: first interaction pacing well done; no mention of slowness. [S3]

## 12. Empty, error, offline
- OpenAI warns dots can make mistakes; review consequential work. [S5,S11]
- Computer-connected mode only works while that Mac is online with the ChatGPT app open; one Mac at a time. [S1,S3]
- Specific empty/error/offline screens on iPhone: not found.

## 13. Ideas worth borrowing
- One long-lived thread as the home surface, with background work reporting back into it as messages.
- Per-action trust rules (allow / ask / block) plus an auto-review step, with money and passwords always handed to the human.
- Route kinds of updates by importance (routine progress quiet, decisions loud).
- "Take over / Return control" handoff for steps the assistant can't do (logins, payments).
- Widget with two modes: avatar-only opens thread, or add message + voice buttons.
- Three Shortcuts actions (message, dictate, call) that also work from Spotlight and the Action Button.
- Anti-lesson: thread search missing and sidebar-buried entry hurt; make search and one-tap entry first-class.

## Sources
- S1 https://learn.chatgpt.com/docs/dots
- S2 https://chatgpt.com/features/dots
- S3 https://www.macstories.net/stories/openais-dots-a-first-look/
- S4 https://zapier.com/blog/chatgpt-dots.md
- S5 https://fastcompany.com/91620082/openai-dots-agent-review (403; only via search summary)
- S6 https://www.iphoneincanada.ca/2026/09/29/openai-dots-take-on-meta-muse-and-grok-bot-with-24-7-ai-agents/
- S7 https://zapier.com/blog/chatgpt-dots.md (same page as S4)
- S8 https://help.openai.com/en/articles/6825453-chatgpt-release-notes (via search snippet)
- S9 https://www.aiposthub.com/chatgpt-dot-iphone-widget-action-button-guide/
- S10 https://www.thurrott.com/a-i/338971/chatgpts-voice-mode-now-supports-live-activities-on-ios
- S11 https://emergent.sh/learn/chatgpt-dots-review (competitor vendor page, weak)
- S12 https://macstories.net/reviews/chatgpt-dots-gain-widget-and-new-shortcuts-actions/
- S13 https://www.absolutegeeks.com/tech-news/chatgpt-dots-now-live-on-your-iphone-home-screen-and-action-button/
- https://www.macrumors.com/2026/09/29/openai-launches-dots/ (setup on desktop, then mobile; voice call)
