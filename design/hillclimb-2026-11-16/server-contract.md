# What the iPhone app expects from otto-core that the server doesn't send yet

Eleven additions to `otto/server.ts` (the "App transport" block) and `otto/dash.ts`. The app's side of
each is built. Every one is switched on by something the server sends first, so against today's
server the app behaves exactly as it does now: no new button, row or request that leads nowhere.

All routes take the app's `Authorization: Bearer <token>`, as the rest of `/app/*` does. Timestamps
are ISO 8601 UTC. Unknown fields are ignored by the app, on every frame and body below.

## 1. Approval scopes

The approval frame (`{"type":"approval", …}`, also the rows of item 3) gains two optional fields:

```json
{"type":"approval","id":"a1","title":"Add 3 events to your calendar","summary":"…","files":[],
 "expires":"2026-11-16T15:04:00Z",
 "scopes":["task","always"],
 "rule":"adding events to your calendar"}
```

- `scopes`: the wider grants the server will take for this approval besides "this once". Any subset
  of `"task"` (until the turn or job that raised it ends) and `"always"` (until taken back, item 2).
  Absent or `[]` means once only, as today.
- `rule`: what an `always` would cover, as a lowercase phrase that completes "Always for …" and
  "Otto won't ask again for …". At most 80 characters. Required whenever `scopes` has `"always"`.

The app's answer gains one optional field:

```json
{"type":"approval","op":"approval-a1","id":"a1","decision":"approve","scope":"always"}
```

- `scope` is `"task"` or `"always"`, sent only on an approve and only when the frame offered it.
  Absent means once. A decline never carries one.
- The op id is unchanged (`approval-<id>`), so a resend after a lost ack is still the same decision.
  The app resends with the same scope, never a different one: it writes the decision (the
  answer and its scope) to disk before sending it, and keeps it while unacked until the server
  stops listing the approval or an hour has passed (twice the 30 minutes the server holds an
  approval), so it holds across a relaunch too, including one that kills the app while the ack is
  awaited. It never resends on its own, only when the owner taps the same answer again.
- On `task`, the server answers later approvals with the same `rule` (or, with no `rule`, the same
  `title`) from that turn or job itself, without raising them. On `always` it stores a rule (item 2)
  and does the same from then on. Either way the action is still journaled as today.
- The server must refuse a scope it didn't offer: treat it as once.
- A `task` answer that arrives after its turn or job has ended (the approval was put off with Later)
  counts as once.
- Never offer a scope on a payment (`payment` present) or on a change with a `guarded` file.

App side (`Otto/Approvals.swift`): a menu beside "Expires in N min" on the sheet, "Just this once"
picked every time it opens; the yes button reads "Always allow" when that is picked, and a line
under the menu says what it means; Face ID as now. The app drops what it shouldn't show whatever the
frame says: every scope on a payment or a guarded change, and `always` without a `rule`.

Without it: no `scopes`, so no menu. The sheet is today's.

## 2. What Otto may do without asking

```
GET    /app/dash/rules        → 200 {"rules":[Rule]}        ([] when none)
DELETE /app/dash/rules/<id>   → 200 {"revoked":true}        (or {"revoked":false}: no such rule)
```

```json
{"id":"calendar:write","label":"adding events to your calendar",
 "created":"2026-10-28T18:40:00Z","uses":1,"lastUsed":"2026-11-09T08:15:00Z"}
```

- `id`: 1 to 64 of `A-Z a-z 0-9 . _ : -`. `label`: the `rule` words the grant was given under.
  `uses` and `lastUsed` are optional (how often the rule answered for the owner, and when last).
- Only `always` grants are listed. After a DELETE the server asks again from the next time on.

App side (`RulesScreen` in `Otto/SystemViews.swift`): "Allowed without asking" in the contact card,
under Devices; each rule with when it was given and how often it was used; swipe, "Ask Again". If
the DELETE gets no 2xx answer the app says Otto may still be allowed.

Without it: the GET is a 404, and the card shows no row.

## 3. Pending approvals over HTTP

```
GET /app/approvals   → 200 [Approval]     ([] when none)
```

Each element is the approval frame without `type`: the same object `approvalFrame` builds, for
every approval `liveApprovals()` returns. The background refresh sends `X-Otto-Background: 1`, as it
does on `/app/history`; the server may record it as it does there, and answers the same either way.

App side (`OttoStore.syncApprovals` in `Otto/OttoApp.swift`): read on every connect, on coming to
the front and in the background refresh. An approval answered on the Mac, or dropped, leaves the
sheet, the pill over the composer and the Home Screen widget at once instead of after its half hour;
one raised while the phone's socket was frozen shows on the widget from the next refresh.

Without it: a 404, which the app reads as "can't say", never as "none". Nothing is removed.

## 4. Who a draft goes to

For something Otto wants to send in the owner's name, the approval frame gains:

```json
"draft":{"channel":"email","to":["Marta Bianchi <marta@example.com>"],"cc":["…"],
         "subject":"Parent meetings: hall booked","body":"Hi all,\n\n…"}
```

- `channel`: `"email"`, `"imessage"`, `"sms"`, `"whatsapp"`, or any other name (shown capitalised).
- `to`: every recipient, at least one. `cc` and `subject` are optional. `body` is the whole text
  that will be sent, not a preview. `attachments` is optional: the name of each file that goes with
  it (`["Quote.pdf"]`).
- `title` stays the sheet's title ("Send email"); `summary`, when not empty, is shown as why Otto is
  sending it. `files` is `[]`.
- On approve, the server sends exactly that draft. Item 1's scopes apply as to any approval.
- Use it for every send in the owner's name that Otto starts on its own. The draft card in the
  thread (a message whose text starts "draft to <name>:", with Send and Discard buttons) stays for
  what the owner just asked for; it should always name who it goes to and by which channel:
  "draft to Marta (email):".

App side (`draftRows` in `Otto/Approvals.swift`): the channel, each recipient on a line of its own
(never "and 3 more"), the subject, any attachments by name and the full body, then the buttons,
"Decline" and "Send", behind Face ID.

Without it: no `draft`, so approvals draw as today.

## 5. Forgetting a memory from its page

```
GET  /app/dash/memory            the existing body, plus "canForget": true
POST /app/dash/memory/forget     {"id":"<MemoryItem.id>"} → 200 {"ok":true}
                                 200 {"ok":false} when there is no such memory (already gone)
```

The server deletes that memory and its index line; the next `GET /app/dash/memory` may still list
it until the index is rebuilt.

The POST is idempotent: asked twice, the second answers `{"ok":false}`. Forgetting also takes the
memory out of the summary: the server rewrites `summary.text` without it (or blanks it until the
nightly rewrite) before the memory page is next served with a new `generatedAt`.

App side (`MemoryDetailScreen` in `Otto/MemoryViews.swift`): with `canForget`, the page's Forget
asks "Forget this?", says it can't be brought back, deletes and takes the row off the list at once;
the row stays off across a relaunch until a rebuilt index no longer lists it, and until then the
summary isn't shown either, so the forgotten fact can't be read there. Any non-2xx or no answer:
"Couldn't confirm", with Try Again, since the memory may or may not be gone.

Without it: no `canForget`, so Forget asks Otto in the chat (`forget memory <name>`), as today.

## 6. A Bark alert that opens a waiting approval

`raiseApproval`'s push passes `url: 'otto://approval'` in `barkPush`'s `extra` (today it gets the
default `otto://`, which opens the app on the thread).

App side (`Doors.open` in `Otto/OttoApp.swift`, already shipped): `otto://approval` opens Otto's
thread and brings back an approval that was put off with Later. One not yet seen shows its sheet as
soon as the app connects, with either link.

## 7. The app alerts for an approval while it's connected

The hello frame gains an optional list, and the app gains one frame:

```json
{"type":"hello","acks":true,"alerts":["approval"]}          otto -> app, on connect
{"type":"approval_alerted","id":"a1"}                       app -> otto
```

`approval_alerted` carries no `op`: the server doesn't ack it, and the app sends it once and
never again (late, it would mean nothing).

With `"approval"` in the hello's list the server holds its Bark push for an approval for 5 seconds
after sending the frame. If any phone app socket (not a desktop's) answers `approval_alerted` for
that id in that time, the push is dropped; otherwise it goes out as it does today. So responsibility
passes only when a phone says it has alerted, never on a socket merely being open. Today
`raiseApproval` forces the push because the app never alerted for one.

App side (`OttoStore`'s approval updates in `Otto/OttoApp.swift`, `Notifier.post(approval:)`):
- In front, the app sends `approval_alerted` when the approval's sheet is on screen, not when the
  frame arrives: with a call, the contact card or another sheet in its way the sheet waits, nothing
  is sent, and the Bark push follows after the 5 seconds.
- In the background (keep-awake holds the socket) it posts Otto's own notification, "Otto needs
  your OK" with what it asks, and sends `approval_alerted` only once iOS has taken the notification.
  With notifications switched off or never allowed it posts nothing and sends nothing, so the Bark
  push follows. A tap opens the approval; the notification is removed when the approval is settled
  (`approval_done`, or item 3's list no longer having it).

Without it: no `alerts`, so the app posts nothing, sends nothing, and the forced Bark push is the
only alert, as today. Never both.

## 8. Taking over the page Otto has open

For a step only the owner can do (a sign-in, a CAPTCHA, a code), the browser frame gains two flags
and two routes take the owner's hands:

```json
{"type":"browser","image":"data:image/jpeg;base64,…","caption":"…","url":"…","ts":1794840000000,
 "control":true,"held":false}
```

```
POST /app/browser/hold    {"hold":true}  → 200 {"held":true}     Otto stops acting on the page and waits
                          {"hold":false} → 200 {"held":false}    the page is Otto's again
POST /app/browser/input   one of                                 → 200 {"ok":true}; 409 when not held
     {"tap":{"x":0.42,"y":0.63}}     fractions of the picture's width and height, from its top left
     {"text":"…"}                    typed into whatever has focus on the page
     {"key":"enter"|"tab"|"backspace"|"escape"}
     {"scroll":0.8}                  viewport heights, positive is down
```

- `control`: the server takes a hold for this page. Absent or false: view only, as today.
- `{"held":…}` is the state after the request, and `{"ok":true}` is sent only once the input has
  been carried out on the page. The app sends one input at a time and waits for each answer, so
  the server sees them in the order they were made.
- While held, frames carry `"held":true`, keep coming (up to four a second while the page is
  changing, at least one right after each input, and none while nothing changes), and carry the picture even for a page the tile would otherwise show without one (a
  sign-in page): the owner asked to see it, behind Face ID.
- The server lets go on its own after 5 minutes with no input, when the app's socket closes, or
  when the work ends, and says so with a frame whose `held` is false.
- What arrives as `text` is typed into the page and nowhere else: not logged, not put in the
  thread, not shown to the session.

App side (`BrowserFullScreen` in `Otto/ChatView.swift`): with `control`, the full-screen page has
"Take over" behind Face ID. Holding, a tap on the picture is a tap on the page, a field types into
it (hidden as it's typed unless shown), and there are Enter, Tab, Delete and scroll keys and "Hand
back". The picture can be pinched in and dragged; a tap is sent as the point of the page it is on.
Closing the screen hands back too. What's typed stays in the field until the server answers
`{"ok":true}`; an input with no such answer is said under the picture, and for typing the app says
to look at the page before typing it again. Handing back, or closing the screen, first lets the
inputs already made reach the page in order, takes no new ones, and only then sends the release.

Without it: no `control`, so the page is view only and closes on a tap, as today.

## 9. What to know before any approval

The approval frame gains `"notes": ["Can't be undone", "Goes to people outside your contacts"]`:
optional, each at most 120 characters. A payment already has its own (`payment.notes`).

App side (`caveats` in `Otto/Approvals.swift`): shown first on the sheet, as "Before you approve"
(or "Before you send" on a draft), in the text colour.

Without it: no `notes`, no section.

## 10. Call keys in the pairing link

`otto/apptokens.ts new` adds two query items to the `otto://pair` link it prints as a QR code,
`vapiKey=<Vapi public key>&vapiAssistant=<assistant id>`, when both `VAPI_PUBLIC_KEY` and
`VAPI_ASSISTANT_ID` are set in the environment it runs with (the env file the server already reads
`VAPI_SERVER_SECRET` from). With either missing it adds neither. Values are URL-encoded like the
other items. The public key is the one Vapi's web SDK takes; it is not the server secret, which
never goes in a link.

App side (`PairingLink` in `Otto/Onboarding.swift`): pairing by scan, paste or a tapped link then
also sets up calls inside the app. They can be typed in the contact card too ("Calls in the app").
A link that opened the app from outside (a message, a web page) is never used unasked: the app
names the Mac, says that calls change too when the link carries these, and waits for Connect. The
keys are kept only once that Mac has accepted the token.

Without them: the phone button dials Otto's number, as today.

## 11. Stopping the turn Otto is on

The hello frame gains an optional flag, and the app gains one frame:

```json
{"type":"hello","acks":true,"stop":true}                    otto -> app, on connect
{"type":"stop","op":"7C1F…"}                                app -> otto
```

- With `"stop":true` the server takes `stop`: it interrupts the turn the session is on (what Esc
  does in the terminal), ends the typing state as at the end of any turn (`{"type":"typing",
  "on":false}` and `{"type":"todos","items":[]}`), and sends an ordinary message saying it stopped
  and where it got to ("Stopped. I'd read two of the five emails; nothing was sent.").
- It answers `{"type":"ack","id":"<op>"}` like any other op, once the interrupt has been asked for.
  With no turn running it acks and does nothing else: no message.
- A coding job isn't a turn. It keeps running; it has its own Stop (`POST /app/jobs/stop`).
- Whatever the turn had already done stays done. The message should say so when it matters.

App side (`ChatView` in `Otto/ChatView.swift`, `OttoStore.stopTurn`): touch and hold the bubble
that shows what Otto is doing, then "Stop". The bubble goes when the server sends `typing` off,
not before, so it never claims a stop the Mac hasn't made; no ack within the usual wait is
an error haptic and an alert, "Couldn't confirm Stop", with Try Again (which sends a new `stop` with
a new op id); the bubble stays as it was.

Without it: no `stop` in the hello, so the bubble has no menu and the frame is never sent.
