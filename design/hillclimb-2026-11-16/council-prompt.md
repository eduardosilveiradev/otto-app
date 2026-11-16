# Review: Otto's iPhone app against five rival assistant apps

Score Otto's iPhone app out of 10 against five rival assistant apps, and list the concrete fixes that would raise the score. This is a read-only review. Change nothing, don't build or run the app, and don't boot a simulator: the screenshots are the running app. Don't ask questions; where something is unclear, say what you assumed.

## What Otto is

Otto is a personal assistant that runs on its owner's own Mac: a Claude Code channel plus a server ("otto-core") that lives in a separate repository and isn't under review. The iPhone app is how the owner reaches it: one Messages-style conversation with Otto, and a contact card behind the header with what Otto knows and the settings. The app is sideloaded with a free Apple signing team, so it has no APNs push entitlement; the server sends its pushes through Bark.

## What to review

Everything is in one folder: `/Users/artemisai/.otto/build/jc4bfeb-review/`

- `axes.md`: the twelve axes to score, and notes on the ones that only partly fit Otto.
- `rivals/`: research notes on the five rivals (Grok Bot, ChatGPT dots, Muse, Claude Duet, OpenBot). They are your only source on the rivals. Don't browse the web.
- `screens/`: screenshots of the app's screens and states, taken in the iOS simulator with sample data, in the dark appearance. `screens/index.md` names each one and says what it shows. `screens/sheets/` has contact sheets of all of them for a first pass, and `screens/full/` has each shot at full resolution.
- `source/`: the app's source as it is now. Read it for what a screenshot can't show: motion, haptics, timing, offline and error handling, background behaviour, accessibility, the light appearance, and anything with no screenshot, such as widgets and Live Activities.
- `server-contract.md`: what the app expects from the server that the server doesn't send yet.

Review only what is in that folder. Don't read anything outside it: no git history, no pull requests, no other folders on this machine.

## Fixed constraints

The owner has decided these. Don't propose a fix that breaks one. If you think one of them costs Otto points, say so under "What blocks 10", not in the fixes.

- The app is a faithful iMessage-style single thread. No tab bar, and no dashboard cards in the thread.
- The conversation layout (header, bubbles, composer) and Otto's thinking mark (the moving face) are approved as they are.
- Buttons are iOS system blue, never orange. Tangerine only marks Otto and things that need the owner.
- No glows, no gradients, no emoji used as icons.
- The app stays sideloaded on a free signing team: nothing can depend on APNs.

## How to score

1. Read `axes.md` and all five rival notes.
2. Look at every screenshot: the contact sheets first, then each screen that matters to an axis, at full resolution when a detail matters.
3. Read the source for what the screenshots can't show.
4. Score Otto and each rival from 1 to 10 on each of the twelve axes. One decimal is fine.
5. Give Otto one overall score from 1 to 10. It is your judgement of the whole app against the rivals, not an average.

What 10 means: on every axis that applies to it, Otto is at least as good as the best rival, and you have no fix left that a person using the app would notice. Don't hold a point back on principle, and don't give one out of politeness. Every point you take off, overall or on an axis, has to come with a fix in your list, or with a plain statement of why it can't be fixed within the constraints.

Features that need the server: where the app's side of a feature is built and `server-contract.md` says what the server must send or accept, count the feature as present, but only if you have checked both of these: (a) the app's code for it is complete, and still behaves correctly against a server that doesn't have it yet; (b) the contract is exact enough to build from without asking questions. If either fails, count the feature as absent and say what's missing. Then give a second overall score, "today", for the app against a server that has none of the contract.

A rival's score rests on its notes. Where the notes found nothing on an axis, score that rival 5 or lower on it.

## What to send back

Use exactly this shape:

```
OVERALL: <n>/10
TODAY: <n>/10

## Scores
| Axis | Otto | Grok Bot | ChatGPT dots | Muse | Claude Duet | OpenBot |
(twelve rows, in the order of axes.md)

## Fixes
(Numbered, most valuable first. For each one: [client] or [server], the axis it would raise, the screenshot or the source file and line it is about, what is wrong, and exactly what to change. Only real defects and gaps that would raise a score: no restyling to taste, and nothing that breaks a fixed constraint.)

## Depends on the server
(Each feature you counted as present under the server rule, and whether its app side and its contract passed your check.)

## What blocks 10
(The shortest honest list of what would have to be true for you to give 10.)
```
