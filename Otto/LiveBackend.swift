import Foundation

/// The real backend: a websocket to otto/server.ts over Tailscale.
///
/// Wire protocol (documented in full at the "App transport" block in server.ts):
///   GET  <server>/app          websocket, `Authorization: Bearer <token>`
///     app -> otto  {"type":"message","id":"<uuid>","text":"...","reply_to":"<id>"?}
///                  {"type":"tap","id":"<source wire ID>","op":"<uuid>","data":"<button data>","label":"..."}
///                  {"type":"react","op":"<uuid>","id":"<id>","emoji":"❤️"}
///                  {"type":"approval","op":"<uuid>","id":"<id>","decision":"approve"|"decline"}
///                  Each op is kept until {"type":"ack","id":"<op or message id>"} comes back and resent on the
///                  next connect until it does; the server handles a repeat once. A server that says
///                  {"type":"hello","acks":true} on connect acks; with an older one the write is all we get.
///     otto -> app  {"type":"message","id":"...","text":"...","ts":"<ISO>","buttons":[{"label","data"} or {"label","url"}],
///                   "files":[{"id","name","kind"}]?,"voice":{"id","name","kind"}?,"reply_to":"<id>"?,
///                   "src"?,"why"?  (only on messages Otto sent unprompted)}
///                  {"type":"react","id":"<id>","emoji":"👍"}
///                  {"type":"edit","id":"<id>","text":"..."}   Otto rewrote a message it sent (also takes off its `otp`)
///                  a "message" may carry "otp":{"code","sender"?}: a verification code, shown in a drawer (OTP.swift)
///                  {"type":"status","text":"Reading ChatView.swift"}   while a reply is in the works
///                  {"type":"read","ids":["<uuid>"]}   your messages Otto has taken in
///                  {"type":"terminal","text":"first six words…","ts":"<ISO>"}   a prompt typed in Otto's terminal
///                  {"type":"echo","id","text","ts","shared"?}   yours, from the share sheet or the dashboard
///                  {"type":"todos","items":[{"text","status":"pending"|"in_progress"|"completed"}]}   Otto's to-do list while it works; [] when done
///                  a "message" (and its history row) may carry "quiet":true: a desktop was focused, so no banner
///                  {"type":"notify","id":"<newest held id>","text":"...","count":N}   focus ended: one banner for what was held, no bubble
///                  {"type":"voice","id":"<id>","voice":{"id","name","kind"}|null}   the spoken version of a message
///                   that came with "voicePending":true (we connect with ?voiceLater=1); null = none coming
///   GET  <server>/app/brief    brief JSON
///   GET  <server>/app/history?limit=  [{"dir":"in"|"out","text","ts","id"?,"kind":"terminal"?,"read"?, and on Otto's: "files","voice","reply_to","buttons"?,"src"?,"why"?}]   (X-Otto-Background: 1 from the background refresh)
///   GET  <server>/app/file/<id>  a file or voice clip from a message
///   POST <server>/app/photo?text=<caption>&id=<uuid>  JPEG body -> 204 once the server has it
///   POST <server>/app/voice?id=<uuid>    m4a body -> {"text": "<transcript>"}
///   POST <server>/app/ask     {"id","text","via":"siri"|"here","place"?} -> {"reply"?:{"id","text","buttons"}}  (Siri; waits for Otto's first reply)
///   POST <server>/app/photo?snap=1&id=<uuid>  JPEG body -> the same answer, for the Snap intent
///   POST <server>/app/health  JSON {notifications, backgroundRefresh, keepAwake, shareConfigured, lastRefresh?, build, version, ios, reason} -> 204
///   <server>/app/dash/*         the web dashboard's API (otto/dash-types.ts), same token
final class LiveBackend: OttoBackend {
    let name = "Otto server"
    var isLive: Bool { lock.withLock { live } }
    var connections: Int { lock.withLock { connects } }
    /// Why the socket last dropped, and when — shown under Status, since a drop that only
    /// happens on one network can't be seen from the Mac.
    var lastDrop: String? { lock.withLock { drop } }
    private var drop: String?
    let incoming: AsyncStream<Message>
    let reactions: AsyncStream<(String, String)>
    let statuses: AsyncStream<String>
    let todoLists: AsyncStream<[TodoItem]>
    let desktopSync: DesktopSync?
    let reads: AsyncStream<[String]>
    let typing: AsyncStream<Bool>
    let approvalUpdates: AsyncStream<ApprovalUpdate>
    let voices: AsyncStream<(String, RemoteFile?)>
    let edits: AsyncStream<(String, String)>
    let notifies: AsyncStream<(String, String)>

    private let base: URL       // http(s)://host:port
    private let token: String
    private let out: AsyncStream<Message>.Continuation
    private let reacted: AsyncStream<(String, String)>.Continuation
    private let status: AsyncStream<String>.Continuation
    private let todosOut: AsyncStream<[TodoItem]>.Continuation
    private let readIDs: AsyncStream<[String]>.Continuation
    private let typingOn: AsyncStream<Bool>.Continuation
    private let approvalOut: AsyncStream<ApprovalUpdate>.Continuation
    private let voiceOut: AsyncStream<(String, RemoteFile?)>.Continuation
    private let edited: AsyncStream<(String, String)>.Continuation
    private let notifyOut: AsyncStream<(String, String)>.Continuation
    private let session = URLSession(configuration: .default)
    /// The socket's own session, replaced on every drop. After iOS suspends the app a
    /// session can be left where every new websocket handshake fails while plain HTTP on
    /// the shared one still works: "not connected" for good, with history still syncing.
    private var wsSession = URLSession(configuration: .default)
    private let lock = NSLock()
    private var live = false
    private var connects = 0
    private var socket: URLSessionWebSocketTask?
    /// Tapbacks not yet acked, oldest first. On disk, so one made just before the app is
    /// killed still goes. (Messages, taps and payments are kept in the thread instead.)
    private var outbox: [String] = UserDefaults.standard.stringArray(forKey: "otto.outbox") ?? [] {
        didSet { UserDefaults.standard.set(outbox, forKey: "otto.outbox") }
    }
    /// Whether this connection's server acks (its hello); nil until it has said, or 3s have passed.
    private var acksOn: Bool?
    /// Op ids the server has acked and nobody has collected yet, and those it acked as gone.
    private var acked: Set<String> = []
    private var gone: Set<String> = []
    private var loop: Task<Void, Never>?

    init(serverURL: URL, token: String) {
        var c = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        if c.scheme == "ws" { c.scheme = "http" }
        if c.scheme == "wss" { c.scheme = "https" }
        c.path = ""
        base = c.url!
        self.token = token
        desktopSync = DesktopSync(key: "otto.desktopSync.\(base.absoluteString)")
        (incoming, out) = AsyncStream.makeStream()
        (reactions, reacted) = AsyncStream.makeStream()
        (statuses, status) = AsyncStream.makeStream()
        (todoLists, todosOut) = AsyncStream.makeStream()
        (reads, readIDs) = AsyncStream.makeStream()
        (typing, typingOn) = AsyncStream.makeStream()
        (approvalUpdates, approvalOut) = AsyncStream.makeStream()
        (voices, voiceOut) = AsyncStream.makeStream()
        (edits, edited) = AsyncStream.makeStream()
        (notifies, notifyOut) = AsyncStream.makeStream()
        loop = Task { [weak self] in await self?.run() }
    }

    deinit { loop?.cancel(); socket?.cancel(with: .goingAway, reason: nil); wsSession.invalidateAndCancel() }

    /// Reads `serverURL` (e.g. "https://mac.tailnet.ts.net" or "http://100.x.y.z:4589")
    /// and `serverToken` from UserDefaults. Nil when either is unset.
    static func fromDefaults() -> LiveBackend? {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "serverURL")?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              let url = URL(string: s), url.host != nil,
              let t = d.string(forKey: "serverToken")?.trimmingCharacters(in: .whitespaces), !t.isEmpty
        else { return nil }
        ShareDirect.save(serverURL: s, token: t)   // the share sheet's way in on builds without an app group
        return LiveBackend(serverURL: url, token: t)
    }

    // MARK: OttoBackend

    func history(background: Bool, limit: Int, since: Date?) async -> [Message] {
        let q = since.map { [URLQueryItem(name: "since", value: $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))] }
            ?? [URLQueryItem(name: "limit", value: String(limit))]
        guard let rows: [WireHistory] = await get("app/history", background: background, query: q) else { return [] }
        // Ids make the merge exact: yours come back under the UUID this phone sent them with.
        // One of yours without an id (written before they had one) can't be matched, so it's left out.
        return rows.filter { $0.dir != "in" || $0.id != nil || $0.kind == "terminal" }.map { r in
            var m = r.kind == "terminal" ? Self.terminal(r.text, ts: r.ts)
            : r.dir == "in"
                // Preserve the exact wire ID, including UUID casing from other devices.
                ? Message(id: r.id.flatMap(UUID.init(uuidString:)) ?? UUID(), from: .me, text: r.text, date: Self.date(r.ts) ?? Date(), shared: r.shared,
                          serverID: r.id, read: r.read)
                : Message(from: .otto, text: r.text, date: Self.date(r.ts) ?? Date(),
                          buttons: (r.buttons ?? []).map { ActionButton(label: $0.label, data: $0.data, url: $0.url, copy: $0.copy) },
                          isVoice: r.voice != nil || r.voicePending == true, serverID: r.id, replyTo: r.reply_to, files: r.files, audio: r.voice,
                          thread: r.thread, level: r.level, src: r.src, why: r.why, scheduled: r.scheduled, recorded: r.recorded, card: r.card, quiet: r.quiet)
            m.reaction = r.reaction
            if r.kind == "edit" || r.kind == "reaction" { m.patch = r.kind }
            return m
        }
    }

    /// Straight onto the open socket, no outbox: the store keeps unsent messages
    /// (saved with the thread) and retries them, so they survive a restart.
    func send(_ text: String, id: String, replyTo: String?, shared: Bool) async -> Bool {
        var frame: [String: Any] = ["type": "message", "text": text, "id": id]
        if let replyTo { frame["reply_to"] = replyTo }
        if shared { frame["shared"] = true }
        return await handOver(frame, op: id)
    }

    /// A tap is kept in the thread like a message (its bubble is the label), under its own id.
    func tap(_ button: ActionButton, id: String, source: String?) async -> Bool {
        await handOver(DesktopSync.tapFrame(button, op: id, source: source), op: id)
    }

    /// A Wallet payment that couldn't go up over HTTP when it happened, kept in the thread until acked.
    func wallet(_ fields: [String: String], id: String) async -> Bool {
        await handOver(fields.merging(["type": "wallet", "op": id]) { a, _ in a }, op: id)
    }

    /// Straight to the socket and waited on, not the outbox: see OttoStore.decide. One op per
    /// approval, so "Try again" after a lost ack is recognised as the same decision.
    func decide(approval id: String, approve: Bool) async -> ApprovalOutcome {
        let op = "approval-\(id)"
        guard await handOver(["type": "approval", "op": op, "id": id, "decision": approve ? "approve" : "decline"], op: op) else { return .unknown }
        return lock.withLock { gone.remove(op) != nil } ? .gone : .done
    }

    func react(to id: String, emoji: String) async {
        await write(["type": "react", "id": id, "emoji": emoji])
    }

    /// True once the server has it: a write into a socket iOS froze also "succeeds", so a
    /// server that acks is waited on, and one that doesn't answer in time is a failure to retry.
    private func handOver(_ frame: [String: Any], op: String) async -> Bool {
        guard let task = lock.withLock({ socket }),
              let json = try? JSONSerialization.data(withJSONObject: frame),
              let s = String(data: json, encoding: .utf8) else { return false }
        do { try await task.send(.string(s)) } catch { return false }
        return await confirmed(op, on: task)
    }

    /// The server's ack for `op`, or true at once for a server too old to send one.
    /// ponytail: polls every 50ms rather than keeping continuations; there are only ever a few waiting.
    private func confirmed(_ op: String, on task: URLSessionWebSocketTask) async -> Bool {
        let end = Date.now.addingTimeInterval(3)
        while lock.withLock({ acksOn == nil && socket === task }), Date.now < end { try? await Task.sleep(for: .milliseconds(50)) }
        let acks = lock.withLock { () -> Bool in
            if acksOn == nil && socket === task { acksOn = false }   // no hello: a server from before acks
            return acksOn == true
        }
        guard acks else { return lock.withLock { socket === task } }
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            let (got, alive) = lock.withLock { (acked.remove(op) != nil, socket === task) }
            if got { return true }
            if !alive { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// True once the server has it (a 2xx), which it sends only after writing it down.
    // ponytail: the server's /app/photo and /app/voice don't read reply_to yet; it's sent so they can.
    func sendPhoto(_ jpeg: Data, caption: String, id: String, replyTo: String?, shared: Bool) async -> Bool {
        await post("app/photo", jpeg, query: [URLQueryItem(name: "id", value: id)]
                   + (replyTo.map { [URLQueryItem(name: "reply_to", value: $0)] } ?? [])
                   + (caption.isEmpty ? [] : [URLQueryItem(name: "text", value: caption)])
                   + (shared ? [URLQueryItem(name: "shared", value: "1")] : [])) != nil
    }

    func file(_ id: String) async -> Data? {
        var req = URLRequest(url: base.appending(path: "app/file/\(id)"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    func sendVoice(_ m4a: Data, id: String, replyTo: String?) async -> String? {
        guard let data = await post("app/voice", m4a, query: [URLQueryItem(name: "id", value: id)]
                                    + (replyTo.map { [URLQueryItem(name: "reply_to", value: $0)] } ?? [])) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data))?["text"] ?? ""
    }

    /// What a Siri intent gets back: Otto's first reply, if it came within the server's wait.
    /// A nil `reply` means it's still coming and will land in the thread.
    struct Answer: Decodable {
        struct Reply: Decodable { let id: String; let text: String; let buttons: [ActionButton] }
        let reply: Reply?
    }

    /// Nil when the server can't be reached or predates /app/ask (404), so the caller falls back.
    func ask(id: String, text: String, via: String, place: [String: Any]? = nil) async -> Answer? {
        var body: [String: Any] = ["id": id, "text": text, "via": via]
        if let place { body["place"] = place }
        guard let json = try? JSONSerialization.data(withJSONObject: body), let data = await post("app/ask", json) else { return nil }
        return (try? JSONDecoder().decode(Answer.self, from: data)) ?? Answer(reply: nil)
    }

    /// A Wallet payment from the Shortcuts "Transaction" automation. Otto files it without
    /// answering, so nothing waits on a reply. False when the server can't be reached.
    func logPayment(id: String, amount: String, merchant: String, card: String) async -> Bool {
        let body: [String: Any] = ["id": id, "text": "", "via": "wallet", "amount": amount, "merchant": merchant, "card": card]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else { return false }
        return await post("app/ask", json) != nil
    }

    /// A photo to be filed. An older server answers 204 with no body: delivered, nothing to say.
    func snap(_ jpeg: Data, note: String, id: String) async -> Answer? {
        guard let data = await post("app/photo", jpeg, query: [URLQueryItem(name: "id", value: id), URLQueryItem(name: "snap", value: "1")]
                                    + (note.isEmpty ? [] : [URLQueryItem(name: "text", value: note)])) else { return nil }
        return (try? JSONDecoder().decode(Answer.self, from: data)) ?? Answer(reply: nil)
    }

    /// The protocol can't say "unavailable", so a failed fetch is an empty brief
    /// stamped `.distantPast` — never something that looks like a clear day.
    func brief() async -> Brief {
        guard let b: WireBrief = await get("app/brief") else {
            return Brief(asOf: .distantPast, events: [], inbox: [], bulk: 0, loops: [], triggers: [])
        }
        return Brief(
            asOf: Self.date(b.asOf) ?? Date(),
            events: (b.events ?? []).compactMap { e in
                Self.date(e.start).map { CalEvent(title: e.title, start: $0, minutes: e.minutes) }
            },
            inbox: (b.inbox ?? []).map { MailItem(from: $0.from, subject: $0.subject) },
            bulk: b.bulk,
            loops: b.loops.map { Loop(id: $0.id ?? UUID().uuidString, title: $0.title, due: $0.due.flatMap(Self.date)) },
            triggers: b.triggers.compactMap { t in Self.date(t.next).map { Trigger(title: t.title, next: $0) } }
        )
    }

    // MARK: Socket

    private func run() async {
        var delay: Double = 1
        while !Task.isCancelled {
            var url = URLComponents(url: base.appendingPathComponent("app"), resolvingAgainstBaseURL: false)!
            url.scheme = url.scheme == "https" ? "wss" : "ws"
            url.queryItems = [URLQueryItem(name: "voiceLater", value: "1")]   // text first, its voice after
            var req = URLRequest(url: url.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = lock.withLock { wsSession }.webSocketTask(with: req)
            task.resume()
            // Receive from the first moment. URLSession only reads control frames while a receive
            // is pending, so a frame the server sends on connect (pending replies, an approval)
            // used to sit unread in front of the pong: the handshake ping timed out (-1001),
            // every reconnect, for as long as the server kept something to send.
            let frames = AsyncThrowingStream<URLSessionWebSocketTask.Message, Error> { c in
                let reader = Task { do { while true { c.yield(try await task.receive()) } } catch { c.finish(throwing: error) } }
                c.onTermination = { _ in reader.cancel() }
            }
            do {
                try await ping(task)                    // handshake done, token accepted
                lock.withLock { socket = task; live = true; connects += 1; acksOn = nil; acked = [] }
                delay = 1
                // Not awaited: the flush waits on acks, which only the loop below reads.
                Task { [weak self] in await self?.flush(task) }
                // Proxies (Funnel) cut idle sockets; a ping every 20s keeps it open
                // and turns a dead one into a receive error, i.e. a prompt reconnect.
                let keepalive = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        do { try await self?.ping(task) } catch { task.cancel(with: .goingAway, reason: nil); return }
                    }
                }
                defer { keepalive.cancel() }
                for try await m in frames { handle(m) }
                throw URLError(.networkConnectionLost)   // the stream ends only when the socket does
            } catch {
                let why = "\(Date.now.formatted(date: .omitted, time: .shortened)): \(error.localizedDescription)"
                    + (task.closeCode != .invalid ? " (close \(task.closeCode.rawValue))" : "")
                lock.withLock { if socket === task { socket = nil }; live = false; drop = why }
                task.cancel(with: .goingAway, reason: nil)
                let stale = lock.withLock { () -> URLSession in
                    defer { wsSession = URLSession(configuration: .default) }
                    return wsSession
                }
                stale.invalidateAndCancel()
            }
            try? await Task.sleep(for: .seconds(delay))
            // Short cap: the usual drop is iOS suspending the app, and coming back
            // to it should reconnect within seconds, not half a minute.
            delay = min(delay * 2, 5)
        }
    }

    /// Bounded: a handshake caught in a network switch (wifi to cellular) can leave the pong
    /// handler never called, and an unbounded wait here parks the reconnect loop for good,
    /// asleep while HTTP (voice, history) still works.
    private func ping(_ task: URLSessionWebSocketTask, timeout: Double = 10) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let done = NSLock()
            nonisolated(unsafe) var resumed = false
            let finish: @Sendable (Error?) -> Void = { err in
                guard done.withLock({ let first = !resumed; resumed = true; return first }) else { return }
                if let err { k.resume(throwing: err) } else { k.resume() }
            }
            task.sendPing { finish($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(URLError(.timedOut)) }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        if desktopSync?.receive(data) == true { return }
        // Before WireMessage: an approval's `files` aren't RemoteFiles, so it would fail that decode whole.
        struct Kind: Decodable { let type: String; let id: String?; let gone: Bool? }
        if let k = try? JSONDecoder().decode(Kind.self, from: data) {
            if k.type == "approval" { if let a = try? JSONDecoder().decode(ApprovalRequest.self, from: data) { approvalOut.yield(.show(a)) }; return }
            if k.type == "approval_done", let id = k.id { approvalOut.yield(.done(id)); return }
            if k.type == "hello" { lock.withLock { acksOn = true }; return }
            if k.type == "ack", let id = k.id { lock.withLock { acked.insert(id); if k.gone == true { gone.insert(id) } }; return }
        }
        guard let f = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        if f.type == "react", let id = f.id, let emoji = f.emoji { reacted.yield((id, emoji)); return }
        if f.type == "edit", let id = f.id, let text = f.text { edited.yield((id, text)); return }
        if f.type == "status", let text = f.text { status.yield(text); return }
        if f.type == "todos" { todosOut.yield(f.items ?? []); return }
        if f.type == "read", let ids = f.ids { readIDs.yield(ids); return }
        if f.type == "typing", let on = f.on { typingOn.yield(on); return }
        if f.type == "terminal", let text = f.text, let ts = f.ts { out.yield(Self.terminal(text, ts: ts)); return }
        if f.type == "voice", let id = f.id { voiceOut.yield((id, f.voice)); return }
        if f.type == "notify", let id = f.id, let text = f.text {
            notifyOut.yield((id, (f.count ?? 1) > 1 ? "\(text) (+\(f.count! - 1) more)" : text)); return
        }
        // Yours, sent from somewhere other than this thread (the share sheet, the dashboard). Same id as /app/history gives it.
        if f.type == "echo", let text = f.text {
            out.yield(Message(id: f.id.flatMap(UUID.init(uuidString:)) ?? UUID(), from: .me, text: text, date: Self.date(f.ts) ?? Date(), shared: f.shared, serverID: f.id))
            return
        }
        guard f.type == "message", let text = f.text else { return }
        out.yield(Message(from: .otto, text: text, date: Self.date(f.ts) ?? Date(),
                          buttons: (f.buttons ?? []).map { ActionButton(label: $0.label, data: $0.data, url: $0.url, copy: $0.copy) },
                          isVoice: f.voice != nil || f.voicePending == true, serverID: f.id, replyTo: f.reply_to,
                          files: f.files, audio: f.voice, thread: f.thread, level: f.level, src: f.src, why: f.why, scheduled: f.scheduled, recorded: f.recorded, card: f.card, otp: f.otp, quiet: f.quiet))
    }

    private func write(_ frame: [String: String]) async {
        var frame = frame
        frame["op"] = UUID().uuidString
        guard let json = try? JSONSerialization.data(withJSONObject: frame),
              let s = String(data: json, encoding: .utf8) else { return }
        lock.withLock { outbox.append(s) }
        if let task = lock.withLock({ socket }) { await flush(task) }
    }

    /// Sends queued frames in order, each kept until the server has it; the rest wait for the next connect.
    /// Two flushes at once can send a frame twice, which the server's op ids make harmless.
    private func flush(_ task: URLSessionWebSocketTask) async {
        while let next = lock.withLock({ outbox.first }) {
            guard let data = next.data(using: .utf8),
                  let op = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["op"] as? String else {
                lock.withLock { if outbox.first == next { outbox.removeFirst() } }   // unreadable: drop it
                continue
            }
            do { try await task.send(.string(next)) } catch { return }
            guard await confirmed(op, on: task) else { return }
            lock.withLock { if outbox.first == next { outbox.removeFirst() } }
        }
    }

    func release() async -> Release? { await get("app/update") }

    func gate() async -> GateReply? { await get("app/gate") }
    func stamps() async -> StampsReply? { await get("app/stamps") }

    func setLoop(_ id: String, done: Bool) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": id, "done": done]) else { return false }
        return await post("app/loop", body) != nil
    }

    func speakReplies(set: Bool?) async -> Bool? {
        struct Settings: Decodable { let speakReplies: Bool }
        if let set {
            guard let body = try? JSONSerialization.data(withJSONObject: ["speakReplies": set]),
                  let data = await post("app/settings", body) else { return nil }
            return (try? JSONDecoder().decode(Settings.self, from: data))?.speakReplies
        }
        let s: Settings? = await get("app/settings")
        return s?.speakReplies
    }

    func settings(flip id: String?) async -> SettingsPage? {
        guard let id else { return await get("app/settings") }
        guard let body = try? JSONSerialization.data(withJSONObject: ["id": id]),
              let data = await post("app/settings", body) else { return nil }
        return try? JSONDecoder().decode(SettingsPage.self, from: data)
    }

    /// The phone's own state for otto_status. Fire-and-forget: a server without the route
    /// answers 404/405 and post() returns nil, which is the right amount of noise (none).
    func postHealth(_ fields: [String: Any]) async {
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { return }
        _ = await post("app/health", body)
    }

    @MainActor private var lastSeenSent: Int64 = 0

    /// Best effort, including on older servers: never queue or repeat an attempted timestamp.
    @MainActor func seen(_ date: Date) async {
        let ts = Int64((date.timeIntervalSince1970 * 1000).rounded())
        guard !Task.isCancelled, ts > lastSeenSent,
              let body = try? JSONSerialization.data(withJSONObject: ["ts": ts]) else { return }
        lastSeenSent = ts
        _ = await post("app/seen", body, contentType: "application/json")
    }

    func snooze(_ change: SnoozeChange?) async -> Snooze? {
        var req = URLRequest(url: base.appendingPathComponent("app/snooze"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let change {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = switch change {
            case .minutes(let m): ["minutes": m]
            case .clear: ["clear": true]
            }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? Snooze.decoder.decode(Snooze.self, from: data)
    }

    func dashData(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async -> Data? {
        var c = URLComponents(url: base.appending(path: "app/dash/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return data
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, background: Bool = false, query: [URLQueryItem] = []) async -> T? {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if background { req.setValue("1", forHTTPHeaderField: "X-Otto-Background") }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Uploads go over plain HTTP, not the socket: its frames are capped at 64 KB.
    private func post(_ path: String, _ body: Data, query: [URLQueryItem] = [], contentType: String? = nil) async -> Data? {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.timeoutInterval = 120   // transcription runs before the response
        guard let (data, resp) = try? await session.upload(for: req, from: body),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return data
    }

    /// The server stamps the live frame and the history line with the same ts, so the id
    /// made from it is how the store knows a replayed one is already in the thread.
    private static func terminal(_ text: String, ts: String) -> Message {
        Message(from: .terminal, text: text, date: date(ts) ?? Date(), serverID: "terminal|\(ts)|\(text)")
    }

    // MARK: Wire types

    private struct WireButton: Decodable { let label: String; let data: String?; let url: String?; let copy: String? }
    private struct WireMessage: Decodable {
        let type: String; let id: String?; let text: String?; let ts: String?; let buttons: [WireButton]?
        let files: [RemoteFile]?; let voice: RemoteFile?; let reply_to: String?; let emoji: String?; let ids: [String]?; let on: Bool?
        let thread: String?; let level: String?; let src: String?; let why: String?
        let voicePending: Bool?; let scheduled: [DashTrigger]?; let recorded: [RecordedCard]?; let shared: Bool?
        let card: Card?
        let items: [TodoItem]?
        let otp: OTPCode?
        let quiet: Bool?; let count: Int?
    }
    /// Otto's entries carry what the live frame did, so a message that arrived while the
    /// socket was asleep still has its photos, voice and buttons.
    private struct WireHistory: Decodable {
        let dir: String; let text: String; let ts: String; let id: String?; let kind: String?
        let files: [RemoteFile]?; let voice: RemoteFile?; let voicePending: Bool?; let reply_to: String?; let buttons: [WireButton]?
        let thread: String?; let level: String?; let src: String?; let why: String?; let scheduled: [DashTrigger]?; let recorded: [RecordedCard]?; let card: Card?
        let shared: Bool?; let reaction: String?; let read: Bool?; let quiet: Bool?
    }
    private struct WireBrief: Decodable {
        struct Event: Decodable { let title: String; let start: String; let minutes: Int }
        struct Mail: Decodable { let from: String; let subject: String }
        struct LoopItem: Decodable { let id: String?; let title: String; let due: String? }
        struct Armed: Decodable { let title: String; let next: String }
        let asOf: String
        let events: [Event]?
        let inbox: [Mail]?
        let bulk: Int
        let loops: [LoopItem]
        let triggers: [Armed]
    }

    /// Server timestamps are ISO 8601 with milliseconds; loop dues may be a bare date.
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = opts
            if opts == [.withFullDate] { f.timeZone = .current }
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
