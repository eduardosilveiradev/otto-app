/**
 * A stand-in for otto/server.ts that speaks the app's wire plus the additions of
 * design/hillclimb-2026-11-16/server-contract.md, so the app's side of them can be checked on a
 * simulator before the server has them. Delete it once otto-core does: its apptwin.ts then covers this.
 *
 *   bun Scripts/contract-server.ts <port> [connect-delay-ms] [old]
 *
 * `old` answers as today's server does (none of the contract). `connect-delay-ms` holds the socket back,
 * for timing a launch through a slow tunnel. Launch the app at it with
 * `-onboarded YES -serverURL http://127.0.0.1:<port> -serverToken t`. Every request and frame is logged.
 *
 *   curl -X POST 'localhost:<port>/test/raise?kind=cal'      raise an approval that offers scopes (kind=draft: an email)
 *   curl -X POST 'localhost:<port>/test/settle?id=a-cal'     settle it as the Mac would
 *   add &quiet=1 to either to send no socket frame, so only GET /app/approvals can tell the phone
 *   curl -X POST 'localhost:<port>/test/browser'             show a page Otto is stuck on, that it will hand over
 */
const port = Number(process.argv[2] ?? 4599), delay = Number(process.argv[3] ?? 0), old = process.argv[4] === 'old'
const log = (...a: unknown[]) => console.log(new Date().toISOString().slice(11, 23), ...a)
const sockets = new Set<any>()
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
const frame = (a: Approval) => JSON.stringify({ type: 'approval', ...a })
// The page Otto has open, for item 8: a grey picture, held or not.
const PAGE = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA='
let held = false, browsing = false
const browserFrame = () => JSON.stringify({ type: 'browser', image: PAGE, caption: 'accounts.example.com · stuck at the sign-in check', url: 'https://accounts.example.com/', ts: Date.now(), control: true, held })
const demo = (kind: string): Approval => kind === 'draft'
  ? { id: 'a-draft', title: 'Send email', summary: 'You asked me to tell the parents once the hall was booked.', files: [], expires: expires(), scopes: old ? undefined : ['task'],
      notes: old ? undefined : ['parents-3b@scuola.example is a list: everyone on it gets this.'],
      draft: old ? undefined : { channel: 'email', to: ['Marta Bianchi <marta@example.com>', 'parents-3b@scuola.example'], subject: 'Hall booked', body: 'Hi all,\n\nThe hall is booked.\n\nSam', attachments: ['Hall booking.pdf'] } }
  : { id: 'a-cal', title: 'Add 3 events to your calendar', summary: 'Adds the three parent meetings to your Home calendar.', files: [], expires: expires(),
      ...(old ? {} : { scopes: ['task', 'always'], rule: 'adding events to your calendar' }) }

Bun.serve({
  port, hostname: '127.0.0.1',
  async fetch(req, server) {
    const u = new URL(req.url), p = u.pathname
    if (p !== '/app') log(req.method, p + u.search, req.headers.get('x-otto-background') ? '(background)' : '')
    if (p === '/app') { await Bun.sleep(delay); return server.upgrade(req) ? undefined : new Response('upgrade failed', { status: 400 }) }
    if (p === '/test/raise') {
      const a = demo(u.searchParams.get('kind') ?? 'cal'); approvals.set(a.id, a); alerted.delete(a.id)
      if (u.searchParams.get('quiet') !== '1') for (const ws of sockets) ws.send(frame(a))
      // Item 7: the push waits 5 s for a phone to say it alerted.
      if (!old) setTimeout(() => log(alerted.has(a.id) ? `no push for ${a.id}: the app alerted` : `PUSH for ${a.id}: no app said it alerted`), 5000)
      return Response.json(a)
    }
    if (p === '/test/settle') { const id = u.searchParams.get('id')!; approvals.delete(id); if (u.searchParams.get('quiet') !== '1') for (const ws of sockets) ws.send(JSON.stringify({ type: 'approval_done', id })); return Response.json({ ok: true }) }
    if (p === '/app/history') return Response.json([{ dir: 'out', text: 'Morning. Two things today: the dentist at 16:00 and the boiler man between 9 and 11.', ts: new Date(Date.now() - 3600_000).toISOString(), id: 'h1' }])
    if (p === '/app/brief') return Response.json({ asOf: new Date().toISOString(), events: [], inbox: [], bulk: 0, loops: [], triggers: [] })
    if (p === '/app/settings') return Response.json({ toggles: [] })
    if (old) return new Response('not found', { status: 404 })
    if (p === '/app/approvals') return Response.json([...approvals.values()])
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
    if (p === '/app/dash/memory') return Response.json({ items: memory, canForget: true, summary: { text: 'You work in design.', note: 'Rewritten nightly.' }, generatedAt: new Date().toISOString(), graph: { c: [], clusters: [] } })
    if (p === '/app/dash/memory/item') return Response.json({ body: 'Flat white, oat milk. No sugar.' })
    if (p === '/app/dash/memory/forget') { const { id } = await req.json() as { id: string }; const i = memory.findIndex(m => m.id === id); if (i >= 0) memory.splice(i, 1); log('forget', id, i >= 0); return Response.json({ ok: i >= 0 }) }
    return new Response('not found', { status: 404 })
  },
  websocket: {
    open(ws) {
      sockets.add(ws); log('socket open')
      ws.send(JSON.stringify({ type: 'hello', acks: true, ...(old ? {} : { alerts: ['approval'], stop: true }) }))
      for (const a of approvals.values()) ws.send(frame(a))
      if (browsing && !old) ws.send(browserFrame())
    },
    close(ws) { sockets.delete(ws); log('socket closed') },
    message(ws, m) {
      log('frame', String(m).slice(0, 300))
      try {
        const f = JSON.parse(String(m)); const op = f.op ?? (f.type === 'message' ? f.id : undefined)
        if (f.type === 'approval_alerted') { alerted.add(f.id); return }
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
