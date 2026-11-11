# Screenshots for otto/a3-calls-and-walkie-never-get-stuck-697d6e

iPhone 17 Pro simulator, iOS 27.0, Debug build. Every failure was real: the app talked to a dead
port or to `standin.ts` (a stand-in for Vapi's API on :3001, or for the Otto server's voice upload),
reached through the DEBUG launch flags in the PR. The simulator has no tap tool here, so
`-tryAgainOnce` pressed the first "try again" through the button's own action.

## Call

| File | How | Shows |
| --- | --- | --- |
| `call/1-calling.png` | stand-in holds `/call/web` open | "calling…" with speaker, mute, end |
| `call/2-failed-dead-host.png` | nothing listening on :3001 | "call failed", the reason, close and try again |
| `call/3-failed-timeout.png` | stand-in never answers | "calling…" gives up at 20 s: "Couldn't connect." |
| `call/4-failed-server-killed.png` | stand-in killed while the call was being set up | "The network connection was lost." |
| `call/5-failed-dead-room.png` | stand-in returns a call room that doesn't exist | "Couldn't connect." (before: the screen closed with no word) |
| `call/6-failed-largest-text.png` | dead host, largest accessibility text size | |

`logs/call-timeout-and-retry.log`: the first request at 8 s, the timeout at ~28 s, try again sends
a second request at 31 s. `logs/call-dead-room-and-retry.log`: the same for the dead room.

## Walkie-talkie

| File | How | Shows |
| --- | --- | --- |
| `walkie/1-thinking.png` | note accepted, no reply ever | "Otto's thinking" (unchanged) |
| `walkie/2-not-delivered.png` | server on a dead port | "Not delivered · Try again", at once |
| `walkie/3-no-answer-after-60s.png` | note accepted, no reply | after 60 s: "Otto didn't answer · Try again" |
| `walkie/4-not-delivered-largest-text-dark.png` | dead port, largest text, dark | |

`logs/walkie-no-answer-and-retry.log`: the note goes up at 9 s; try again at 72 s sends it again
as a new note (it had been delivered). `logs/walkie-killed-then-retry.log`: the upload was held,
the server killed and restarted; try again sent the same note id again, no second copy.

## Run

```sh
PORT=3001 MODE=hang bun standin.ts     # or MODE=bogus; nothing on :3001 for a dead host
xcrun simctl launch <sim> dev.otto.app -onboarded YES -call -vapiPublicKey lab -vapiAssistantId lab -vapiHost localhost [-tryAgainOnce]

PORT=4599 MODE=ok bun standin.ts       # MODE=hang to hold the upload; a dead port for "not delivered"
xcrun simctl launch <sim> dev.otto.app -onboarded YES -walkie -walkieNote -serverURL http://127.0.0.1:4599 -serverToken lab [-tryAgainOnce]
```
