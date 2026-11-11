# Screenshots for otto/a5-details-share-sheet-keyboard-feedback-2a3f2b

iPhone 18 Pro simulator, iOS 27.0, Debug build. Every failure is real: the code talked to a stand-in
server (`standin.ts`) or to a port with nothing listening. Addresses are loopback (`127.0.0.1`), and
the token is a fake. The simulator has no tap tool here, so states were reached through launch
arguments.

- **Details**: the app itself, opened with `-details -checkServer` (DEBUG), which scrolls the contact
  card to the server fields and submits them.
- **Share sheet and keyboard**: an extension can't be launched from the command line, so
  `harness/` builds a throwaway app from the branch's own `ShareViewController.swift`,
  `OttoKeyboard/*.swift` and `Shared/*.swift` and drives them. Patches on its copy only: the
  keyboard's model is reachable, Full Access counts as on, and the text proxy gets a document id
  (an app can't grant either). The share harness has no app group, so it always takes the direct
  path to the server, which is the path these failures come from. The keyboard sits on a grey
  stand-in for the system keyboard backdrop. Keyboard shots are cropped to the bottom of the
  screen.

Stand-in modes, one per port: `ok` :4591, `500` :4592, `401` :4593, `hang` (accepts, never
answers) :4594, nothing listening :4595, `slow` (`/app/settings` after 9 s) :4596.

`overview-details.png` (light, then dark), `overview-share.png` and `overview-keyboard.png` put
the states side by side.

## Details: server address and token

| File | Server | Shows |
| --- | --- | --- |
| `details/1-checking.png` | slow | "Checking…" with a spinner under the token |
| `details/2-connected.png` | ok | "Connected" |
| `details/3-token-refused-401.png` | 401 | "The server didn't accept that token. Check it, or make a new one on your Mac." |
| `details/4-server-error-500.png` | 500 | "Otto's server hit an error (500). Try again in a moment." |
| `details/5-dead-host.png` | nothing listening | "Can't reach that address. Check it, and that Tailscale is on." |
| `details/*-dark.png` | | the same, dark |
| `details/6-token-refused-largest-text.png` | 401 | largest accessibility text size |

## Share sheet

| File | Server | Shows |
| --- | --- | --- |
| `share/1-loading.png` | (item never finishes loading) | "Getting what you shared…", Send off |
| `share/2-sending.png` | hang | "Sending to Otto…", keyboard down |
| `share/3-sent.png` | ok | "Sent" (the real sheet closes 0.8 s later) |
| `share/4-server-error-500.png` | 500 | the reason, Try again, Send back on |
| `share/5-dead-host.png` | nothing listening | "Can't reach your Mac. Check it's awake and on Tailscale." |
| `share/6-timeout.png` | hang | after 15 s: "Your Mac took too long to answer." |
| `share/7-server-error-after-try-again.png` | 500 | after Try again's action ran once |
| `share/*-dark.png` | | dark |
| `share/8-server-error-largest-text.png` | 500 | largest accessibility text size |

`logs/share-500-and-try-again.log`: two share sockets, the second from Try again.

## Keyboard

| File | Server | Shows |
| --- | --- | --- |
| `keyboard/1-thinking.png` | hang | "Otto is on it…" |
| `keyboard/2-server-error-500.png` | 500 | "Otto's server hit an error (500)." and the Try again chip |
| `keyboard/3-dead-host.png` | nothing listening | "Can't reach your Mac." and the chip |
| `keyboard/4-timeout.png` | hang | after 15 s: "Otto took too long. It may answer in the app." and the chip |
| `keyboard/5-token-refused-401.png` | 401 | the reason, no chip (trying again won't help) |
| `keyboard/6-answered.png` | ok | "Added · Undo", as before |
| `keyboard/*-dark.png` | | dark |

`logs/keyboard-timeout-and-try-again.log`: the ask at 1831.6 s, the chip's retry at 1849.1 s
(after the 15 s timeout), both with the same id, so a server that did get the first one answers
the second from the thread instead of asking Otto twice.

Not shown: the phone being offline (the simulator shares the Mac's network). That case is covered
by `Scripts/server-problem-check.sh`.

## Run

```sh
PORT=4592 MODE=500 bun standin.ts
xcrun simctl launch <sim> dev.otto.app -onboarded YES -noNotificationPrompt -serverURL http://127.0.0.1:4592 -serverToken lab-token-not-real -details -checkServer
harness/build.sh <worktree> && xcrun simctl install <sim> harness/Harness.app
xcrun simctl launch <sim> dev.example.harness -scene share -server http://127.0.0.1:4592 [-retryAfter 3 | -slowLoad]
xcrun simctl launch <sim> dev.example.harness -scene keyboard -server http://127.0.0.1:4594 [-retryAfter 17]
```
