import Foundation

// The crew: specialist agents behind Otto (docs/crew-protocol.md). Wire shapes are §5 and §7.

struct CrewAgent: Decodable, Identifiable, Hashable {
    let id: String
    let role: String
    let name: String
    /// idle, working, waiting or error.
    let status: String
    let lastLine: String?
    let lastFrom: String?
    let lastAt: String?
}

/// One line of a thread: a message, a tool call or a status change.
struct CrewEvent: Decodable, Identifiable, Hashable {
    let id: String
    let agent: String
    let kind: String
    let ts: String
    let from: String?
    let to: String?
    let text: String?
    let tool: String?
    let summary: String?
    let status: String?
    let note: String?

    /// The same message sits in two threads under one `id`, so the thread is part of the key.
    var key: String { agent + "/" + id }
    var date: Date { LiveBackend.date(ts) ?? Date() }
}

/// "writer-3" -> "Writer 3", as the server names them.
func crewName(_ id: String) -> String {
    switch id {
    case "pm": return "Product manager"
    case "otto": return "Otto"
    case "user": return "You"
    default:
        let parts = id.split(separator: "-")
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

@MainActor @Observable
final class CrewStore {
    var agents: [CrewAgent] = []
    var threads: [String: [CrewEvent]] = [:]
    /// The thread on screen, so its messages don't notify.
    var open: String?
    /// Keys of your messages the server never took.
    var failed: Set<String> = []
    /// Threads whose history has come back at least once (empty or not), so an empty one isn't still loading.
    var loaded: Set<String> = []
    /// Set by the list while Otto's thread is pushed; the thread's back button calls it.
    var back: (() -> Void)?
    private var seen: [String: String] = [:]
    @ObservationIgnored private var backend: OttoBackend?
    @ObservationIgnored private var foreground: () -> Bool = { true }

    var hasCrew: Bool { !agents.isEmpty }

    /// Messages newer than the last time the thread was open, not yours.
    func unread(_ id: String) -> Int {
        let mark = seen[id] ?? UserDefaults.standard.string(forKey: "crewSeen.\(id)") ?? ""
        return (threads[id] ?? []).filter { $0.kind == "message" && $0.ts > mark && $0.from != "user" }.count
    }

    func markSeen(_ id: String) {
        guard let ts = threads[id]?.map(\.ts).max() else { return }
        seen[id] = ts
        UserDefaults.standard.set(ts, forKey: "crewSeen.\(id)")
    }

    func start(_ backend: OttoBackend, foreground: @escaping () -> Bool) async {
        self.backend = backend
        self.foreground = foreground
        // Every socket open sends a snapshot; frames sent while it was down are gone, so refetch the stale threads.
        Task {
            for await a in backend.crewAgents {
                agents = a
                for x in a where Self.stale(x, threads[x.id]) { await load(x.id, notify: true) }
            }
        }
        Task { for await e in backend.crewEvents { append(e, foreground: foreground()) } }
        agents = await backend.crew() ?? []
        // Unread counts need every thread, not just the one opened.
        for a in agents { await load(a.id) }
    }

    func refresh() async { if let a = await backend?.crew() { agents = a } }

    private func append(_ e: CrewEvent, foreground: Bool) {
        guard !(threads[e.agent] ?? []).contains(where: { $0.key == e.key }) else { return }
        threads[e.agent, default: []].append(e)
        if e.kind == "message", let from = e.from, from == e.agent, from != "user", from != "otto",
           !foreground || open != e.agent {
            Notifier.shared.post(title: crewName(from), body: e.text ?? "", thread: "crew:\(from)", id: "crew/\(e.id)")
        }
    }

    /// The roster's last line is newer than anything the thread holds.
    private static func stale(_ a: CrewAgent, _ thread: [CrewEvent]?) -> Bool {
        guard let at = a.lastAt else { return false }
        return at > (thread?.map(\.ts).max() ?? "")
    }

    /// `notify`: a refetch after a gap. Only for a thread already held, so a first load never replays old history.
    func load(_ id: String, notify: Bool = false) async {
        guard let rows = await backend?.crewHistory(id, limit: 200) else { return }
        loaded.insert(id)
        let held = !(threads[id] ?? []).isEmpty
        let mark = seen[id] ?? UserDefaults.standard.string(forKey: "crewSeen.\(id)") ?? ""
        var have = Set((threads[id] ?? []).map(\.key))
        var all = threads[id] ?? []
        for e in rows where have.insert(e.key).inserted {
            all.append(e)
            if notify, held, e.kind == "message", e.from == id, e.ts > mark, open != id || !foreground() {
                Notifier.shared.post(title: crewName(id), body: e.text ?? "", thread: "crew:\(id)", id: "crew/\(e.id)")
            }
        }
        threads[id] = all.sorted { $0.ts < $1.ts }
    }

    func send(_ id: String, text: String) async {
        guard let backend else { return }
        let cid = String(UUID().uuidString.lowercased().replacing("-", with: "").prefix(8))
        let local = CrewEvent(id: cid, agent: id, kind: "message", ts: Self.now(), from: "user", to: id,
                              text: text, tool: nil, summary: nil, status: nil, note: nil)
        threads[id, default: []].append(local)
        if let e = await backend.crewSend(id, text: text, clientID: cid) {
            // Same id: the socket's copy may have landed first, so drop the optimistic one rather than double up.
            threads[id]?.removeAll { $0.key == local.key }
            if !(threads[id] ?? []).contains(where: { $0.key == e.key }) { threads[id, default: []].append(e) }
            threads[id]?.sort { $0.ts < $1.ts }
        } else {
            failed.insert(local.key)
        }
    }

    func stop(_ id: String) async {
        if let a = await backend?.crewStop(id), let i = agents.firstIndex(where: { $0.id == a.id }) { agents[i] = a }
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
