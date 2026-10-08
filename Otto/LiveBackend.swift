import Foundation

/// The real backend: a websocket to otto/server.ts over Tailscale.
///
/// Wire protocol (documented in full at the "App transport" block in server.ts):
///   GET  <server>/app          websocket, `Authorization: Bearer <token>`
///     app -> otto  {"type":"message","id":"<uuid>","text":"...","reply_to":"<id>"?}
///                  {"type":"tap","data":"<button data>","label":"..."}
///                  {"type":"react","id":"<id>","emoji":"❤️"}
///     otto -> app  {"type":"message","id":"...","text":"...","ts":"<ISO>","buttons":[{"label","data"}],
///                   "files":[{"id","name","kind"}]?,"voice":{"id","name","kind"}?,"reply_to":"<id>"?}
///                  {"type":"react","id":"<id>","emoji":"👍"}
///                  {"type":"status","text":"Reading ChatView.swift"}   while a reply is in the works
///                  {"type":"read","ids":["<uuid>"]}   your messages Otto has taken in
///   GET  <server>/app/brief    brief JSON
///   GET  <server>/app/history  [{"dir":"in"|"out","text","ts","id"?, and on Otto's: "files","voice","reply_to","buttons"?}]
///   GET  <server>/app/file/<id>  a file or voice clip from a message
///   POST <server>/app/photo?text=<caption>&id=<uuid>  JPEG body
///   POST <server>/app/voice?id=<uuid>    m4a body -> {"text": "<transcript>"}
final class LiveBackend: OttoBackend {
    let name = "Otto server"
    var isLive: Bool { lock.withLock { live } }
    var connections: Int { lock.withLock { connects } }
    let incoming: AsyncStream<Message>
    let reactions: AsyncStream<(String, String)>
    let statuses: AsyncStream<String>
    let reads: AsyncStream<[String]>
    let typing: AsyncStream<Bool>

    private let base: URL       // http(s)://host:port
    private let token: String
    private let out: AsyncStream<Message>.Continuation
    private let reacted: AsyncStream<(String, String)>.Continuation
    private let status: AsyncStream<String>.Continuation
    private let readIDs: AsyncStream<[String]>.Continuation
    private let typingOn: AsyncStream<Bool>.Continuation
    private let session = URLSession(configuration: .default)
    private let lock = NSLock()
    private var live = false
    private var connects = 0
    private var socket: URLSessionWebSocketTask?
    /// Frames written while disconnected; sent first thing on reconnect.
    private var outbox: [String] = []
    private var loop: Task<Void, Never>?

    init(serverURL: URL, token: String) {
        var c = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        if c.scheme == "ws" { c.scheme = "http" }
        if c.scheme == "wss" { c.scheme = "https" }
        c.path = ""
        base = c.url!
        self.token = token
        (incoming, out) = AsyncStream.makeStream()
        (reactions, reacted) = AsyncStream.makeStream()
        (statuses, status) = AsyncStream.makeStream()
        (reads, readIDs) = AsyncStream.makeStream()
        (typing, typingOn) = AsyncStream.makeStream()
        loop = Task { [weak self] in await self?.run() }
    }

    deinit { loop?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }

    /// Reads `serverURL` (e.g. "https://mac.tailnet.ts.net" or "http://100.x.y.z:4589")
    /// and `serverToken` from UserDefaults. Nil when either is unset.
    static func fromDefaults() -> LiveBackend? {
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "serverURL")?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              let url = URL(string: s), url.host != nil,
              let t = d.string(forKey: "serverToken")?.trimmingCharacters(in: .whitespaces), !t.isEmpty
        else { return nil }
        return LiveBackend(serverURL: url, token: t)
    }

    // MARK: OttoBackend

    func history() async -> [Message] {
        guard let rows: [WireHistory] = await get("app/history") else { return [] }
        // Ids make the merge exact: yours come back under the UUID this phone sent them with.
        return rows.map { r in
            r.dir == "in"
                ? Message(id: r.id.flatMap(UUID.init(uuidString:)) ?? UUID(), from: .me, text: r.text, date: Self.date(r.ts) ?? Date())
                : Message(from: .otto, text: r.text, date: Self.date(r.ts) ?? Date(),
                          buttons: (r.buttons ?? []).map { ActionButton(label: $0.label, data: $0.data) },
                          isVoice: r.voice != nil, serverID: r.id, replyTo: r.reply_to, files: r.files, audio: r.voice)
        }
    }

    /// Straight onto the open socket, no outbox: the store keeps unsent messages
    /// (saved with the thread) and retries them, so they survive a restart.
    func send(_ text: String, id: String, replyTo: String?) async -> Bool {
        var frame = ["type": "message", "text": text, "id": id]
        if let replyTo { frame["reply_to"] = replyTo }
        guard let task = lock.withLock({ socket }),
              let json = try? JSONSerialization.data(withJSONObject: frame),
              let s = String(data: json, encoding: .utf8) else { return false }
        do { try await task.send(.string(s)); return true } catch { return false }
    }

    func tap(_ button: ActionButton) async {
        await write(["type": "tap", "data": button.data, "label": button.label])
    }

    func react(to id: String, emoji: String) async {
        await write(["type": "react", "id": id, "emoji": emoji])
    }

    func sendPhoto(_ jpeg: Data, caption: String, id: String) async {
        _ = await post("app/photo", jpeg, query: [URLQueryItem(name: "id", value: id)]
                       + (caption.isEmpty ? [] : [URLQueryItem(name: "text", value: caption)]))
    }

    func file(_ id: String) async -> Data? {
        var req = URLRequest(url: base.appending(path: "app/file/\(id)"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    func sendVoice(_ m4a: Data, id: String) async -> String {
        guard let data = await post("app/voice", m4a, query: [URLQueryItem(name: "id", value: id)]),
              let r = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return r["text"] ?? ""
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
            loops: b.loops.map { Loop(title: $0.title, due: $0.due.flatMap(Self.date)) },
            triggers: b.triggers.compactMap { t in Self.date(t.next).map { Trigger(title: t.title, next: $0) } }
        )
    }

    // MARK: Socket

    private func run() async {
        var delay: Double = 1
        while !Task.isCancelled {
            var url = URLComponents(url: base.appendingPathComponent("app"), resolvingAgainstBaseURL: false)!
            url.scheme = url.scheme == "https" ? "wss" : "ws"
            var req = URLRequest(url: url.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: req)
            task.resume()
            do {
                try await ping(task)                    // handshake done, token accepted
                lock.withLock { socket = task; live = true; connects += 1 }
                delay = 1
                await flush(task)
                // Proxies (Funnel) cut idle sockets; a ping every 20s keeps it open
                // and turns a dead one into a receive error, i.e. a prompt reconnect.
                let keepalive = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(20))
                        do { try await self?.ping(task) } catch { task.cancel(with: .goingAway, reason: nil); return }
                    }
                }
                defer { keepalive.cancel() }
                while true { handle(try await task.receive()) }
            } catch {
                lock.withLock { if socket === task { socket = nil }; live = false }
                task.cancel(with: .goingAway, reason: nil)
            }
            try? await Task.sleep(for: .seconds(delay))
            // Short cap: the usual drop is iOS suspending the app, and coming back
            // to it should reconnect within seconds, not half a minute.
            delay = min(delay * 2, 5)
        }
    }

    private func ping(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            task.sendPing { err in if let err { k.resume(throwing: err) } else { k.resume() } }
        }
    }

    private func handle(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let f = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        if f.type == "react", let id = f.id, let emoji = f.emoji { reacted.yield((id, emoji)); return }
        if f.type == "status", let text = f.text { status.yield(text); return }
        if f.type == "read", let ids = f.ids { readIDs.yield(ids); return }
        if f.type == "typing", let on = f.on { typingOn.yield(on); return }
        guard f.type == "message", let text = f.text else { return }
        out.yield(Message(from: .otto, text: text, date: Self.date(f.ts) ?? Date(),
                          buttons: (f.buttons ?? []).map { ActionButton(label: $0.label, data: $0.data) },
                          isVoice: f.voice != nil, serverID: f.id, replyTo: f.reply_to,
                          files: f.files, audio: f.voice))
    }

    private func write(_ frame: [String: String]) async {
        guard let json = try? JSONSerialization.data(withJSONObject: frame),
              let s = String(data: json, encoding: .utf8) else { return }
        lock.withLock { outbox.append(s) }
        if let task = lock.withLock({ socket }) { await flush(task) }
    }

    /// Sends queued frames in order; anything that fails stays for the next connect.
    private func flush(_ task: URLSessionWebSocketTask) async {
        while let next = lock.withLock({ outbox.first }) {
            do { try await task.send(.string(next)) } catch { return }
            lock.withLock { if outbox.first == next { outbox.removeFirst() } }
        }
    }

    func release() async -> Release? { await get("app/update") }

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

    // MARK: HTTP

    private func get<T: Decodable>(_ path: String) async -> T? {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Uploads go over plain HTTP, not the socket: its frames are capped at 64 KB.
    /// ponytail: no retry — a failed upload is lost; queue them like `outbox` if that bites.
    private func post(_ path: String, _ body: Data, query: [URLQueryItem] = []) async -> Data? {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120   // transcription runs before the response
        guard let (data, resp) = try? await session.upload(for: req, from: body),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return data
    }

    // MARK: Wire types

    private struct WireButton: Decodable { let label: String; let data: String }
    private struct WireMessage: Decodable {
        let type: String; let id: String?; let text: String?; let ts: String?; let buttons: [WireButton]?
        let files: [RemoteFile]?; let voice: RemoteFile?; let reply_to: String?; let emoji: String?; let ids: [String]?; let on: Bool?
    }
    /// Otto's entries carry what the live frame did, so a message that arrived while the
    /// socket was asleep still has its photos, voice and buttons.
    private struct WireHistory: Decodable {
        let dir: String; let text: String; let ts: String; let id: String?
        let files: [RemoteFile]?; let voice: RemoteFile?; let reply_to: String?; let buttons: [WireButton]?
    }
    private struct WireBrief: Decodable {
        struct Event: Decodable { let title: String; let start: String; let minutes: Int }
        struct Mail: Decodable { let from: String; let subject: String }
        struct LoopItem: Decodable { let title: String; let due: String? }
        struct Armed: Decodable { let title: String; let next: String }
        let asOf: String
        let events: [Event]?
        let inbox: [Mail]?
        let bulk: Int
        let loops: [LoopItem]
        let triggers: [Armed]
    }

    /// Server timestamps are ISO 8601 with milliseconds; loop dues may be a bare date.
    private static func date(_ s: String?) -> Date? {
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
