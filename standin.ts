// Stand-in for Vapi's API (port 3001, what `-vapiHost localhost` points at) or the Otto server's
// voice upload (any other port). MODE: hang (accept, never answer) | ok (voice: 200, never reply) |
// bogus (call: a web call URL that goes nowhere).
const port = Number(process.env.PORT ?? 3001)
const mode = process.env.MODE ?? 'hang'
const t0 = Date.now()
const log = (s: string) => console.log(`${((Date.now() - t0) / 1000).toFixed(1)}s ${s}`)
Bun.serve({
  port,
  idleTimeout: 0,
  async fetch(req) {
    const u = new URL(req.url)
    log(`${req.method} ${u.pathname}${u.search}`)
    if (u.pathname === '/call/web' || u.pathname === '/app/voice') {
      await req.arrayBuffer()
      if (mode === 'hang') return new Promise<Response>(() => {})
      if (mode === 'bogus') return Response.json({ webCallUrl: 'https://nowhere.invalid/room', id: 'lab' })
      return Response.json({ text: 'Walkie test note' })
    }
    return new Response('not here', { status: 404 })
  },
})
log(`listening on ${port}, mode ${mode}`)
