# Pips design mockups

Open `index.html` directly in a browser. Plain HTML and CSS; no scripts, build,
network assets, dependencies or app changes. Controls inside frames are drawings;
page navigation and the handoff link use native anchors.

The eight planned screens appear in light and dark, followed by the handoff
exchange. Desktop pairs stack at narrow widths. Each iPhone screen is 402 × 874
points inside the ios-sim scaffold; the complete device scales without reflow.

Coverage:

- Conversations: Otto, Inbox, Code, School and Home; unread, working, needs you and asleep.
- Otto thread: lead orchestrator; direct access to pips; Telegram/WhatsApp stay with Otto.
- Group: sender names, @mention and GPT fallback when Claude’s weekly limit is low.
- Handoff: centered exchange link, failed delivery and retry copy; nothing sent.
- New pip: name, job, instructions, mascot colour, shared memory/logins and approval rules.
- Details: job, schedules, access, asleep state and pause action.
- Mac: pips above the existing navigation; group activity panel.

Validation: Chrome at 390 and 1440 px, no horizontal scroll or overflowing phone
threads/sheets; screenshots visually inspected. The generative-ui checker also
ran at 375, 768 and 1440 px in both system appearances. Its only remaining
findings concern the 44-point handoff link after the complete phone is scaled
for display. iOS Safari on a spare iPhone 17 Pro simulator was checked for frame
clipping and sheet layout. The simulated controls are intentionally static.

The iPhone uses the requested blue outgoing bubbles; the current Swift source
uses slate. Mac colours follow the desktop source, including its slate bubbles.
All content is fictional. Mascots and icons use CSS and original SVG paths.
