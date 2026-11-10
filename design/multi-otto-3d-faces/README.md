# Otto and its pips: design mockups

Open `index.html` in a browser. Plain HTML and CSS, no scripts, build step, network assets or app changes.

Direction: the app stays one faithful iMessage thread and the faces carry the colour. Otto is the largest
face on every screen. Otto is a sphere and each pip is its own soft solid in its own colour; mood (working,
needs you, asleep, on GPT, failed) shows through the eyes. Group pictures are faces blobbed in a loose cluster.
Nobody makes pips by hand: Otto starts a group when a job needs one and makes the pips that group needs.

Copied from `Otto/ChatView.swift`: the top bar (centred picture, name in a glass capsule, glass phone button,
no fill behind it), the bubble shape, spacing and colours, the composer, and `TerminalLine`, which is now
also how a handoff appears in a thread. The path between two faces lives only in the handoff sheet.

Screens, each in light and dark: conversations, Otto's thread, group chat, handoff, failed handoff, Otto makes
a group, a new group, pip details, Mac conversations, Mac group chat. With only Otto the app is unchanged and the conversations
screen never appears.

`ios.css` is the iPhone frame (402 x 874 pt, scaled as one piece). Mac colours follow the desktop app's
tokens. All data is made up. Faces are PNGs in `faces/`, rendered by `faces/src/render.sh` from one WebGL shader.
They blink, bob and breathe with CSS and stop under `prefers-reduced-motion`.
`screenshots/` shows each section at desktop width.
