/**
 * A stand-in for otto/server.ts that speaks the app's wire plus the additions of
 * design/hillclimb-2026-11-16/server-contract.md, so the app's side of them can be checked on a
 * simulator before the server has them. Delete it once otto-core does: its apptwin.ts then covers this.
 *
 *   bun Scripts/contract-server.ts <port> [connect-delay-ms] [old|noscreen|noimage]
 *
 * `old` answers as today's server does (none of the contract). `connect-delay-ms` holds the socket back,
 * for timing a launch through a slow tunnel. Launch the app at it with
 * `-onboarded YES -serverURL http://127.0.0.1:<port> -serverToken t`. Every request and frame is logged.
 *
 *   curl -X POST 'localhost:<port>/test/raise?kind=cal'      raise an approval that offers scopes (kind=draft: an email)
 *   curl -X POST 'localhost:<port>/test/revoke?token=t'      revoke a token as `apptokens.ts revoke` does: its sockets close with 4401,
 *                                                            and it gets a 401 from then on (token `revoked` always does)
 *   curl -X POST 'localhost:<port>/test/settle?id=a-cal'     settle it as the Mac would
 *   add &quiet=1 to either to send no socket frame, so only GET /app/approvals can tell the phone
 *   curl -X POST 'localhost:<port>/test/browser'             show a page Otto is stuck on, that it will hand over
 *   curl -X POST 'localhost:<port>/test/working'             Otto starts a turn ("Reading your mail"): the bubble that Stop is on
 *
 * Talk (otto-core's otto/talk.ts), unless `old`: talk.start is answered, the turn's audio is taken and dropped, and
 * talk.end gets a transcript, then an answer whose voice is the WAV clips in TALK_CLIPS (a folder of s<sentence>-<n>.wav,
 * cut as the Mac cuts them), sent TALK_PACE times slower than they play (1.3: a busy Mac), each late or early by up
 * to TALK_JITTER of its length, with a talk.timing frame and a pause before each sentence as the Mac's speech makes.
 * The answer also comes as a thread message, as otto-core sends it. TALK_DROP=speaking|ended|final|answer closes the
 * socket at that stage and stays unreachable for TALK_DOWN seconds (7): a lift, a tunnel, cellular. A closed socket's
 * turns go as otto-core's do: one still being said or written down is dropped, one already written down gets its answer
 * as a thread message only. POST /app/voice takes a note in once per id. Every turn Otto takes in is logged as
 * "TURN <n>", and one refused as already in as "deduped": one utterance should make exactly one TURN.
 * talk.screen is logged by size, never the picture. `noscreen` answers it as otto-core's talk.ts did before it knew
 * the frame, talk.error "unknown talk frame"; `noimage` takes `off` and refuses only a picture, so the refusal
 * lands in the middle of a turn.
 *
 * GET /app/dash/people lists made-up people, for iPhone Search.
 *
 * Pins as otto-core's pins.ts keeps them: GET /app/pins, POST /app/pins and /app/pins/unpin {id} (404 for an id history
 * hasn't got), and the whole list as a "pins" frame to every app on each change and on every connect. Your messages go
 * into history, so they can be pinned too.
 *   curl -X POST 'localhost:<port>/test/pin?id=h2'            pin (or /test/unpin) as the Mac would, from another device
 *   curl -X POST 'localhost:<port>/test/showoff?seconds=20'    show-off mode for 20 s: pins go empty, and come back with no frame
 */
const port = Number(process.argv[2] ?? 4599), delay = Number(process.argv[3] ?? 0), old = process.argv[4] === 'old', noscreen = process.argv[4] === 'noscreen', noimage = process.argv[4] === 'noimage'
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 23), ...a)
const sockets = new Set<any>()
import { readdirSync, readFileSync } from 'fs'
const clipDir = process.env.TALK_CLIPS, pace = Number(process.env.TALK_PACE ?? 1), jitter = Number(process.env.TALK_JITTER ?? 0)
const clips = clipDir ? readdirSync(clipDir).filter(f => /^s\d+-\d+\.wav$/.test(f)).sort() : []
const cuts = new Set<string>()
type Talk = { turn: string; phase: 'mic' | 'written' | 'answering'; audio: number }
const talks = new Map<unknown, Talk>()
const answerText = process.env.TALK_TEXT ?? 'Sunlight is a mix of every colour. The air scatters blue light much more than red.'
const dropAt = process.env.TALK_DROP, downFor = Number(process.env.TALK_DOWN ?? 7) * 1000
let downUntil = 0, dropped = false
const rows: Record<string, unknown>[] = [   // the thread since start, as /app/history serves it
  { dir: 'out', text: 'Morning. Two things today: the dentist at 16:00 and the boiler man between 9 and 11.', ts: new Date(Date.now() - 3600_000).toISOString(), id: 'h1' },
  { dir: 'out', text: '', ts: new Date(Date.now() - 3500_000).toISOString(), id: 'h2', card: { title: 'This week', blocks: [{ type: 'progress', value: 0.6, label: '3 of 5 workouts' }], actions: [{ label: 'Log a workout', data: 'log a workout' }] } },
]
type Pin = { id: string; pinnedAt: string; message: Record<string, unknown> }
let pins: Pin[] = [], showoffUntil = 0
const visiblePins = () => Date.now() < showoffUntil ? [] : pins
const pinsFrame = () => JSON.stringify({ type: 'pins', pins: visiblePins() })
/** POST /app/pins and /app/pins/unpin, as otto/http.ts's appPin: the list, or the status it refuses with. */
function setPin(id: unknown, on: boolean): Pin[] | number {
  if (typeof id !== 'string' || !id) return 400
  const row = rows.findLast(r => r.id === id)
  if (on && !row) return 404
  const at = pins.findIndex(p => p.id === id)
  if (on) pins = at >= 0 ? pins.map(p => p.id === id ? { ...p, message: row! } : p) : [...pins, { id, pinnedAt: new Date().toISOString(), message: row! }].slice(-20)
  else pins = pins.filter(p => p.id !== id)
  log(on ? 'pin' : 'unpin', id, '->', pins.length)
  for (const ws of sockets) ws.send(pinsFrame())
  return visiblePins()
}
const taken = new Map<string, string>()   // what Otto took in, by id: one per thing you said
function takeIn(id: string, how: string): boolean {
  if (taken.has(id)) { log(`deduped ${how} ${id} (already in by ${taken.get(id)})`); return false }
  taken.set(id, how); log(`TURN ${taken.size} by ${how} ${id}`)
  rows.push({ dir: 'in', text: 'Why is the sky blue?', ts: new Date().toISOString(), id })
  return true
}
/** Otto's answer as a thread message, to whoever is connected and to history. */
function answer(to: string) {
  const m = { type: 'message', id: crypto.randomUUID().slice(0, 8), text: answerText, ts: new Date().toISOString(), voice: null, reply_to: to }
  log('answer as a message to', to)
  rows.push({ dir: 'out', ...m }); for (const ws of sockets) ws.send(JSON.stringify(m))
}
function drop(ws: any, stage: string): boolean {
  if (dropped || dropAt !== stage) return false
  dropped = true; downUntil = Date.now() + downFor; log(`DROP at ${stage}, down ${downFor} ms`)
  ws.close(1001, 'lost'); return true
}
/** One answer's voice down the socket, clip by clip, at the Mac's pace. A WAV's length: its data bytes at 16-bit mono. */
async function speak(ws: any, turn: string) {
  let seq = 0, sentence = ''
  for (const f of clips) {
    if (seq === 4 && drop(ws, 'answer')) return
    if (cuts.has(turn)) return
    const wav = readFileSync(`${clipDir}/${f}`), seconds = (wav.length - 44) / 2 / wav.readUInt32LE(24)
    if (f.split('-')[0] !== sentence) {
      sentence = f.split('-')[0]
      await Bun.sleep(800)   // the next sentence's first clip, from the warm daemon
      ws.send(JSON.stringify({ type: 'talk.timing', turn, sentenceToAudioMs: 800 }))
    }
    await Bun.sleep(seconds * 1000 * (pace + (Math.random() * 2 - 1) * jitter))
    if (cuts.has(turn)) return
    log('clip', f, `${Math.round(seconds * 1000)} ms`)
    ws.send(JSON.stringify({ type: 'talk.audio', turn, seq: seq++, audio: wav.toString('base64'), format: 'wav' }))
  }
  ws.send(JSON.stringify({ type: 'talk.done', turn }))
}
const revoked = new Set(['revoked'])
const expires = () => new Date(Date.now() + 24 * 60_000).toISOString()
type Approval = Record<string, unknown> & { id: string }
const approvals = new Map<string, Approval>()
const alerted = new Set<string>()
const rules = new Map<string, Record<string, unknown>>([
  ['apply:diet', { id: 'apply:diet', label: 'memory clean-ups', created: '2026-11-03T09:12:00Z', uses: 4, lastUsed: '2026-11-14T03:00:00Z' }],
])
const memory = [
  { id: 'm1', store: 'durable', kind: 'preference', scope: 'me', name: 'coffee-order', description: 'Flat white, oat milk. No sugar.', updated: '2026-11-01T08:00:00Z', hits: 14, lastHitDays: 1 },
  { id: 'm2', store: 'durable', kind: 'fact', scope: 'me', name: 'office-wifi', description: 'Network: Studio-5G. Password in 1Password.', updated: '2026-09-02T12:00:00Z', hits: 0, badge: 'never' },
]
const person = (name: string, relationship: string | null, org: string | null, city: string | null, mentions: number[] = []) =>
  ({ name, relationship, city, timezone: null, org, notes: [{ at: '2026-11-02T09:00:00Z', text: 'Wants the deposit back by December.' }], inbound: 4, outbound: 2, lastContact: '2026-11-20T18:00:00Z', mentions })
const people = [person('Odalys Fenwright', 'landlord’s contact', 'Casa Lettings', 'Lisbon', [1]), person('Bruno Kestelmann', 'climbing partner', null, 'Porto'), person('Wren', null, null, null)]
const frame = (a: Approval) => JSON.stringify({ type: 'approval', ...a })
// The page Otto has open, for item 8: a grey picture, held or not.
const PAGE = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA='
let held = false, browsing = false
const browserFrame = () => JSON.stringify({ type: 'browser', image: PAGE, caption: 'accounts.example.com · stuck at the sign-in check', url: 'https://accounts.example.com/', ts: Date.now(), control: true, held })
const demo = (kind: string): Approval => kind === 'draft'
  ? { id: 'a-draft', title: 'Send email', summary: 'You asked me to tell the parents once the hall was booked.', files: [], expires: expires(),
      notes: old ? undefined : ['parents-3b@scuola.example is a list: everyone on it gets this.'],
      draft: old ? undefined : { channel: 'email', to: ['Marta Bianchi <marta@example.com>', 'parents-3b@scuola.example'], subject: 'Hall booked', body: 'Hi all,\n\nThe hall is booked.\n\nSam', attachments: ['Hall booking.pdf'] } }
  : { id: 'a-cal', title: 'Add 3 events to your calendar', summary: 'Adds the three parent meetings to your Home calendar.', files: [], expires: expires(),
      ...(old ? {} : { scopes: ['task', 'always'], rule: 'adding events to your calendar' }) }

Bun.serve({
  port, hostname: '127.0.0.1',
  async fetch(req, server) {
    const u = new URL(req.url), p = u.pathname
    if (p !== '/app') log(req.method, p + u.search, req.headers.get('x-otto-background') ? '(background)' : '')
    if (Date.now() < downUntil && !p.startsWith('/test/')) return new Response('down', { status: 503 })   // out of reach
    // A revoked device: every /app request, the socket's handshake too, gets otto/server.ts's bare 401.
    const token = req.headers.get('authorization')?.replace(/^Bearer /, '') ?? ''
    if (p.startsWith('/app') && revoked.has(token)) { log('401', p); return new Response(null, { status: 401 }) }
    if (p === '/test/revoke') {
      const t = u.searchParams.get('token') ?? ''; revoked.add(t)
      for (const ws of sockets) if (ws.data?.token === t) ws.close(4401, 'token revoked')
      return Response.json({ revoked: t })
    }
    if (p === '/app/voice' && req.method === 'POST' && !old) {
      const id = u.searchParams.get('id') ?? crypto.randomUUID()
      await req.arrayBuffer()
      log('note', id, 'via', u.searchParams.get('via') ?? '-')
      if (takeIn(id, 'note')) setTimeout(() => answer(id), 1500)
      return Response.json({ text: 'Why is the sky blue?' })
    }
    if (p === '/app') { await Bun.sleep(delay); return server.upgrade(req, { data: { token } }) ? undefined : new Response('upgrade failed', { status: 400 }) }
    if (p === '/test/raise') {
      const a = demo(u.searchParams.get('kind') ?? 'cal'); approvals.set(a.id, a); alerted.delete(a.id)
      if (u.searchParams.get('quiet') !== '1') for (const ws of sockets) ws.send(frame(a))
      // Item 7: the push waits 5 s for a phone to say it alerted.
      if (!old) setTimeout(() => log(alerted.has(a.id) ? `no push for ${a.id}: the app alerted` : `PUSH for ${a.id}: no app said it alerted`), 5000)
      return Response.json(a)
    }
    if (p === '/test/settle') { const id = u.searchParams.get('id')!; approvals.delete(id); if (u.searchParams.get('quiet') !== '1') for (const ws of sockets) ws.send(JSON.stringify({ type: 'approval_done', id })); return Response.json({ ok: true }) }
    if (p === '/app/history') return Response.json(rows)
    if (p === '/app/pins' && req.method === 'GET') return Response.json({ pins: visiblePins() })
    if ((p === '/app/pins' || p === '/app/pins/unpin') && req.method === 'POST') {
      const r = setPin(((await req.json().catch(() => ({}))) as { id?: unknown }).id, p === '/app/pins')
      return typeof r === 'number' ? new Response(null, { status: r }) : Response.json({ pins: r })
    }
    if (p === '/test/pin' || p === '/test/unpin') { const r = setPin(u.searchParams.get('id'), p === '/test/pin'); return Response.json({ pins: r }) }
    if (p === '/test/showoff') {
      showoffUntil = Date.now() + Number(u.searchParams.get('seconds') ?? 20) * 1000
      for (const ws of sockets) { ws.send(JSON.stringify({ type: 'showoff', on: true, until: new Date(showoffUntil).toISOString() })); ws.send(pinsFrame()) }
      return Response.json({ until: new Date(showoffUntil).toISOString() })
    }
    if (p === '/app/brief') return Response.json({ asOf: new Date().toISOString(), events: [], inbox: [], bulk: 0, loops: [], triggers: [] })
    if (p === '/app/settings') return Response.json({ toggles: [] })
    if (old) return new Response('not found', { status: 404 })
    if (p === '/app/approvals') return Response.json([...approvals.values()])
    if (p === '/test/working') { for (const ws of sockets) { ws.send(JSON.stringify({ type: 'typing', on: true })); ws.send(JSON.stringify({ type: 'status', text: 'Reading your mail' })) }; return Response.json({ ok: true }) }
    if (p === '/test/browser') { browsing = true; held = false; for (const ws of sockets) ws.send(browserFrame()); return Response.json({ ok: true }) }
    if (p === '/app/browser/hold') { held = (await req.json() as { hold: boolean }).hold === true; for (const ws of sockets) ws.send(browserFrame()); return Response.json({ held }) }
    if (p === '/app/browser/input') {
        if (!held) return new Response('not held', { status: 409 })
        const input = await req.json() as Record<string, unknown>
        log('input', 'text' in input ? '{"text": <not logged>}' : JSON.stringify(input))   // what's typed is never written down
        for (const ws of sockets) ws.send(browserFrame())
        return Response.json({ ok: true })
    }
    if (p === '/app/dash/rules') return Response.json({ rules: [...rules.values()] })
    if (p.startsWith('/app/dash/rules/') && req.method === 'DELETE') return Response.json({ revoked: rules.delete(decodeURIComponent(p.slice('/app/dash/rules/'.length))) })
    if (p === '/app/dash/people') return Response.json({ cards: people })
    if (p === '/app/dash/memory') return Response.json({ items: memory, canForget: true, summary: { text: 'You work in design.', note: 'Rewritten nightly.' }, generatedAt: new Date().toISOString(), graph: { c: [], clusters: [] } })
    if (p === '/app/dash/memory/item') return Response.json({ body: 'Flat white, oat milk. No sugar.' })
    if (p === '/app/dash/memory/forget') { const { id } = await req.json() as { id: string }; const i = memory.findIndex(m => m.id === id); if (i >= 0) memory.splice(i, 1); log('forget', id, i >= 0); return Response.json({ ok: i >= 0 }) }
    return new Response('not found', { status: 404 })
  },
  websocket: {
    open(ws) {
      sockets.add(ws); log('socket open')
      ws.send(JSON.stringify({ type: 'hello', acks: true, ...(old ? {} : { alerts: ['approval'], stop: true }), ...(Date.now() < showoffUntil ? { showoff: { until: new Date(showoffUntil).toISOString() } } : {}) }))
      ws.send(pinsFrame())
      for (const a of approvals.values()) ws.send(frame(a))
      if (browsing && !old) ws.send(browserFrame())
    },
    close(ws) {
      sockets.delete(ws); log('socket closed')
      // As otto-core does: a turn still being said or written down is dropped; one written down and not yet answered is
      // answered as a thread message only (Otto takes a few seconds), for whoever is connected by then and in history.
      const t = talks.get(ws); talks.delete(ws)
      if (t) cuts.add(t.turn)
      if (t?.phase === 'mic') log('dropped the turn being said', t.turn)
      if (t?.phase === 'written') setTimeout(() => answer(t.turn), 3000)
    },
    message(ws, m) {
      try {
        const f = JSON.parse(String(m)); const op = f.op ?? (f.type === 'message' ? f.id : undefined)
        if (f.type === 'talk.audio') {   // the turn's audio: counted, not kept
          const t = talks.get(ws)
          if (t?.phase === 'mic' && ++t.audio === 8) drop(ws, 'speaking')
          return
        }
        if (f.type === 'talk.screen') {   // your screen: its size logged, never the picture
          log('frame talk.screen', f.off ? 'off' : `${f.width}x${f.height} ${Math.round(Buffer.from(f.image ?? '', 'base64').length / 1024)} KB jpeg=${String(f.image).startsWith('/9j/')}`)
          if (!old && (noscreen || (noimage && !f.off))) ws.send(JSON.stringify({ type: 'talk.error', turn: talks.get(ws)?.turn, error: 'unknown talk frame' }))
          return
        }
        log('frame', String(m).slice(0, 300))
        if (!old && typeof f.type === 'string' && f.type.startsWith('talk.')) {
          const talk = talks.get(ws), turn = talk?.turn
          if (f.type === 'talk.start') { const t = crypto.randomUUID(); talks.set(ws, { turn: t, phase: 'mic', audio: 0 }); ws.send(JSON.stringify({ type: 'talk.ready', turn: t, sampleRate: 16000 })) }
          if (f.type === 'talk.cut') { if (turn) { cuts.add(turn); ws.send(JSON.stringify({ type: 'talk.cut', turn })) } }
          if (f.type === 'talk.stop') { if (turn) cuts.add(turn); talks.delete(ws) }
          if (f.type === 'talk.end' && talk?.phase === 'mic') {
            if (drop(ws, 'ended')) return
            const said = (t: Record<string, unknown>) => ws.send(JSON.stringify({ turn, ...t }))
            said({ type: 'talk.ending' }); said({ type: 'talk.final', text: 'Why is the sky blue?' })
            takeIn(turn!, 'stream')
            ws.send(JSON.stringify({ type: 'echo', id: turn, text: 'Why is the sky blue?', ts: new Date().toISOString() }))
            said({ type: 'talk.accepted' })
            talk.phase = 'written'
            if (drop(ws, 'final')) return
            setTimeout(() => {
              if (!sockets.has(ws) || talks.get(ws) !== talk) return
              talk.phase = 'answering'
              said({ type: 'talk.text', text: answerText }); answer(turn!)
              void speak(ws, turn!)
            }, 500)
          }
          return
        }
        if (f.type === 'approval_alerted') { alerted.add(f.id); return }
        if (f.type === 'message' && typeof f.id === 'string') rows.push({ dir: 'in', text: f.text ?? '', ts: new Date().toISOString(), id: f.id })
        if (f.type === 'stop') {
          // The turn ends: typing off, and a word in the thread about where it got to.
          for (const s of sockets) { s.send(JSON.stringify({ type: 'typing', on: false })); s.send(JSON.stringify({ type: 'todos', items: [] })) }
          for (const s of sockets) s.send(JSON.stringify({ type: 'message', id: crypto.randomUUID(), text: 'Stopped. Nothing was sent.', ts: new Date().toISOString() }))
        }
        if (f.type === 'approval') {
          const a = approvals.get(f.id)
          if (a && f.decision === 'approve' && f.scope === 'always' && typeof a.rule === 'string') rules.set(`rule:${a.id}`, { id: `rule:${a.id}`, label: a.rule, created: new Date().toISOString(), uses: 0 })
          approvals.delete(f.id); for (const s of sockets) s.send(JSON.stringify({ type: 'approval_done', id: f.id }))
          if (op) ws.send(JSON.stringify({ type: 'ack', id: op, ...(a ? {} : { gone: true }) }))
        } else if (op) ws.send(JSON.stringify({ type: 'ack', id: op }))
      } catch {}
    },
  },
})
log(`fake otto on 127.0.0.1:${port}, connect delay ${delay} ms${old ? ', today\'s server (no contract)' : ''}`)
