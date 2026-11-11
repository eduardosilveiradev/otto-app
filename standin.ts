// Stand-in for the Otto server's /app routes. MODE applies to every /app route, the websocket included:
//   ok   – answers like a working server (settings, ask with a reply, share socket acks, photo 200)
//   500  – every /app route answers 500
//   401  – every /app route answers 401 (token refused)
//   hang – accepts the connection and never answers
//   slow – like ok, but /app/settings answers after 9 s (to catch a check in flight)
// A dead host is just a port with nothing listening.
const port = Number(process.env.PORT ?? 4599)
const mode = process.env.MODE ?? 'ok'
const t0 = Date.now()
const log = (s: string) => console.log(`${((Date.now() - t0) / 1000).toFixed(1)}s ${s}`)

Bun.serve({
  port,
  idleTimeout: 0,
  async fetch(req, server) {
    const u = new URL(req.url)
    const body = req.method === 'POST' && u.pathname === '/app/ask' ? await req.text() : ''
    log(`${req.method} ${u.pathname}${u.search} ${body ? body.slice(0, 120) : ''}`)
    if (!u.pathname.startsWith('/app')) return new Response('not here', { status: 404 })
    if (mode === 'hang') return new Promise<Response>(() => {})
    if (mode === '500') return new Response('boom', { status: 500 })
    if (mode === '401') return new Response(null, { status: 401 })
    if (u.pathname === '/app') return server.upgrade(req) ? undefined : new Response(null, { status: 400 })
    if (u.pathname === '/app/history') return Response.json([])
    if (mode === 'slow' && u.pathname === '/app/settings') await Bun.sleep(9000)
    if (u.pathname === '/app/settings') return Response.json({ speakReplies: true })
    if (u.pathname === '/app/ask') return Response.json({ reply: { id: 'r1', text: 'Thursday works for me.', buttons: [] } })
    if (u.pathname === '/app/photo') { await req.arrayBuffer(); return Response.json({}) }
    return new Response(null, { status: 404 })
  },
  websocket: {
    open(ws) { ws.send(JSON.stringify({ type: 'hello' })); log('ws open') },
    message(ws, m) {
      const f = JSON.parse(String(m))
      log(`ws ${String(m).slice(0, 120)}`)
      if (f.type === 'message') ws.send(JSON.stringify({ type: 'ack', id: f.id }))
    },
  },
})
log(`listening on ${port}, mode ${mode}`)
