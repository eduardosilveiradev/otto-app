# Otto and its pips: design mockups

Open `index.html` in a browser. Plain HTML and CSS, no scripts, build step, network assets or app changes.

Direction: Otto is the tangerine and the largest face on every screen. Pips are the seeds inside it:
pointed, each with its own colour and one prop, with Otto's eyes and the same top-left light.
State (working, needs you, asleep, on GPT, failed) shows on the face, not in words. A handoff is a path
drawn between two faces. Group chats use a loose overlapping cluster of the members' faces.

Screens, each in light and dark: conversations, Otto's thread, group chat, handoff, failed handoff,
new pip, pip details, Mac conversations, Mac group chat with the activity panel. With only Otto the
app is unchanged and the conversations screen never appears.

`ios.css` is the iPhone frame (402 x 874 pt, scaled as one piece). Mac colours follow the desktop app's
tokens. All data is made up. Faces are original SVG. Faces blink, bob and breathe with CSS and stop
under `prefers-reduced-motion`.
