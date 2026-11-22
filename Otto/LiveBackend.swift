import CryptoKit
import Foundation

/// The real backend: a websocket to otto/server.ts over Tailscale.
///
/// Wire protocol (documented in full at the "App transport" block in server.ts):
///   GET  <server>/app          websocket, `Authorization: Bearer <token>`
///     app -> otto  {"type":"message","id":"<uuid>","text":"...","reply_to":"<id>"?}
///                  {"type":"tap","id":"<source wire ID>","op":"<uuid>","data":"<button data>","label":"..."}
///                  {"type":"react","op":"<uuid>","id":"<id>","emoji":"❤️"}
///                  {"type":"stop","op":"<uuid>"}   end the turn Otto is on; only to a server whose hello says "stop":true
///                  {"type":"approval","op":"<uuid>","id":"<id>","decision":"approve"|"decline","scope":"task"|"always"?}
///                   `scope` only when the approval frame offered it ("scopes") and you picked it; absent means this once
///                  Each op is kept until {"type":"ack","id":"<op or message id>"} comes back and resent on the
///                  next connect until it does; the server handles a repeat once. A server that says
///                  {"type":"hello","acks":true} on connect acks; with an older one the write is all we get.
///                  Its hello may add "alerts":["approval"]: the app then alerts for an approval itself and says so with
///                  {"type":"approval_alerted","id":"<id>"}; unacked within 5 s, the server pushes as before (server-contract.md, item 7).
///     otto -> app  {"type":"message","id":"...","text":"...","ts":"<ISO>","buttons":[{"label","data"} or {"label","url"}],
///                   "files":[{"id","name","kind"}]?,"voice":{"id","name","kind"}?,"reply_to":"<id>"?,
///                   "src"?,"why"?  (only on messages Otto sent unprompted)}
///                  {"type":"react","id":"<id>","emoji":"👍"}
///                  {"type":"edit","id":"<id>","text":"..."}   Otto rewrote a message it sent (also takes off its `otp`)
///                  {"type":"delete","id":"<id>"}   Otto deleted a message it sent (history names it in X-Otto-Deleted)
///                  a "message" may carry "otp":{"code","sender"?}: a verification code, shown in a drawer (OTP.swift)
///                  {"type":"status","text":"Reading ChatView.swift"}   while a reply is in the works
///                  {"type":"approval","id","title","summary","files","expires",…}   something that needs your yes (Approvals.swift);
///                   {"type":"approval_done","id"} once it's settled. It may carry "payment", and, from a server that has them,
///                   "scopes":["task","always"] with "rule":"…" (a yes that lasts) and "draft":{"channel","to","cc"?,"subject"?,"body"}
///                  {"type":"read","ids":["<uuid>"]}   your messages Otto has taken in
///                  {"type":"terminal","text":"first six words…","ts":"<ISO>"}   a prompt typed in Otto's terminal
///                  {"type":"echo","id","text","ts","shared"?}   yours, from the share sheet or the dashboard
///                  {"type":"todos","items":[{"text","status":"pending"|"in_progress"|"completed"}]}   Otto's to-do list while it works; [] when done
///                  {"type":"open_todos","items":[{"text","status":"pending"|"in_progress"}]}   its open to-dos, idle too; on connect and on change
///                  {"type":"browser","image":"data:image/jpeg;base64,…"|null,"caption":"example.com · clicks Generate","url","ts":<epoch ms>}
///                   what Otto is doing in Chrome, whole each time (≤ 1/s; on connect only while live); {"type":"browser","done":true} ends it.
///                   From a server that can hand the page over it may carry "control":true, and "held":true while you have it:
///                   POST /app/browser/hold {"hold":bool} and POST /app/browser/input (server-contract.md, item 8)
///                  a "message" (and its history row) may carry "quiet":true: a desktop was focused, so no banner
///                  {"type":"notify","id":"<newest held id>","text":"...","count":N}   focus ended: one banner for what was held, no bubble
///                  {"type":"reminders","items":[{"id","at":"<ISO>","text"}]}   every upcoming reminder, on connect and on change:
///                   each becomes a local notification (Reminders.swift), so it fires with the Mac off; we answer
///                   {"type":"reminders_ack","items":[{"id","at"}]} for those really pending, and the server stops alerting for them
///                  {"type":"jobs","jobs":[WireJob],"usage","github"}   the coding jobs, whole: on connect when the Mac has them
///                   and whenever one changes (Jobs.swift). A "message" (and its history row) may carry "jobs":["<job id>"]
///                   (or "job", the first of them): each draws as a card under that message. GET /app/jobs is the same list;
///                   POST /app/jobs/<answer|steer|stop|merge|resolve> {"id","text"?} acts on one and answers with it.
///                  {"type":"voice","id":"<id>","voice":{"id","name","kind"}|null}   the spoken version of a message
///                   that came with "voicePending":true (we connect with ?voiceLater=1); null = none coming
///   talk mode, on the same socket (otto-core's otto/talk.ts has the whole protocol; Talk.swift speaks it):
///     app -> otto  {"type":"talk.start"}, {"type":"talk.audio","audio":"<base64 16 kHz mono s16le, ≤ 200 ms>"},
///                  {"type":"talk.end"} (the phone's pause), {"type":"talk.cut"} (you talked over Otto), {"type":"talk.stop"}
///     otto -> app  talk.ready, talk.partial, talk.ending, talk.final, talk.accepted, talk.text, talk.audio (a playable
///                  WAV each, in order), talk.done, talk.cut, talk.error, talk.timing: each with the server's "turn"
///                  An older server ignores talk.start and never says talk.ready: talk then sends voice notes.
///   GET  <server>/app/approvals  [approval frame without "type"], the ones still pending ([] when none); not on every
///                   server yet, and a 404 means "can't say", never "none" (design/hillclimb-2026-11-16/server-contract.md)
///   GET  <server>/app/brief    brief JSON
///   GET  <server>/app/history?limit=  [{"dir":"in"|"out","text","ts","id"?,"kind":"terminal"?,"read"?, and on Otto's: "files","voice","reply_to","buttons"?,"src"?,"why"?}]   (X-Otto-Background: 1 from the background refresh)
///   GET  <server>/app/file/<id>  a file or voice clip from a message
///   POST <server>/app/photo?text=<caption>&id=<uuid>  JPEG body -> 204 once the server has it
///   POST <server>/app/voice?id=<uuid>&via=talk?    m4a body -> {"text": "<transcript>"}; an id the Mac already has
///                   (a talk turn's, saved over the stream) is answered and not taken in twice
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
    let openTodoLists: AsyncStream<[TodoItem]>
    let browserTiles: AsyncStream<BrowserTile?>
    let jobLists: AsyncStream<[CodeJob]>
    let desktopSync: DesktopSync?
    let reads: AsyncStream<[String]>
    let typing: AsyncStream<Bool>
    let approvalUpdates: AsyncStream<ApprovalUpdate>
    let voices: AsyncStream<(String, RemoteFile?)>
    let edits: AsyncStream<(String, String)>
    let deletes: AsyncStream<String>
    let notifies: AsyncStream<(String, String)>
    let conversationEvents: AsyncStream<ConversationEvent>

    /// The pair in use: http(s)://host:port and its token. Replaced only once the Mac has refused the token
    /// and setup has saved a new pair (setup runs in this same process, and the store keeps this backend).
    private var base: URL { lock.withLock { pair.base } }
    private var token: String { lock.withLock { pair.token } }
    private var pair: (base: URL, token: String)
    private let out: AsyncStream<Message>.Continuation
    private let reacted: AsyncStream<(String, String)>.Continuation
    private let status: AsyncStream<String>.Continuation
    private let todosOut: AsyncStream<[TodoItem]>.Continuation
    private let openTodosOut: AsyncStream<[TodoItem]>.Continuation
    private let browserOut: AsyncStream<BrowserTile?>.Continuation
    private let jobsOut: AsyncStream<[CodeJob]>.Continuation
    private let readIDs: AsyncStream<[String]>.Continuation
    private let typingOn: AsyncStream<Bool>.Continuation
    private let approvalOut: AsyncStream<ApprovalUpdate>.Continuation
    private let voiceOut: AsyncStream<(String, RemoteFile?)>.Continuation
    private let edited: AsyncStream<(String, String)>.Continuation
    private let deleted: AsyncStream<String>.Continuation
    private let notifyOut: AsyncStream<(String, String)>.Continuation
    private let conversationOut: AsyncStream<ConversationEvent>.Continuation
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
    /// What this connection's server leaves to the app to alert for (its hello's "alerts"): with "approval"
    /// there, it holds its own push for five seconds and drops it if the app says it alerted (server-contract.md, item 7).
    private var appAlerts: Set<String> = []
    var alertsApprovals: Bool { lock.withLock { live && appAlerts.contains("approval") } }
    /// Its hello's "stop": it takes {"type":"stop"} and ends the turn Otto is on.
    private var canStopTurn = false
    /// The last failure of each card page, by path (see `dashFailure`).
    private var dashFailures: [String: Int] = [:]
    func dashFailure(_ path: String) -> Int? { lock.withLock { dashFailures[path] } }
    /// Op ids the server has acked and nobody has collected yet, and those it acked as gone.
    private var acked: Set<String> = []
    private var gone: Set<String> = []
    private var loop: Task<Void, Never>?
    private var talkOut: AsyncStream<Data>.Continuation?
    /// Where talk.* frames go, in the order they came: the talk under way, if any.
    var talkSink: AsyncStream<Data>.Continuation? {
        get { lock.withLock { talkOut } }
        set { lock.withLock { talkOut?.finish(); talkOut = newValue } }
    }

    init(serverURL: URL, token: String) {
        let base = Self.origin(serverURL)
        pair = (base, token)
        desktopSync = DesktopSync(key: "otto.desktopSync.\(base.absoluteString)")
        defer { sweepKept() }
        (incoming, out) = AsyncStream.makeStream()
        (reactions, reacted) = AsyncStream.makeStream()
        (statuses, status) = AsyncStream.makeStream()
        (todoLists, todosOut) = AsyncStream.makeStream()
        (openTodoLists, openTodosOut) = AsyncStream.makeStream()
        (browserTiles, browserOut) = AsyncStream.makeStream()
        (jobLists, jobsOut) = AsyncStream.makeStream()
        (reads, readIDs) = AsyncStream.makeStream()
        (typing, typingOn) = AsyncStream.makeStream()
        (approvalUpdates, approvalOut) = AsyncStream.makeStream()
        (voices, voiceOut) = AsyncStream.makeStream()
        (edits, edited) = AsyncStream.makeStream()
        (deletes, deleted) = AsyncStream.makeStream()
        (notifies, notifyOut) = AsyncStream.makeStream()
        (conversationEvents, conversationOut) = AsyncStream.makeStream()
        loop = Task { [weak self] in await self?.run() }
    }

    deinit { loop?.cancel(); socket?.cancel(with: .goingAway, reason: nil); wsSession.invalidateAndCancel() }

    private static func origin(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if c.scheme == "ws" { c.scheme = "http" }
        if c.scheme == "wss" { c.scheme = "https" }
        c.path = ""
        return c.url!
    }

    /// Reads `serverURL` (e.g. "https://mac.tailnet.ts.net" or "http://100.x.y.z:4589")
    /// and `serverToken` from UserDefaults. Nil when either is unset.
    static func stored() -> (server: URL, token: String)? {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "serverURL")?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              let url = URL(string: s), url.host != nil,
              let t = d.string(forKey: "serverToken")?.trimmingCharacters(in: .whitespaces), !t.isEmpty
        else { return nil }
        return (url, t)
    }

    static func fromDefaults() -> LiveBackend? {
        guard let p = stored() else { return nil }
        ShareDirect.save(serverURL: p.server.absoluteString, token: p.token)   // the share sheet's way in on builds without an app group
        return LiveBackend(serverURL: p.server, token: p.token)
    }

    // MARK: OttoBackend

    func history(background: Bool, limit: Int, since: Date?) async -> [Message]? {
        let q = since.map { [URLQueryItem(name: "since", value: $0.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))] }
            ?? [URLQueryItem(name: "limit", value: String(limit))]
        guard let (data, resp) = await fetch("app/history", background: background, query: q),
              let rows = try? JSONDecoder().decode([WireHistory].self, from: data) else { return nil }
        // Messages the server took back: a "delete" patch each, so the thread drops its copy.
        let gone = (resp.value(forHTTPHeaderField: "X-Otto-Deleted") ?? "").split(separator: ",").map { id -> Message in
            var m = Message(from: .otto, text: "", date: .distantPast, serverID: String(id)); m.patch = "delete"; return m   // dated nowhere, so the sync cursor never moves for it
        }
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
                          thread: r.thread, level: r.level, src: r.src, why: r.why, scheduled: r.scheduled, recorded: r.recorded, card: r.card,
                          jobs: r.jobs ?? r.job.map { [$0] }, quiet: r.quiet)
            m.reaction = r.reaction
            if r.kind == "edit" || r.kind == "reaction" { m.patch = r.kind }
            return m
        } + gone
    }

    /// Straight onto the open socket, no outbox: the store keeps unsent messages
    /// (saved with the thread) and retries them, so they survive a restart.
    func send(_ text: String, id: String, replyTo: String?, shared: Bool) async -> Bool {
        if text.lowercased().hasPrefix("forget ") { dropKept() }   // a forget asked for in words: nothing kept outlives the asking
        var frame: [String: Any] = ["type": "message", "text": text, "id": id]
        if let replyTo { frame["reply_to"] = replyTo }
        if shared { frame["shared"] = true }
        return await handOver(frame, op: id)
    }

    /// A tap is kept in the thread like a message (its bubble is the label), under its own id.
    func tap(_ button: ActionButton, id: String, source: String?) async -> Bool {
        if (button.data ?? "").lowercased().hasPrefix("forget ") { dropKept() }   // the thread's "Forget it" chip
        return await handOver(DesktopSync.tapFrame(button, op: id, source: source), op: id)
    }

    /// A Wallet payment that couldn't go up over HTTP when it happened, kept in the thread until acked.
    func wallet(_ fields: [String: String], id: String) async -> Bool {
        await handOver(fields.merging(["type": "wallet", "op": id]) { a, _ in a }, op: id)
    }

    /// Straight to the socket and waited on, not the outbox: see OttoStore.decide. One op per
    /// approval, so "Try again" after a lost ack is recognised as the same decision.
    func decide(approval id: String, approve: Bool, scope: ApprovalScope) async -> ApprovalOutcome {
        let op = "approval-\(id)"
        var frame = ["type": "approval", "op": op, "id": id, "decision": approve ? "approve" : "decline"]
        if approve && scope != .once { frame["scope"] = scope.rawValue }
        switch await hand(frame, op: op) {
        case .notSent: return .notSent   // no socket, or the write failed: nothing reached the Mac
        case .unconfirmed: return .unknown
        case .confirmed: return lock.withLock { gone.remove(op) != nil } ? .gone : .done
        }
    }

    /// Ends the turn Otto is on. True once the Mac has the ask; it says in the thread that it stopped.
    func stopTurn() async -> Bool {
        let op = UUID().uuidString
        return await handOver(["type": "stop", "op": op], op: op)
    }
    var canStop: Bool { lock.withLock { live && canStopTurn } }

    func pendingApprovals(background: Bool) async -> [ApprovalRequest]? { await get("app/approvals", background: background) }

    /// Straight onto the socket, once, with no op. It only means anything inside the Mac's five seconds, so it
    /// is never queued or sent again; and the outbox waits for an ack per frame, which this one never gets:
    /// queued there, the first alert held up every frame behind it (the next approval's alert among them).
    func alerted(approval id: String) async {
        guard let task = lock.withLock({ socket }),
              let json = try? JSONSerialization.data(withJSONObject: ["type": "approval_alerted", "id": id]),
              let s = String(data: json, encoding: .utf8) else { return }
        try? await task.send(.string(s))
    }

    /// The Mac's own word for it, not just a 2xx: `held` as asked, `ok` true.
    func holdBrowser(_ hold: Bool) async -> Bool {
        struct Held: Decodable { let held: Bool }
        return (await postJSON("app/browser/hold", ["hold": hold]).flatMap { try? JSONDecoder().decode(Held.self, from: $0) })?.held == hold
    }
    func browserInput(_ input: BrowserInput) async -> Bool {
        struct Done: Decodable { let ok: Bool }
        return (await postJSON("app/browser/input", input.body).flatMap { try? JSONDecoder().decode(Done.self, from: $0) })?.ok == true
    }

    /// A small JSON POST: the body of a 2xx, or nil. Ten seconds: these answer a tap.
    private func postJSON(_ path: String, _ body: [String: Any]) async -> Data? {
        var req = URLRequest(url: base.appending(path: path), timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else { return nil }
        return data
    }

    func react(to id: String, emoji: String) async {
        await write(["type": "react", "id": id, "emoji": emoji])
    }

    /// True once the server has it: a write into a socket iOS froze also "succeeds", so a
    /// server that acks is waited on, and one that doesn't answer in time is a failure to retry.
    private func handOver(_ frame: [String: Any], op: String) async -> Bool { await hand(frame, op: op) == .confirmed }

    /// How far a frame got: never out of the phone, out with no ack, or acked.
    private enum Handed { case notSent, unconfirmed, confirmed }
    private func hand(_ frame: [String: Any], op: String) async -> Handed {
        guard let task = lock.withLock({ socket }),
              let json = try? JSONSerialization.data(withJSONObject: frame),
              let s = String(data: json, encoding: .utf8) else { return .notSent }
        do { try await task.send(.string(s)) } catch { return .notSent }
        return await confirmed(op, on: task) ? .confirmed : .unconfirmed
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

    func file(_ id: String) async throws -> Data? {
        var req = URLRequest(url: base.appending(path: "app/file/\(id)"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 404: return nil
        default: throw URLError(.badServerResponse)
        }
    }

    func sendVoice(_ m4a: Data, id: String, replyTo: String?, via: String?) async -> String? {
        guard let data = await post("app/voice", m4a, query: [URLQueryItem(name: "id", value: id)]
                                    + (replyTo.map { [URLQueryItem(name: "reply_to", value: $0)] } ?? [])
                                    + (via.map { [URLQueryItem(name: "via", value: $0)] } ?? [])) else { return nil }
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
        var refusals = 0
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
                lock.withLock { socket = task; live = true; connects += 1; acksOn = nil; acked = []; appAlerts = []; canStopTurn = false }
                // A live tile comes again right after connect; a `done` missed while away must not leave one up.
                browserOut.yield(nil)
                delay = 1; refusals = 0
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
                refusals = Pairing.refused(status: (task.response as? HTTPURLResponse)?.statusCode, close: task.closeCode.rawValue) ? refusals + 1 : 0
                lock.withLock { if socket === task { socket = nil }; live = false; drop = why }
                task.cancel(with: .goingAway, reason: nil)
                let stale = lock.withLock { () -> URLSession in
                    defer { wsSession = URLSession(configuration: .default) }
                    return wsSession
                }
                stale.invalidateAndCancel()
                // The Mac turned this token down, try after try: back to setup, and no more tries with it until a new
                // pair is saved. Anything else (no network, a Mac asleep or out of reach, a timeout) only waits for the next try.
                if refusals >= Pairing.refusalsToForget {
                    let gone = lock.withLock { pair }
                    await MainActor.run { if Pairing.forget(token: gone.token) { NotificationCenter.default.post(name: Pairing.forgotten, object: nil) } }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let s = LiveBackend.stored() else { continue }
                        let next = (base: Self.origin(s.server), token: s.token)
                        if next.base != gone.base || next.token != gone.token {
                            lock.withLock { pair = next }
                            ShareDirect.save(serverURL: s.server.absoluteString, token: s.token)
                            break
                        }
                    }
                    delay = 1; refusals = 0
                    continue
                }
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
    /// Back in front: a socket iOS froze, or one whose network changed under it, still reads as live until the
    /// 20 s keep-alive finds out. One quick ping settles it now; a dead one is dropped and the loop reconnects.
    func probe() async {
        guard let task = lock.withLock({ socket }) else { return }
        do { try await ping(task, timeout: 2) } catch { task.cancel(with: .goingAway, reason: nil) }
    }

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
            if k.type.hasPrefix("talk.") { talkSink?.yield(data); return }
            if k.type == "approval" { if let a = try? JSONDecoder().decode(ApprovalRequest.self, from: data) { approvalOut.yield(.show(a)) }; return }
            if k.type == "approval_done", let id = k.id { approvalOut.yield(.done(id)); return }
            // Here, not below: its `ts` is a number, which WireMessage would refuse.
            if k.type == "browser" { if let f = BrowserFrame(json: data) { browserOut.yield(f.tile) }; return }
            // The coding jobs, whole: on connect when the Mac has them, and whenever one changes.
            if k.type == "jobs" { if let w = try? JSONDecoder().decode(CodeJobs.self, from: data) { jobsOut.yield(w.jobs) }; return }
            if k.type == "hello" {
                struct Hello: Decodable { let alerts: [String]?; let stop: Bool? }
                let hello = try? JSONDecoder().decode(Hello.self, from: data)
                lock.withLock { acksOn = true; appAlerts = Set(hello?.alerts ?? []); canStopTurn = hello?.stop == true }
                return
            }
            if k.type == "reminders" {
                struct Frame: Decodable { let items: [ReminderItem] }
                guard let set = try? JSONDecoder().decode(Frame.self, from: data), let task = lock.withLock({ socket }) else { return }
                Task { if let ack = await Reminders.sync(set.items) { try? await task.send(.string(ack)) } }
                return
            }
            if k.type == "ack", let id = k.id { lock.withLock { acked.insert(id); if k.gone == true { gone.insert(id) } }; return }
            if let e = ConversationEvent.decode(type: k.type, data) { conversationOut.yield(e); return }
        }
        guard let f = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        if f.type == "react", let id = f.id, let emoji = f.emoji { reacted.yield((id, emoji)); return }
        if f.type == "edit", let id = f.id, let text = f.text { edited.yield((id, text)); return }
        if f.type == "delete", let id = f.id { deleted.yield(id); return }
        if f.type == "status", let text = f.text { status.yield(text); return }
        if f.type == "todos" { todosOut.yield(f.items ?? []); return }
        if f.type == "open_todos" { openTodosOut.yield(f.items ?? []); return }
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
                          files: f.files, audio: f.voice, thread: f.thread, level: f.level, src: f.src, why: f.why, scheduled: f.scheduled, recorded: f.recorded, card: f.card,
                          jobs: f.jobs ?? f.job.map { [$0] }, otp: f.otp, quiet: f.quiet))
    }

    /// A talk frame, now or never: talk keeps its own copy of a turn (its voice note) for when the socket is down.
    /// Sent in the order called, so a turn's audio stays in order.
    @discardableResult func talkSend(_ frame: [String: Any]) -> Bool {
        guard let task = lock.withLock({ live ? socket : nil }),
              let json = try? JSONSerialization.data(withJSONObject: frame), let s = String(data: json, encoding: .utf8) else { return false }
        task.send(.string(s)) { _ in }
        return true
    }

    #if DEBUG
    /// Talk's `-talkDrop`: the socket cut from under a turn, as a lift or a tunnel would.
    func dropSocket() { lock.withLock { socket }?.cancel(with: .goingAway, reason: nil) }
    #endif

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
        var req = URLRequest(url: c.url!, timeoutInterval: 15)   // a page somebody is looking at: a stalled Mac isn't waited on for the default minute
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let answer = try? await session.data(for: req)
        let code = (answer?.1 as? HTTPURLResponse)?.statusCode
        // Remembered so the page can say what went wrong: no such page on this Mac, an error there, or no answer.
        lock.withLock { dashFailures[path] = code.map { (200..<300).contains($0) ? nil : $0 } ?? 0 }
        // The Mac says it's gone: so is the copy kept here.
        if method == "GET", code == 404 || code == 410, let file = keptFile(path, query) { try? FileManager.default.removeItem(at: file) }
        guard let answer, let code, (200..<300).contains(code) else { return nil }
        // A page that was read is kept, so it can still be shown (as old) with the Mac out of reach: see dashKept.
        // Readable only while the phone is unlocked: these are your memories, people and money. A change made
        // through these routes (a forget, a rule taken back) drops everything kept, so nothing shown later as
        // "from 9:40" is something you have since removed.
        if method == "GET", let file = keptFile(path, query) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? answer.0.write(to: file, options: [.atomic, .completeFileProtection])
        } else if method != "GET", let folder = keptFile("", [])?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: folder)
        }
        return answer.0
    }

    /// Where a card page's last answer is kept: the Caches folder (iOS may clear it; nothing depends on it), one
    /// file per server, page and query, so another Mac's pages are never shown for this one.
    /// ponytail: no pruning of its own; a page per memory or schedule opened adds a small file until iOS clears Caches.
    private func keptFile(_ path: String, _ query: [URLQueryItem]) -> URL? {
        let name = base.absoluteString + "|" + path + "|" + query.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appending(path: "dash/\(hash).json")
    }

    /// A kept page is good for a day. Past that it isn't shown: something forgotten from another device, or
    /// through the chat, is gone from the Mac's own pages by its overnight tidy-up, and mustn't outlive that here.
    private static let keptFor: TimeInterval = 24 * 3600

    func dashKept(_ path: String, query: [URLQueryItem]) -> (data: Data, at: Date)? {
        guard let file = keptFile(path, query),
              let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        guard Date.now.timeIntervalSince(at) < Self.keptFor else { try? FileManager.default.removeItem(at: file); return nil }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (data, at)
    }

    /// Everything kept, dropped: asked for when the owner forgets something, whichever way the forgetting goes.
    func dropKept() {
        if let folder = keptFile("", [])?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
    }

    /// At launch: kept pages past their day are deleted, whether or not anyone opens them again.
    private func sweepKept() {
        guard let folder = keptFile("", [])?.deletingLastPathComponent() else { return }
        Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map({ Date.now.timeIntervalSince($0) >= Self.keptFor }) ?? true {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    func pipRequest(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async -> PipResponse? {
        #if DEBUG
        // `-pipsFixture` against a dead server: the list a returning user has saved, for screenshots.
        if let r = PipFixture.respond(method, path, query: query, body: body) { return r }
        #endif
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = "/" + path   // ids are already escaped: they're opaque and may hold a slash
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" { req.httpBody = body ?? Data("{}".utf8); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let (data, resp) = try? await session.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        return PipResponse(status: code, data: data)
    }

    func jobs() async -> [CodeJob]? {
        guard let w: CodeJobs = await get("app/jobs") else { return nil }
        return w.jobs
    }

    func jobAction(_ verb: JobVerb, id: String, text: String?) async -> JobOutcome {
        var req = URLRequest(url: base.appending(path: "app/jobs/\(verb.rawValue)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120   // a merge or a steer answers once the agent has it
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["id": id]
        if let text { body["text"] = text }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await session.data(for: req), let code = (resp as? HTTPURLResponse)?.statusCode else {
            return .failed(String(localized: "Can’t reach your Mac."))
        }
        if (200..<300).contains(code) { return .done(try? JSONDecoder().decode(CodeJob.self, from: data)) }
        struct Failure: Decodable { let error: String }
        return .failed((try? JSONDecoder().decode(Failure.self, from: data))?.error ?? String(localized: "Your Mac couldn’t do that."))
    }

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String, background: Bool = false, query: [URLQueryItem] = []) async -> T? {
        guard let (data, _) = await fetch(path, background: background, query: query) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// A 200's body and response, for the one read that needs a header (history's X-Otto-Deleted).
    private func fetch(_ path: String, background: Bool = false, query: [URLQueryItem] = []) async -> (Data, HTTPURLResponse)? {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!, timeoutInterval: 15)   // history and the brief at launch wait on this: not the default minute
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if background { req.setValue("1", forHTTPHeaderField: "X-Otto-Background") }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return (data, http)
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
        /// Coding jobs the reply started; `job` is the first of them, from a server that sends only one.
        let jobs: [String]?; let job: String?
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
        let jobs: [String]?; let job: String?
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
