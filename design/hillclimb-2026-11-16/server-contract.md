# What the iPhone app expects from otto-core that the server doesn't send yet

Six additions to `otto/server.ts` (the "App transport" block) and `otto/dash.ts`. The app's side of
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
  The app resends with the same scope, never a different one.
- On `task`, the server answers later approvals with the same `rule` (or, with no `rule`, the same
  `title`) from that turn or job itself, without raising them. On `always` it stores a rule (item 2)
  and does the same from then on. Either way the action is still journaled as today.
- The server must refuse a scope it didn't offer: treat it as once.
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
does on `/app/history`.

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
  that will be sent, not a preview.
- `title` stays the sheet's title ("Send email"); `summary`, when not empty, is shown as why Otto is
  sending it. `files` is `[]`.
- On approve, the server sends exactly that draft. Item 1's scopes apply as to any approval.

App side (`draftRows` in `Otto/Approvals.swift`): the channel, each recipient on a line of its own
(never "and 3 more"), the subject and the full body, then the buttons, "Decline" and "Send", behind
Face ID.

Without it: no `draft`, so approvals draw as today.

## 5. Forgetting a memory from its page

```
GET  /app/dash/memory            the existing body, plus "canForget": true
POST /app/dash/memory/forget     {"id":"<MemoryItem.id>"} → 200 {"ok":true}
                                 200 {"ok":false} when there is no such memory (already gone)
```

The server deletes that memory and its index line; the next `GET /app/dash/memory` may still list
it until the index is rebuilt.

App side (`MemoryDetailScreen` in `Otto/MemoryViews.swift`): with `canForget`, the page's Forget
asks "Forget this?", says it can't be brought back, deletes and takes the row off the list at once.
Any non-2xx or no answer: "Not forgotten", and the row stays.

Without it: no `canForget`, so Forget asks Otto in the chat (`forget memory <name>`), as today.

## 6. A Bark alert that opens a waiting approval

`raiseApproval`'s push passes `url: 'otto://approval'` in `barkPush`'s `extra` (today it gets the
default `otto://`, which opens the app on the thread).

App side (`Doors.open` in `Otto/OttoApp.swift`, already shipped): `otto://approval` opens Otto's
thread and brings back an approval that was put off with Later. One not yet seen shows its sheet as
soon as the app connects, with either link.
