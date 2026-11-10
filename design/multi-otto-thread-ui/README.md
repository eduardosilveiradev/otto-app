# Otto and its pips: design mockups

Open `index.html` in a browser. Plain HTML and CSS, no scripts, build step, network assets or app changes.

Direction: the app stays one faithful iMessage thread and the faces carry the colour. Otto is the largest
face on every screen. A pip is the same circle in its own colour; mood (working, needs you, asleep, on GPT,
failed) shows through the eyes. Group pictures are faces blobbed in a loose cluster.

Copied from `Otto/ChatView.swift`: the top bar (centred picture, name in a glass capsule, glass phone button,
no fill behind it), the bubble shape, spacing and colours, the composer, and `TerminalLine`, which is now
also how a handoff appears in a thread. The path between two faces lives only in the handoff sheet.

Screens, each in light and dark: conversations, Otto's thread, group chat, handoff, failed handoff, new pip,
pip details, Mac conversations, Mac group chat. With only Otto the app is unchanged and the conversations
screen never appears.

`ios.css` is the iPhone frame (402 x 874 pt, scaled as one piece). Mac colours follow the desktop app's
tokens. All data is made up. Faces blink, bob and breathe with CSS and stop under `prefers-reduced-motion`.
`screenshots/` shows each section at desktop width.
