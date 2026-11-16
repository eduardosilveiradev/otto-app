# OpenBot (openbot.run) - iPhone app notes, 16 Nov 2026

## Identification
- Means: **OpenBot by Synthetify Labs / nightly-labs, openbot.run** (App Store "OpenBot.run", id6807024266). Confidence: ~85%.
- Evidence: Product Hunt "OpenBot 3" (tagline "Grok Bot alternative: free, local, open-source, multiplayer", #2 Product of the Day 6 Oct 2026, links to openbot.run, App Store, github.com/nightly-labs/openbot) [1][2]; mentions mobile + Ollama/LM Studio.
- It is a desktop agent-team workspace (Mac/Win/Linux); the iPhone app is a **companion** that needs the computer on [3]. Not a standalone phone assistant, and not OpenClaw-style texting.
- Caveats: a second, unrelated "OpenBot by CopilotKit" (open.bot) exists, iOS "early access" only, shows a "Needs your approval" card with Approve/Review buttons [9]. Not used below. Also "AI Chatbot - Ask Open Bot" is an unrelated ChatGPT wrapper.
- Limits: I could not view screenshots (App Store page gave no image URLs) or any demo video. Everything is from text. Most UI details are "not found".

## 1. Main screens and navigation
- Per-agent conversations (each agent has role, instructions, workspace, avatar), teams/shared projects, task tracking, conversation search, chat pinning, agent muting, threads, workflows, Marketplace of apps (207 apps) [4].
- Tab bar / layout: not found.

## 2. Chat / composer
- Real-time chat; "@" skill picker, "@" tagging of browser tabs/threads, file previews, files up to 100 MB, video attachments, message delete, mark unread, "smarter chat queue" [4].
- Composer layout, send button, attachment sheet: not found.

## 3. Voice input and spoken replies
- 1.4.4 "voice conversations"; 1.4.5 speak-aloud button on agent messages; 1.4.7 voice settings; ElevenLabs integration 1.4.8 [4].
- A reviewer asks for "improved voice mode" [4]. Hold-to-talk, calls, waveform UI: not found.

## 4. Showing the assistant thinking / working
- Live Activity (Dynamic Island / lock screen) tracks agents running; only new request, failure, new reply and finished agent are "urgent" updates [5].
- In-thread thinking indicator, tool-step display: not found.

## 5. Background tasks
- Agents keep running on the host computer; phone follows progress and sends tasks remotely (maker comment) [1][3]. Workflows with approval steps on mobile [6].
- Phone cannot work if the computer is off [3].

## 6. Memory
- 1.4.10: long-term agent memory via Honcho and Hindsight, server-side integrations [4]. Memory UI on phone: not found.
- Desktop: per-agent context monitor compacts long threads [7].

## 7. Notifications and approvals
- Thread-completion notifications (1.4.9) [4]. Host forwards notifications to phone when the computer was idle ~30 s (dev default) [7].
- Approvals: server sends full text of long approvals to mobile (0.70.0) [5]. Default agents run "approvalPolicy: never" with "Ask first" / "Full access" consent modes [7]. Approval sheet visuals: not found.

## 8. System integration
- Live Activity via APNs, ends at iOS 8 h limit, one update after re-sign-in [5][7].
- Widgets, Siri/Shortcuts, share sheet, Action Button, keyboard: not found. A feature request asks for agents to read Reminders/Calendar/Contacts/Health on a paired phone (proposal only) [8].
- Also iPad support; iOS 16.4+ [4].

## 9. Onboarding / pairing
- Desktop: Settings > Mobile Connect > generate QR (expires in 2 min, single use). Phone: "Scan QR code". Needs an OpenBot account [3].
- Encrypted, direct device-to-device (WebRTC, coturn relay fallback), no VPN/tunnel, nothing stored in cloud. Revoke from desktop, access stops instantly [3][7].
- Product analytics on by default; off in Settings > General > Privacy [1].

## 10. Motion and haptics
- Not found.

## 11. Perceived speed
- Changelog claims "faster startup" (1.4.6) [4]. Live Activity late/missing updates were a known bug fixed 0.70.0 [5]. Otherwise not found.

## 12. Empty, error and offline states
- Codex "at capacity" notice now shows on mobile too [5]. Computer-off requirement stated in docs only [3]. In-app copy: not found.

## 13. Ideas worth borrowing
- Pairing as a 2-minute single-use QR with instant remote revoke, shown with the exact trust model in one line.
- Live Activity limited to four "urgent" events (request, failure, reply, done) so updates are never rationed away.
- Long approvals ship full text to the phone instead of a truncated preview.
- A per-conversation speak-aloud button on each message, separate from voice mode.
- Thread-completion notification for long jobs, with per-agent mute.
- "@" picker in the composer to reference a skill, tab or thread inline.

## Sources
1. https://www.producthunt.com/products/openbot-3
2. https://openbot.run/
3. https://openbot.run/download/ios
4. https://apps.apple.com/us/app/openbot-run/id6807024266
5. https://openbot.run/changelog (0.70.0, 13 Nov 2026)
6. https://github.com/nightly-labs/openbot/releases/tag/v0.52.0
7. https://github.com/nightly-labs/openbot
8. https://github.com/nightly-labs/openbot/issues/6128
9. https://open.bot/ (different product, CopilotKit)
