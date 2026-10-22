# The crew — contract for the first slice

Otto stays the one front door. Behind it sits a crew of specialist agents, each
its own headless `claude -p` session with its own tools, model and context,
reachable through one message tool. This file is the contract between the
server (`otto/crew.ts`, `otto/crewmcp.ts`, the routes and tools in
`otto/server.ts`) and the iOS app (chat list + agent threads). Both sides
follow it verbatim; where it is silent, keep the surrounding code's habits.

Placeholders: `<state>` is the state dir (`~/.otto/state`, or `OTTO_STATE_DIR`),
`<otto>` the plugin dir (`otto/`), `<port>` the webhook listener's port.

## 1. Identities

| id | role | display name | how many |
|---|---|---|---|
| `pm` | `pm` | Product manager | 1 |
| `planner` | `planner` | Planner | 1 |
| `designer` | `designer` | Designer | 0 or 1 (`crew.designer`, default true) |
| `writer-1` … `writer-N` | `writer` | Writer 1 … | pool, 1 … `crew.writers` (default 1) |
| `reviewer-1` … `reviewer-N` | `reviewer` | Reviewer 1 … | pool, 1 … `crew.reviewers` (default 1) |

Two more addresses exist that are not agents: `otto` (the live Otto session) and
`user` (the person, through the app). A message's `from` is an agent id, `otto`
or `user`; its `to` is an agent id, a bare role name (`writer`, `reviewer`:
the server picks a member, see §4), `otto` or `user`.

`displayName(id)`: `pm` → `Product manager`, `planner` → `Planner`,
`designer` → `Designer`, `writer-3` → `Writer 3`, `reviewer-1` → `Reviewer 1`,
`otto` → `Otto`, `user` → `You`.

Status of an agent, exactly one of: `idle` | `working` | `waiting` | `error`.

- `working` — a run is in progress (a pid the server spawned is alive).
- `waiting` — its last run ended after it sent at least one message to another
  agent or to `otto`: it handed off and nothing has come back yet.
- `idle` — never run, or its last run ended without handing anything off, or
  it was stopped.
- `error` — the run crashed twice in a row (or the `claude` binary is missing).
  Sticky until the next message to it (which retries) or a stop.

## 2. Configuration — `crew` in `access.json`

Optional. Every field optional. The block's presence (even `{}`) makes the crew
visible in the app before anyone has used it.

```json
"crew": {
  "maxConcurrent": 3,
  "writers": 1,
  "reviewers": 1,
  "designer": true,
  "models": { "pm": "opus", "planner": "opus", "designer": "sonnet", "writer": "sonnet", "reviewer": "sonnet" },
  "cwd": "/absolute/path/the/agents/start/in",
  "runMinutes": 30
}
```

- `maxConcurrent` — crew runs alive at once, across all agents. Default 3.
  Independent of `delegate`'s own cap.
- `writers` / `reviewers` — pool ceilings. Default 1 each. Members are created
  on demand (§4), never ahead of need.
- `models` — per role, any value `claude --model` accepts. Defaults as shown.
- `cwd` — working directory of every run. Default: `projectsRoot` from
  `access.json`, else `~/Documents/Projects`. Messages name repos by path.
- `runMinutes` — wall clock per run. Default 30, max 180.

**Inert rule.** With no `crew` block and no agent ever messaged, nothing spawns,
`GET /app/crew` answers `{"agents":[]}`, no frame is ever sent, no file under
`<state>/crew/` exists, and every other behaviour of the server is unchanged.
The crew becomes *active* the first time any message is delivered to an agent
(from Otto's tool or the app), or when the block exists.

## 3. Roles, tools and permissions

Every run is `claude -p <prompt>` with:

```
--output-format stream-json --verbose
--model <role model>
--permission-mode dontAsk --permission-prompts none
--tools <built-ins, comma-joined>
--allowedTools <rules, comma-joined>
--disallowedTools Read(/<state>/**)
--append-system-prompt <role prompt>
--strict-mcp-config --mcp-config <json, §5>
--session-id <uuid>            first run of this agent
--resume <sessionId>           every later run
```

`dontAsk` denies anything that would have prompted, so `--allowedTools` is the
whole policy and `--tools` removes built-ins the role must not even see.
`Edit(<path>)` rules govern Edit and Write alike (Claude Code checks file
permissions against `Edit`/`Read` rules only). `Read(/<state>/**)` is the state
dir as an absolute pattern (`//` prefix: `Read(//<home>/.otto/state/**)`,
built at runtime from the real path, never written in code).

| role | `--tools` | `--allowedTools` | extra |
|---|---|---|---|
| pm | `Read,Grep,Glob,Edit,Write,Bash` | `Read,Grep,Glob,Edit(**/*.md),Bash(git *),mcp__crew__*` | git only, for log/diff/merge |
| planner | `Read,Grep,Glob,Edit,Write` | `Read,Grep,Glob,Edit(**/*.md),mcp__crew__*` | |
| designer | `Read,Grep,Glob,Edit,Write` | `Read,Grep,Glob,Edit(**/*.md),mcp__crew__*` | |
| writer | `Read,Grep,Glob,Edit,Write,Bash` | `Read,Grep,Glob,Edit,Bash,mcp__crew__*` | works in `<repo>/.crew/<slug>` worktrees (§3.1) |
| reviewer | `Read,Grep,Glob,Bash` | `Read,Grep,Glob,Bash,mcp__crew__*` | no Edit/Write tool exists in its session |

`roleArgs(role, { stateDir, model })` in `crew.ts` returns exactly this argv
fragment (from `--model` through `--disallowedTools`), and is what the tests
check. Bash for writers and reviewers is unrestricted inside the policy: the
worktree rule and the user watching are the safety model, as with `delegate`.

### 3.1 Worktrees

Writers never edit a repo's main checkout. The ticket names the repo path and a
slug; the writer runs `git worktree add <repo>/.crew/<slug> -b crew/<slug>`
(reusing it if present) and works, builds, tests and commits only there. The
`.crew/` directory is inside the agents' cwd tree, so reads and edits there need
no extra `--add-dir`, and `otto/projects.ts` skips dot-directories, so the
nightly scan never lists a worktree as a project. The PM merges `crew/<slug>`
into the main checkout with `git merge --no-ff`. Nobody pushes.

### 3.2 System prompts (`--append-system-prompt`)

Every role gets the common block, then its own. The server builder copies these
verbatim (one string per role in `ROLES`); the mock crew in the app should read
as if these were followed.

Common:

> You are the {name} on the user's software crew. The crew: a product manager (pm), a planner, a designer, writers (writer-1, writer-2, …) and reviewers (reviewer-1, …), coordinated by Otto, the user's assistant. You run headless: nobody reads your transcript. The only things that reach anyone are calls to the crew_message tool, so every hand-off, question, report and answer is a crew_message(to, text) call — one per recipient, plain text, carrying the file paths, repo path and branch names the other side needs, because they share no context with you. Messages to you arrive in your prompt as "From <sender>:" blocks. Write to otto or user only when they wrote to you or a task asks you to report; never message user unprompted. crew_status shows who is busy. Tickets, specs and reviews are markdown files: refer to them by path. Never read or write anything under the user's .otto directory, never touch access.json or secrets, never push to a remote, never merge unless you are the pm. Keep messages short and concrete.

pm:

> You own the spec and the roadmap, and you are the only one who merges. When Otto hands you a feature: write or refine its spec as a markdown file under the repo's docs/, then message planner with the spec path and the repo path. When a writer or reviewer reports a ticket approved: check the branch against the spec with git log and git diff only, merge it into the main checkout with `git merge --no-ff crew/<slug>`, then message otto with one line per merged ticket (what, which repo). A ticket that falls short of the spec goes back to its writer with what is missing. You edit markdown only, never code.

planner:

> You split a feature (a spec path or a description) into markdown tickets, one file per ticket at <repo>/docs/tickets/<slug>.md, each cut by file or by feature so writers never collide, each with acceptance checks (the commands to run and what must be true). Assign each ticket by messaging writer with the ticket path, the repo path and the branch crew/<slug>; the server picks a free writer and tells you which. Follow up with that writer-N by name. Once every ticket is assigned, message otto with the list. Markdown only, never code.

designer:

> You write UI specs on request: screens, states, copy, spacing, what not to do, as a markdown file at the path you were asked for (default <repo>/docs/design/<slug>.md). Message whoever asked when it is written. Markdown only.

writer:

> You take one ticket at a time. Create your own worktree from the repo the ticket names: `git worktree add <repo>/.crew/<slug> -b crew/<slug>` (reuse it if it exists). Work only inside that worktree: read the ticket, make the change, build, run the acceptance checks, commit there with a clear message. Never push, never edit the main checkout. Then message reviewer with the ticket path, the worktree path, the branch, what you changed and how you tested it. A review comes back as a message: fix what it raises, commit, and message that same reviewer again. After your second round with a reviewer on the same ticket, stop and message pm with where things stand instead of continuing.

reviewer:

> Fresh eyes on a writer's work. Read the ticket, open the worktree it names, run `git diff main...<branch>` there and the ticket's acceptance checks. Message the writer with findings (path:line, what is wrong, what would fix it) or the single word approved, followed by the ticket path and branch. At most two rounds per ticket: if your second message on a ticket is not an approval, message pm with the open findings and stop. You read and run only; never change a file, not even through the shell.

## 4. Launcher behaviour (`Crew` in `otto/crew.ts`)

One object in the server process. No detached supervisor: runs are children of
the server, their pids saved, and a restart recovers (§4.5).

### 4.1 Delivery — `deliver(from, to, text, id?)`

1. Resolve `to`:
   - an exact agent id (`pm`, `planner`, `designer`, `writer-2`, …) — must
     exist or be creatable: `writer-K` with K ≤ `crew.writers` is created on
     first use; `designer` only if enabled.
   - a bare pool role (`writer`, `reviewer`): the first existing member with
     status `idle` or `waiting` and an empty inbox; else a new member if the
     pool is under its ceiling; else the member with the shortest inbox
     (ties: lowest number).
   - `otto` → the message is recorded in the sender's file (sender must be an
     agent) and injected into the Otto session (§6).
   - `user` → recorded in the sender's file, delivered to the app (§7); the
     Otto session is not involved.
   - anything else → error `unknown recipient "<to>"`.
2. Make the event (§5 shape, `kind:"message"`), `id` = 8 hex chars from
   `randomBytes(4)` (or the client's `id` when given, trimmed to 64 chars).
   Append it to the sender's JSONL when the sender is an agent, and to the
   recipient's JSONL when the recipient is an agent; the same `id` in both,
   `agent` set to the file's owner. Update `lastLine`/`lastFrom`/`lastAt` on
   every agent record it was appended to.
3. If the recipient is an agent: push `{ id, from, text, ts }` on its inbox,
   save `agents.json`, call `tick()`.
4. Return `{ to: <resolved id>, event }` (the recipient's copy, or the
   sender's for `otto`/`user`).

Text is trimmed; empty is an error; longer than 4000 chars is cut to 4000.

### 4.2 Scheduling — `tick()`

For each agent, in roster order, with a non-empty inbox and status not
`working`: if runs alive < `maxConcurrent`, start a run (§4.3). Otherwise it
stays queued. `tick()` runs after every delivery, after every run ends, once at
boot (recovery), and from the server's 30-second scheduler tick (a no-op with
empty inboxes). Nothing spawns when every inbox is empty.

### 4.3 A run

- The batch is the whole inbox at that moment. It moves to the agent record's
  `current` (`{ id, token, pid, startedAt, resumed, messages }`), the inbox is
  emptied, status → `working` (status event appended and broadcast).
- The prompt: when the batch has one message, `From <from>:\n<text>`; with
  several, `You have N new messages.\n\n` then each block separated by a blank
  line, oldest first.
- `token`: 32 hex chars from `randomBytes(16)`, new per run; it is the agent's
  credential for `/crew/*` (§5) and dies with the run.
- argv as in §3; cwd `crew.cwd`; env = `process.env` without
  `OTTO_CHANNEL_HOST` and `OTTO_SUPERVISED`.
- The claude binary is `~/.local/bin/claude` (as `jobs.ts`), overridable in
  the constructor; missing → status `error`, note `claude CLI not found`,
  batch back on the inbox.
- stdout is read line by line (`stream-json`). Per line:
  - `{"type":"system","subtype":"init","session_id":…}` → save `sessionId`
    on the agent record (first run) and continue.
  - `{"type":"assistant","message":{"content":[…]}}` → for every block with
    `type:"tool_use"` whose `name` does not start with `mcp__crew__`, append a
    `tool` event `{ tool: <name>, summary: toolSummary(name, input) }`; for
    every `text` block, remember the text (last one wins as "final text" if no
    `result` line arrives).
  - `{"type":"result", …}` → `result` (string) is the final text; the run
    counts as finished whatever `is_error` says.
  - anything else → ignored.
- Wall clock `runMinutes`: on expiry, SIGTERM the saved pid; the run ends as
  finished with a status note `stopped at the wall clock`; no retry.
- `toolSummary(name, input)`: `Read`/`Edit`/`Write`/`NotebookEdit` → the
  `file_path` made relative to cwd when under it; `Bash` → `command` collapsed
  to one line; `Grep` → `pattern` (+ ` in <path>` when given); `Glob` →
  `pattern`; `WebFetch` → `url`; anything else → `JSON.stringify(input)`.
  Always cut to 120 chars.

### 4.4 Run end

When the process exits:

- **Finished** (a `result` line was seen, or the wall clock stopped it):
  - *Fallback reply.* For each sender in the batch that is `otto` or `user` and
    received no `crew_message` from this agent during the run, deliver the final
    text (trimmed, cut to 4000) as a message from the agent to that sender,
    unless the final text is empty. This is what makes "what are you doing?"
    from the app get an answer even when the model just answers in prose.
  - Status → `waiting` if the run sent at least one message to an agent or to
    `otto`, else `idle`. Status event appended.
  - `current` cleared, pid cleared, `retried` cleared, `tick()`.
- **Crashed** (exit without a `result` line, not killed by us):
  - First time (`current.retried` unset): put the batch back at the front of the
    inbox, set `retried`, and if this run used `--resume`, drop `sessionId` so
    the retry starts a fresh session with a new `--session-id` (covers a lost
    or corrupt session file). Status → `idle`, note `crashed (exit <code>),
    retrying`, `tick()`.
  - Second time: batch back on the inbox, status → `error`, note
    `crashed twice (exit <code>)`. The next message to this agent, or a stop,
    clears it; a new message runs the whole inbox again (and may crash again:
    that is the user's signal to look at the thread).

### 4.5 Stop and restart

- `stop(id)`: SIGTERM `current.pid` if set (never any other pid, never
  pkill), drop `current` and the inbox, status → `idle`, note `stopped`.
  Returns the agent snapshot.
- Boot: load `agents.json`; any agent with `current` gets its batch back at the
  front of its inbox, `current` cleared, status `idle`, note `server
  restarted`; then `tick()`. (A run that outlived the old server is not
  reaped: its token is dead, so anything it posts is refused.)
- Inbox and `current` live in `agents.json`, so no accepted message is lost
  across a restart.

### 4.6 Persistence — `<state>/crew/`

- `agents.json` — `{ "agents": [AgentRecord] }`, written atomically (tmp +
  rename, mode 0600) on every change. `AgentRecord`:
  `{ id, role, status, sessionId?, inbox: [{id, from, text, ts}], current?: {id, token, pid?, startedAt, resumed, messages, retried?}, lastLine?, lastFrom?, lastAt?, note? }`.
  Roster order: pm, planner, designer, writers ascending, reviewers ascending.
- `<agentId>.jsonl` — append-only, one event (§5) per line, mode 0600. Never
  rewritten. Read back with `history(id, limit)`: the last `limit` lines,
  oldest first; a line that fails to parse is skipped.

## 5. Events and the message tool

### 5.1 `CrewEvent` — the one shape, on disk and on the wire

```json
{ "id": "a1b2c3d4", "agent": "planner", "kind": "message", "ts": "2026-10-22T10:00:00.000Z",
  "from": "otto", "to": "planner", "text": "Split docs/crew-spec.md into tickets." }

{ "id": "0f9e8d7c", "agent": "planner", "kind": "tool", "ts": "2026-10-22T10:00:04.210Z",
  "tool": "Read", "summary": "docs/crew-spec.md" }

{ "id": "5566aabb", "agent": "planner", "kind": "status", "ts": "2026-10-22T10:00:00.050Z",
  "status": "working", "note": "run 3" }
```

| field | type | on |
|---|---|---|
| `id` | string, 8 hex (client ids may be up to 64 chars) | all |
| `agent` | string, the thread this line belongs to | all |
| `kind` | `"message"` \| `"tool"` \| `"status"` | all |
| `ts` | ISO 8601 with milliseconds, UTC | all |
| `from`, `to` | string (agent id, `otto`, `user`) | message |
| `text` | string, ≤ 4000 chars | message |
| `tool` | string, the Claude Code tool name | tool |
| `summary` | string, ≤ 120 chars | tool |
| `status` | `idle` \| `working` \| `waiting` \| `error` | status |
| `note` | string, optional | status |

Dedupe key for a client: `agent + "/" + id`. A message between two agents
appears once in each of their files with the same `id`.

### 5.2 `CrewAgent` — the snapshot row

```json
{ "id": "writer-1", "role": "writer", "name": "Writer 1", "status": "working",
  "lastLine": "Ticket docs/tickets/crew-launcher.md is yours …", "lastFrom": "planner",
  "lastAt": "2026-10-22T10:01:12.000Z" }
```

`lastLine` is the last message event's text, whitespace collapsed, cut to 120
chars; `lastFrom` its sender; `lastAt` its `ts`. All three `null` until the
first message. `name` is `displayName(id)`.

### 5.3 The crew MCP server — `otto/crewmcp.ts`

A stdio MCP server (same SDK as `server.ts`), name `crew`, started by each run
through `--mcp-config`:

```json
{ "mcpServers": { "crew": { "command": "bun", "args": ["<otto>/crewmcp.ts"],
  "env": { "OTTO_CREW_URL": "http://127.0.0.1:<port>", "OTTO_CREW_TOKEN": "<run token>", "OTTO_CREW_SELF": "<agent id>" } } } }
```

Tools (ids `mcp__crew__crew_message`, `mcp__crew__crew_status`):

- `crew_message(to: string, text: string)` — description: "Send a message to a
  crew member (pm, planner, designer, writer, writer-N, reviewer, reviewer-N),
  to otto, or to user. The only way anything you do reaches anyone. One call
  per recipient; include paths and branch names, the recipient has no other
  context." Posts `POST <OTTO_CREW_URL>/crew/message` with
  `Authorization: Bearer <OTTO_CREW_TOKEN>` and JSON `{ "to", "text" }`.
  Returns the server's text: `delivered to writer-2` (the resolved id), or the
  error as an MCP error result (`isError: true`).
- `crew_status()` — `GET <OTTO_CREW_URL>/crew/status`, same header; returns
  one line per agent: `<id> — <status> — <lastFrom>: <lastLine> (<lastAt>)`.

### 5.4 Agent-side routes on the webhook listener

Served by the same `Bun.serve` as `/app`, dispatched before the webhook
fallback (`path.startsWith('/crew')`). Loopback only (same check as
`/status`), else 403. Auth: `Authorization: Bearer <run token>` matched in
constant time against every agent's `current.token`; the match names the
sender. No match → 401.

- `POST /crew/message` `{ "to": string, "text": string }` →
  `200 { "delivered": "<resolved id>" }`; `400 { "error": "…" }` for an empty
  text or an unknown recipient; `404` is never used here so the agent gets the
  reason in words.
- `GET /crew/status` → `200 { "self": "<agent id>", "agents": [CrewAgent] }`.

## 6. Otto's side

MCP tools in `server.ts`, declared beside `delegate`:

- `crew_message(to, text)` — "Hand work to the crew or answer a crew member.
  `to` is pm, planner, designer, writer, writer-N, reviewer, reviewer-N. Big
  jobs start with planner (or pm when the spec is not written yet); small jobs
  you do yourself. The reply comes back later as a crew event; you do not
  wait." Returns `delivered to planner (working)` or throws with the reason
  (unknown recipient; the webhook listener is off — the crew needs
  `webhook.token` in `access.json`).
- `crew_status()` — the `CrewAgent` list as lines: `planner — working — otto:
  Split docs/… (2m ago)`; `(no crew)` when inert.
- `crew_stop(id)` — stops that agent (§4.5); returns its new line.

A message addressed to `otto` arrives in the Otto session as a channel event:
`injectEvent('crew', content, { crew_from: <agent id> })`, with content

```
Crew message from <id> (<display name>):
<text>
```

followed by `taintOrigin('a crew agent wrote this')` so a crew message can
never count as the user's say-so. Otto relays what matters on the chat the
user last wrote from, answers the agent with `crew_message`, or stays silent.
`src` on anything Otto then sends is `crew` (via `srcOf`).

A message addressed to `user` goes to the app only (§7.2 frame plus the
app's own notification). With no app socket open the server also calls
`barkPush(text, false, { title: displayName(from), group: 'crew:<from>' })`,
the same push a closed app gets for Otto's messages; `barkPush` already does
nothing when `BARK_KEY` is unset or a socket is open.

CLAUDE.md gets a short `## Crew` section (server task) documenting the two
tools, the `crew` event and the `crew/` state dir; the plugin instructions
block is at its 2048-char cap and is not touched.

## 7. App protocol

Same listener, same bearer tokens, same `checkAppToken` gate as every `/app/*`
route. Paths are matched before the `switch` on exact paths.

### 7.1 HTTP

- `GET /app/crew` → `200 { "agents": [CrewAgent] }`. `agents` is `[]` while the
  crew is inert (§2). Order: roster order.
- `GET /app/crew/<id>/history?limit=200` → `200 { "events": [CrewEvent] }`,
  oldest first, the last `limit` (default 200, max 1000). `404` for an unknown
  agent id.
- `POST /app/crew/<id>/send` with JSON `{ "text": string, "id"?: string }` →
  `200 { "event": CrewEvent }` — the recorded message, `from:"user"`,
  `agent` and `to` set to the resolved agent (so `<id>` may be `writer`).
  `400 { "error": "…" }` for an empty text, `404` for an unknown recipient. A
  missing `claude` binary is not an HTTP error: the message is accepted and
  the agent turns `error` (§4.3).
- `POST /app/crew/<id>/stop` → `200 { "agent": CrewAgent }`, `404` unknown.

`<id>` matches `^[a-z]+(-[0-9]+)?$`.

### 7.2 WebSocket frames (otto → app, on the existing `/app` socket)

```json
{ "type": "crew_agents", "agents": [CrewAgent] }
{ "type": "crew", "event": CrewEvent }
```

- `crew_agents`: the full snapshot, sent on socket open when the crew is
  active, and again whenever the roster, any status, or any `lastLine`
  changes. The app replaces its list with it.
- `crew`: every event appended to any agent's file, in order, including both
  copies of an agent-to-agent message (same `id`, different `agent`). Live
  only: not queued in `appPending`; a reconnect re-fetches history. The app
  dedupes by `agent/id`.

Older apps ignore both frames (unknown `type`), older servers never send them.

### 7.3 What the app does with them

- **Chat list** (root after onboarding, only when `agents` is non-empty):
  Otto's row pinned first (avatar, "Otto", the Otto thread's last line and
  time), then one row per agent in roster order: a status dot (`idle` grey,
  `working` blue, `waiting` orange, `error` red), `name`, `lastLine` with
  `lastFrom` as a prefix when it is not the agent itself (`You:` for `user`,
  `Otto:` for `otto`, `Planner:` …), relative time from `lastAt`, and an
  unread badge. Styled as the iOS Messages conversation list: plain list rows,
  no cards, no tabs.
- **Unread**: per agent, kept on the phone (`UserDefaults`
  `crewSeen.<agentId>` = ts of the newest event seen). Unread = message events
  newer than that with `from != "user"`. Opening the thread marks everything
  seen.
- **Thread**: message events as bubbles — `from == "user"` on the right, blue;
  everything else on the left, grey. A left bubble whose `from` is not the
  thread's agent gets a small sender label above it (`Otto`, `Planner`, …);
  a bubble the agent sent to someone else (`from == agent`, `to != "user"`)
  gets a `to <name>` label. Tool events are compact monospaced rows (`Read
  docs/crew-spec.md`) between bubbles, shown only when "Show tool calls" is on
  (`@AppStorage("crewShowTools")`, default off). Status events draw a centred
  caption like the time stamps (`working · run 3`, `idle`, `error · crashed
  twice`). The composer sends `POST /app/crew/<id>/send` and appends the
  returned event (deduped against the socket's copy).
- **Notifications**: a `crew` frame with `kind == "message"`, `from` an agent
  id, and `agent == from` (the sender's copy, so one notification per
  message), when the app is not in the foreground or that thread is not on
  screen: title `displayName(from)`, body `text`, thread id `crew:<from>`,
  request id `crew/<id>`. Never for tool or status events, never for `user` or
  `otto` senders.
- **No crew** (`agents` empty, 404 on `/app/crew`, or a mock without the
  flag): the app opens straight into the Otto thread, exactly as today, with no
  list and no back button.

## 8. Server tests — `otto/tests/crew.test.ts`

`new Crew({ stateDir: <tmp>, config: () => cfg, cwd: () => <tmp>, port: () => 4589, claudeBin: '/bin/true', spawn: fake, now, onEvent, onAgents, onOtto, onUser })`
with a fake `Spawner`: `(o: { argv: string[]; cwd: string; env }) => { pid: number; stdout: ReadableStream<Uint8Array>; exited: Promise<number>; kill(): void }`
whose stdout the test feeds with stream-json lines. `await crew.settle()`
resolves once no run is in flight. Cases, at least:

1. inert: no config, no message → `agents()` is `[]`, `active()` false, no
   `crew/` dir created, no spawn.
2. `crew: {}` → roster `pm, planner, designer, writer-1, reviewer-1` in order,
   all `idle`, `lastLine` null.
3. `deliver('otto','planner',…)` spawns once; argv has `-p` with
   `From otto:\n…`, `--session-id` (a UUID), `--model opus`, the planner's
   `--tools`/`--allowedTools`, `--disallowedTools Read(//<tmp>/**)`,
   `--mcp-config` whose JSON names `crewmcp.ts` and carries
   `OTTO_CREW_TOKEN` = the record's `current.token` and `OTTO_CREW_SELF=planner`.
4. `roleArgs` per role matches the §3 table exactly (five assertions).
5. resume: after an `init` line with `session_id`, the next run uses
   `--resume <id>` and no `--session-id`.
6. queueing: a message to a `working` agent lands in its inbox, nothing new
   spawns; after the run ends it spawns with that batch (`You have 2 new
   messages.` when two arrived).
7. cap: `maxConcurrent: 1`, messages to planner and pm → one spawn; the second
   starts when the first ends.
8. pool: `to:"writer"` with `writers: 2` → `writer-1`; while it is working a
   second `to:"writer"` → `writer-2` created; a third queues on the shorter
   inbox; `writers: 1` never creates `writer-2`.
9. agent-side: `inbound(token, 'reviewer', text)` from writer-1's run token
   records the message in both files with the same id, pushes reviewer's inbox;
   a wrong token → null; `to:"otto"` calls `onOtto('writer-1', text)` and
   writes only the sender's file; `to:"user"` calls `onUser`.
10. tool events: an `assistant` line with `tool_use` blocks yields `tool`
    events with the expected `summary` (`Read` relative path, `Bash` one line,
    `mcp__crew__crew_message` skipped).
11. fallback reply: a batch from `user` whose run ends with `result` text and
    no crew_message → a message event `from:<agent> to:user` with that text and
    `onUser` called; when the run did message user, no fallback.
12. status after a run: `waiting` when it messaged another agent, `idle`
    otherwise; `working` while it runs.
13. crash: exit 1 without `result` → inbox has the batch back, `retried` set,
    status `idle`; with a `sessionId` the retry argv has `--session-id` not
    `--resume`; a second crash → `error`; a new message clears `error` and
    runs again.
14. stop: kills the fake's pid (the fake records `kill()`), empties the inbox,
    status `idle`.
15. restart: write `agents.json` with a `current` batch, construct a new
    `Crew`, the batch is back on the inbox and a spawn follows `tick()`.
16. JSONL: `history('planner')` returns the events appended, oldest first,
    `limit` honoured, a corrupt line skipped; message text over 4000 chars cut.
17. `displayName` and `toolSummary` table checks.

`bun test` must pass in full (currently 1665), including `docdrift` (every new
tool name, path and `crew/` state entry in CLAUDE.md must exist in code) and
`imports` (no duplicate import names in `server.ts`).

## 9. Things deliberately left out of this slice

A shared crew memory, cost accounting per agent, the PM's merge actually
running under a worktree lock, deep links from a notification into a thread,
reading an agent's transcript, and a Telegram surface. Each is a later ticket.
