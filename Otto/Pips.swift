import Foundation
import Observation

// Pips: named helpers under Otto, in their own threads and groups. Otto makes them, and so can you.
// The wire types are otto-core's docs/pips-api.md. An older server 404s every route, so `active`
// stays false and the app is the one thread it was.

// MARK: - Wire types

struct PipButton: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let ask: String
    var usedAt: String? = nil
}

struct PipMember: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var solid: FaceSolid
    var colour: String
    var state: FaceState
    var activity: String? = nil
    var buttons: [PipButton]? = nil

    /// Otto is always the orange sphere, whatever colour the server has on file for it.
    var look: FaceLook { isOtto ? FaceLook.otto.with(state) : FaceLook(solid: solid, colour: colour, state: state) }
    var isOtto: Bool { id == "otto" }
}

struct GroupLink: Codable, Hashable, Sendable {
    let id: String
    var name: String
    var members: [PipMember]
    var memberList: String
}

struct ConversationMessage: Codable, Sendable {
    let id: String
    let conversation_id: String
    let sender: String
    let kind: String
    let text: String
    let ts: String
    var handoff_id: String? = nil
    var pip_id: String? = nil
    var group: GroupLink? = nil
    var buttons: [PipButton]? = nil
    var read: Bool? = nil
    var readAt: String? = nil
    var quiet: Bool? = nil
    /// Only on rows `app` history adapted from the old transport, which already delivers them.
    var dir: String? = nil
}

struct ConversationRow: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let kind: String     // otto, pip or group
    var name: String
    var members: [String]
    var lastMessage: ConversationPreview? = nil
    var unread: Int
    var readAt: String? = nil
    var memberStates: [PipMember]
    var activity: [PipMember]
    var nextWakeAt: Double? = nil

    var isGroup: Bool { kind == "group" }
    var pips: [PipMember] { memberStates.filter { !$0.isOtto } }
    var otto: PipMember? { memberStates.first(where: \.isOtto) }
    /// A pip of its own that's waiting on you goes to the top of the list. A group doesn't, even with one
    /// in it: the mockup keeps those in time order and lets the face say it.
    var needsYou: Bool { kind == "pip" && pips.first?.state == .needs }
}

/// The part of `lastMessage` a row uses.
struct ConversationPreview: Codable, Hashable, Sendable {
    let sender: String
    let text: String
    let ts: String
}

struct PipSchedule: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var label: String
    var schedule: String
    let tz: String
    var ask: String
}

struct PipTool: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
}

/// What goes up to create or change a pip: only the fields that are set, and only ones the server takes.
struct PipPatch: Encodable {
    struct Schedule: Encodable { let name, label, schedule, tz, ask: String }
    var name, job, instructions: String?
    var solid: FaceSolid?
    var colour: String?
    var tools: [String]?
    var schedules: [Schedule]?
}

/// The part of a cron line the editor can change: one time on some weekdays. 0 is Sunday, as in cron.
struct ScheduleWhen: Equatable {
    var hour = 9, minute = 0
    var days = Set(1...5)

    init() {}

    /// nil for anything fancier than `m h * * days`.
    init?(cron: String) {
        let f = cron.split(separator: " ").map(String.init)
        guard f.count == 5, f[2] == "*", f[3] == "*", let m = Int(f[0]), let h = Int(f[1]), (0..<60).contains(m), (0..<24).contains(h) else { return nil }
        var found = Set<Int>()
        for part in f[4] == "*" ? ["0-6"] : f[4].split(separator: ",").map(String.init) {
            let r = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) ?? -1 }
            guard r.count <= 2, let a = r.first, let b = r.last, a >= 0, a <= b, b <= 7 else { return nil }
            found.formUnion((a...b).map { $0 % 7 })   // cron lets 7 be Sunday too
        }
        guard !found.isEmpty else { return nil }
        (hour, minute, days) = (h, m, found)
    }

    var cron: String { "\(minute) \(hour) * * \(days.count == 7 ? "*" : days.sorted().map(String.init).joined(separator: ","))" }

    var label: String {
        let time = String(format: "%d:%02d", hour, minute)
        if days.count == 7 { return "Every day \(time)" }
        if days == Set(1...5) { return "Weekdays \(time)" }
        if days == [0, 6] { return "Weekends \(time)" }
        let cal = Calendar.current
        let inWeek = days.sorted { ($0 - cal.firstWeekday + 8) % 7 < ($1 - cal.firstWeekday + 8) % 7 }
        return inWeek.map { cal.shortStandaloneWeekdaySymbols[$0] }.joined(separator: ", ") + " \(time)"
    }
}

struct PipDetail: Codable, Hashable, Identifiable, Sendable {
    struct Reach: Codable, Hashable, Identifiable, Sendable { let id: String; let name: String; let sharedWithOtto: Bool }
    struct RunsOn: Codable, Hashable, Sendable {
        let model: String?
        let requestedModel: String
        let available: Bool
        let reason: String
        let claudeReturnsAt: String?
    }
    let id: String
    var name: String
    var job: String
    var description: String
    var solid: FaceSolid
    var colour: String
    var paused: Bool
    var state: FaceState
    var schedules: [PipSchedule]
    var canReach: [Reach]
    var runsOn: RunsOn
    var instructions: String? = nil
    var tools: [String]? = nil

    var look: FaceLook { FaceLook(solid: solid, colour: colour, state: state) }
}

struct PipHandoff: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let from: String
    let to: String
    let conversation: String
    let ask: String
    var reply: String? = nil
    var status: String   // asked, answered or failed
    let askedAt: String
    var endedAt: String? = nil
    var error: String? = nil
    var toldOttoAt: String? = nil
    var toldUserAt: String? = nil
}

struct ConversationSearchResult: Decodable, Identifiable {
    let conversation: ConversationRow
    let matches: [ConversationMessage]
    var id: String { conversation.id }
}

/// The new websocket frames. Older builds ignore them; older servers never send them.
enum ConversationEvent: Sendable {
    case message(ConversationMessage)
    case read(conversation: String, readAt: String?)
    case changed
    case pips([PipDetail])
    case activity(conversation: String, PipMember)
    case handoff(PipHandoff)
    case group(GroupLink)

    /// Nil for any other frame.
    static func decode(type: String, _ data: Data) -> ConversationEvent? {
        let d = JSONDecoder()
        struct M: Decodable { let message: ConversationMessage }
        struct R: Decodable { let conversation_id: String; let readAt: String? }
        struct P: Decodable { let pips: [PipDetail] }
        struct A: Decodable { let conversation_id: String; let pip: PipMember }
        struct H: Decodable { let handoff: PipHandoff }
        struct G: Decodable { let group: GroupLink }
        switch type {
        case "conversation_message": return (try? d.decode(M.self, from: data)).map { .message($0.message) }
        case "conversation_read": return (try? d.decode(R.self, from: data)).map { .read(conversation: $0.conversation_id, readAt: $0.readAt) }
        case "conversations_changed", "pip_state": return .changed   // pip_state lacks the computed fields: refetch
        case "pip_states": return (try? d.decode(P.self, from: data)).map { .pips($0.pips) }
        case "pip_activity": return (try? d.decode(A.self, from: data)).map { .activity(conversation: $0.conversation_id, $0.pip) }
        case "handoff_updated": return (try? d.decode(H.self, from: data)).map { .handoff($0.handoff) }
        case "group_link": return (try? d.decode(G.self, from: data)).map { .group($0.group) }
        default: return nil
        }
    }
}

extension Message {
    /// One message of a conversation, as the thread keeps it. Yours come back under the UUID this phone sent.
    init(_ w: ConversationMessage) {
        let uuid = UUID(uuidString: w.id)
        self.init(id: uuid ?? UUID(), from: w.kind == "system" ? .terminal : w.sender == "user" ? .me : .otto,
                  text: w.text, date: LiveBackend.date(w.ts) ?? .now)
        serverID = uuid == nil ? w.id : nil
        read = w.read
        pip = w.sender == "user" ? nil : w.sender
        handoffID = w.handoff_id
        pipRef = w.pip_id
        groupLink = w.group
        buttons = Self.actionButtons(w.buttons)
    }

    /// A server id as `wireID` spells it: a UUID's case isn't significant, but string compares are.
    static func wire(_ id: String) -> String { UUID(uuidString: id)?.uuidString ?? id }

    static func actionButtons(_ b: [PipButton]?) -> [ActionButton] {
        (b ?? []).filter { $0.usedAt == nil }.map { ActionButton(label: $0.label, data: PipStore.buttonPrefix + $0.id) }
    }

    /// Who a run of bubbles belongs to: the pip, or Otto, or you.
    var author: String { pip == nil || pip == "otto" ? from.rawValue : pip! }
    /// Came through the conversation API, which has no tapbacks or quoted replies.
    var isConversation: Bool { pip != nil || handoffID != nil || pipRef != nil || groupLink != nil }
    /// `true` when it's a line this feature added, not a prompt typed in Otto's terminal.
    var isPipLine: Bool { from == .terminal && isConversation }

    mutating func merge(_ w: ConversationMessage) {
        text = w.text
        pending = nil; failed = nil
        if w.read == true { read = true }
        groupLink = w.group ?? groupLink
        if let b = w.buttons { buttons = Self.actionButtons(b) }
    }
}

// MARK: - The time, overridable by the debug fixture

enum PipClock {
    #if DEBUG
    nonisolated(unsafe) static var fixed: Date?
    static var now: Date { fixed ?? .now }
    #else
    static var now: Date { .now }
    #endif

    /// Today's time, then Yesterday, then a weekday, then a date, as Messages does.
    static func listTime(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return date.formatted(date: .omitted, time: .shortened)
        case 1: return String(localized: "Yesterday")
        case 2...6: return date.formatted(.dateTime.weekday(.wide))
        default: return date.formatted(date: .numeric, time: .omitted)
        }
    }

    static func time(_ s: String?) -> String { LiveBackend.date(s)?.formatted(date: .omitted, time: .shortened) ?? "" }

    /// "Back at 7:00 tomorrow".
    static func wake(_ epochMs: Double) -> String {
        let date = Date(timeIntervalSince1970: epochMs / 1000), cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        let t = date.formatted(date: .omitted, time: .shortened)
        switch days {
        case ...0: return "Back at \(t)"
        case 1: return "Back at \(t) tomorrow"
        default: return "Back \(date.formatted(.dateTime.weekday(.wide))) at \(t)"
        }
    }
}

// MARK: - One conversation

/// A pip's own thread or a group: the same chat screen as Otto's, through ChatThread.
@MainActor @Observable final class PipThread: ChatThread {
    let id: String
    private unowned let pips: PipStore
    var messages: [Message] = [] { didSet { save() } }
    var replyingTo: Message.ID?
    var animated = false

    var name: String { row?.name ?? "" }
    let isOtto = false
    var conversationID: String { id }
    let typing = false
    let typingStatus: String? = nil
    let typingTodos: [TodoItem] = []
    var connected: Bool { pips.store?.connected ?? false }
    var row: ConversationRow? { pips.row(id) }

    private let file: URL
    @ObservationIgnored private var saving: Task<Void, Never>?

    init(id: String, pips: PipStore) {
        self.id = id
        self.pips = pips
        file = pips.folder.appending(path: "thread-\(PipStore.esc(id)).json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Message].self, from: data) { messages = saved }
    }

    private func save() {
        saving?.cancel()
        let snapshot = messages, file = file
        saving = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    func upsert(_ w: ConversationMessage) {
        guard w.kind == "text" || w.kind == "system" else { return }   // edit and reaction are `app` patches
        if let i = messages.firstIndex(where: { $0.wireID == Message.wire(w.id) }) { messages[i].merge(w); return }
        let m = Message(w)
        messages.insert(m, at: messages.lastIndex { $0.date <= m.date }.map { $0 + 1 } ?? 0)
    }

    /// The server's page, merged: what's already here keeps its identity, so nothing redraws.
    func load() async {
        struct Page: Decodable { let messages: [ConversationMessage] }
        guard let r = await pips.request("GET", "app/conversations/\(PipStore.esc(id))/history", query: [URLQueryItem(name: "limit", value: "200")]),
              r.status == 200, let page = try? JSONDecoder().decode(Page.self, from: r.data) else { animated = true; return }
        page.messages.forEach(upsert)
        animated = true
        await resendPending()
    }

    private func add(_ text: String) -> UUID {
        let m = Message(from: .me, text: text, pending: true)
        messages.append(m)
        return m.id
    }

    func send(_ text: String) {
        let id = add(text)
        Task { await deliver(id) }
    }

    /// From a notification: answered before iOS is told we're done, because it may suspend the app then.
    func sendNow(_ text: String) async { await deliver(add(text)) }

    private func deliver(_ id: UUID) async {
        guard let m = messages.first(where: { $0.id == id }), m.pending == true else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["id": m.wireID, "text": m.text])
        let r = await pips.request("POST", "app/conversations/\(PipStore.esc(self.id))/messages", body: body)
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        struct Sent: Decodable { let message: ConversationMessage }
        switch r?.status {
        case 200:
            if let d = r?.data, let sent = try? JSONDecoder().decode(Sent.self, from: d) { messages[i].merge(sent.message) } else { messages[i].pending = nil }
        case 400:   // an unknown @name: sending it again can't help
            messages[i].pending = nil; messages[i].failed = true
        default:    // 503 or no answer: same id, next connection or on a tap
            messages[i].failed = true
        }
    }

    func retry(_ id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].pending == true else { return }
        messages[i].failed = nil
        Task { await deliver(id) }
    }

    func resendPending() async {
        for m in messages where m.pending == true { await deliver(m.id) }
    }

    func tap(_ button: ActionButton, on id: Message.ID) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].buttons = [] }
        pips.press(button, in: self.id)
    }

    func react(_ emoji: String, on id: Message.ID) {}   // the conversation API has no tapbacks
}

// MARK: - The store

enum PipSheet: Identifiable, Hashable {
    case handoff(String), pip(String), group(String)
    var id: Self { self }
}

@MainActor @Observable final class PipStore {
    static let buttonPrefix = "pip-button:"
    private(set) var rows: [ConversationRow] = [] { didSet { saveRows() } }
    var details: [String: PipDetail] = [:]
    var handoffs: [String: PipHandoff] = [:]
    /// The open thread, one deep: a thread opened from another replaces it.
    var path: [String] = []
    var sheet: PipSheet?
    /// The conversation on screen, whose unread dot stays clear.
    @ObservationIgnored var visible: String?
    @ObservationIgnored var match: ConversationMessage?

    @ObservationIgnored weak var store: OttoStore?
    @ObservationIgnored private var threads: [String: PipThread] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    let folder: URL
    private var rowsFile: URL { folder.appending(path: "conversations.json") }

    /// The server has the conversation routes, so there's a list, even of Otto alone. An older
    /// server never fills `rows`, and stays the single thread.
    var active: Bool { !rows.isEmpty }

    init(name: String) {
        folder = URL.applicationSupportDirectory.appending(path: "pips-\(name.lowercased().replacing(" ", with: "-"))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: rowsFile), let saved = try? JSONDecoder().decode([ConversationRow].self, from: data) { rows = saved }
    }

    static func esc(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async -> PipResponse? {
        await store?.backend.pipRequest(method, path, query: query, body: body)
    }

    private func saveRows() {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        let url = rowsFile
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    func row(_ id: String) -> ConversationRow? { rows.first { $0.id == id } }

    func thread(_ id: String) -> PipThread {
        if let t = threads[id] { return t }
        let t = PipThread(id: id, pips: self)
        threads[id] = t
        return t
    }

    /// Everyone but Otto, needs-first, then newest first.
    var list: [ConversationRow] {
        rows.filter { $0.kind != "otto" }.sorted {
            if $0.needsYou != $1.needsYou { return $0.needsYou }
            return ($0.lastMessage?.ts ?? "") > ($1.lastMessage?.ts ?? "")
        }
    }

    /// Anywhere a member is known; a pip can be mentioned before its row has loaded.
    func member(_ id: String) -> PipMember? {
        for r in rows { if let m = r.memberStates.first(where: { $0.id == id }) { return m } }
        return details[id].map { PipMember(id: $0.id, name: $0.name, solid: $0.solid, colour: $0.colour, state: $0.state) }
    }

    /// `match`: a search result, which ChatView scrolls to once the thread has loaded.
    func open(_ id: String, at match: ConversationMessage? = nil) {
        sheet = nil
        self.match = match
        path = [id]
    }

    // MARK: Sync

    func run() async {
        guard let store else { return }
        await refresh(launching: true)
        await syncApp()
        for await e in store.backend.conversationEvents { handle(e) }
    }

    /// After a reconnect: events are updates, not a replay log.
    func reconnected() async {
        await refresh()
        await syncApp()
        if let id = path.last, id != "app" { await thread(id).load() }
        for t in threads.values { await t.resendPending() }
        switch sheet {
        case .handoff(let id)?: await loadHandoff(id)
        case .pip(let id)?: await loadPip(id)
        case .group?: await loadAll()
        case nil: break
        }
    }

    /// `launching`: the splash is still up, so a list that's just arrived is simply where the app opens.
    func refresh(launching: Bool = false) async {
        struct Page: Decodable { let conversations: [ConversationRow] }
        guard let r = await request("GET", "app/conversations"), r.status == 200,
              let page = try? JSONDecoder().decode(Page.self, from: r.data) else { return }
        let wasActive = active
        rows = page.conversations
        // The list arrived late, under someone already reading Otto's thread: they stay in it.
        if !wasActive, active, path.isEmpty, !launching { path = ["app"] }
    }

    private func refreshSoon() {
        refreshing?.cancel()
        refreshing = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { await refresh() }
        }
    }

    /// What Otto's thread has beyond the old transport: handoff lines, group links, and replies
    /// relayed from a pip. Rows carrying `dir` came from that transport and are already there.
    private func syncApp() async {
        struct Page: Decodable { let messages: [ConversationMessage] }
        guard let r = await request("GET", "app/conversations/app/history", query: [URLQueryItem(name: "limit", value: "200")]),
              r.status == 200, let page = try? JSONDecoder().decode(Page.self, from: r.data) else { return }
        for m in page.messages where m.dir == nil { store?.upsert(m) }
    }

    func handle(_ e: ConversationEvent) {
        switch e {
        case .message(let m):
            if m.conversation_id == "app" { store?.upsert(m) } else { thread(m.conversation_id).upsert(m) }
            if store?.foreground == false { notify(m) }
            guard let i = rows.firstIndex(where: { $0.id == m.conversation_id }), m.kind == "text" || m.kind == "system" else { refreshSoon(); return }
            rows[i].lastMessage = ConversationPreview(sender: m.sender, text: m.text, ts: m.ts)
            if visible == m.conversation_id { markRead(m.conversation_id) } else if m.sender != "user" { rows[i].unread += 1 }
        case .read(let id, let readAt):
            if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].unread = 0; rows[i].readAt = readAt }
        case .changed: refreshSoon()
        case .pips(let list):
            for p in list { details[p.id] = p }
            refreshSoon()
        case .activity(let id, let member): apply(activity: member, in: id)
        case .handoff(let h): handoffs[h.id] = h
        case .group(let g):
            store?.relink(g)
            for t in threads.values { for i in t.messages.indices where t.messages[i].groupLink?.id == g.id { t.messages[i].groupLink = g } }
            refreshSoon()
        }
    }

    private func apply(activity m: PipMember, in id: String) {
        for i in rows.indices {
            if let j = rows[i].memberStates.firstIndex(where: { $0.id == m.id }) {
                rows[i].memberStates[j].state = m.state
                rows[i].memberStates[j].buttons = m.buttons
                if rows[i].id == id { rows[i].memberStates[j].activity = m.activity }
            }
            guard rows[i].id == id else { continue }
            rows[i].activity.removeAll { $0.id == m.id }
            if m.activity?.isEmpty == false { rows[i].activity.append(m) }
        }
    }

    // MARK: Notifications: Otto's two paths (see Notifier), for what doesn't come through the old transport

    private static let notifiedKey = "pips.notifiedThrough"
    /// Everything up to here was on screen or has had its banner.
    private var notifiedThrough: Date {
        get { UserDefaults.standard.object(forKey: Self.notifiedKey) as? Date ?? .now }
        set { UserDefaults.standard.set(newValue, forKey: Self.notifiedKey) }
    }

    func leftApp() { notifiedThrough = .now }

    private func notify(_ m: ConversationMessage) {
        guard (m.kind == "text" || m.kind == "system"), m.sender != "user", m.dir == nil, !m.text.isEmpty,
              m.quiet != true, store?.backend.desktopSync?.snapshot.read.contains(m.id) != true,
              let date = LiveBackend.date(m.ts), date > notifiedThrough else { return }
        notifiedThrough = date
        let id = m.conversation_id, r = row(id)
        let who = m.sender == "otto" ? "Otto" : member(m.sender)?.name ?? r?.name ?? "Otto"
        // Otto's thread keeps Otto's routing: no conversation means the old reply path and the old tap.
        Notifier.shared.post(title: id == "app" ? who : r?.name ?? who, body: r?.isGroup == true ? "\(who): \(m.text)" : m.text,
                             thread: "pip-\(id)", id: m.id, conversation: id == "app" ? nil : id)
    }

    /// A background wake: what came in since the last look, oldest first, as banners.
    func backgroundCatchUp() async {
        struct Page: Decodable { let messages: [ConversationMessage] }
        await refresh()
        let since = notifiedThrough
        var fresh: [ConversationMessage] = []
        for r in rows where (LiveBackend.date(r.lastMessage?.ts) ?? .distantPast) > since {
            let q = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "since", value: since.formatted(.iso8601))]
            guard let h = await request("GET", "app/conversations/\(Self.esc(r.id))/history", query: q), h.status == 200,
                  let page = try? JSONDecoder().decode(Page.self, from: h.data) else { continue }
            fresh += page.messages
        }
        for m in fresh.sorted(by: { (LiveBackend.date($0.ts) ?? .distantPast) < (LiveBackend.date($1.ts) ?? .distantPast) }) { notify(m) }
    }

    // MARK: Actions

    /// When a conversation becomes visible, and when one lands while it is. Clears the dot on every device.
    func markRead(_ id: String) {
        if let i = rows.firstIndex(where: { $0.id == id }), rows[i].unread > 0 { rows[i].unread = 0 }
        Task { _ = await request("POST", "app/conversations/\(Self.esc(id))/read") }
    }

    /// A pip's button, on a message or an activity line. The answer goes back to the pip, never to the world.
    func press(_ button: ActionButton, in conversation: String) {
        guard let data = button.data, data.hasPrefix(Self.buttonPrefix) else { return }
        let id = String(data.dropFirst(Self.buttonPrefix.count))
        if let i = rows.firstIndex(where: { $0.id == conversation }) {
            for j in rows[i].activity.indices { rows[i].activity[j].buttons?.removeAll { $0.id == id } }
        }
        let body = try? JSONSerialization.data(withJSONObject: ["button_id": id])
        Task { _ = await request("POST", "app/conversations/\(Self.esc(conversation))/buttons", body: body) }
    }

    func loadHandoff(_ id: String) async {
        guard let r = await request("GET", "app/handoffs/\(Self.esc(id))"), r.status == 200,
              let h = try? JSONDecoder().decode(PipHandoff.self, from: r.data) else { return }
        handoffs[id] = h
    }

    func loadPip(_ id: String) async {
        guard let r = await request("GET", "app/pips/\(Self.esc(id))"), r.status == 200,
              let p = try? JSONDecoder().decode(PipDetail.self, from: r.data) else { return }
        details[id] = p
    }

    func act(_ action: String, on id: String) {
        sheet = nil
        Task {
            let body = try? JSONSerialization.data(withJSONObject: ["action": action])
            _ = await request("POST", "app/handoffs/\(Self.esc(id))/actions", body: body)
            await loadHandoff(id)
        }
    }

    func setPaused(_ paused: Bool, pip id: String) {
        details[id]?.paused = paused
        Task {
            let body = try? JSONSerialization.data(withJSONObject: ["paused": paused])
            guard let r = await request("PATCH", "app/pips/\(Self.esc(id))", body: body), r.status == 200,
                  let p = try? JSONDecoder().decode(PipDetail.self, from: r.data) else {
                details[id]?.paused = !paused   // it didn't take: the button says so by going back
                return
            }
            details[id] = p
        }
    }

    func loadAll() async {
        struct Page: Decodable { let pips: [PipDetail] }
        guard let r = await request("GET", "app/pips"), r.status == 200,
              let page = try? JSONDecoder().decode(Page.self, from: r.data) else { return }
        details = Dictionary(page.pips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// nil when the server has no such route.
    func tools() async -> [PipTool]? {
        struct Page: Decodable { let tools: [PipTool] }
        guard let r = await request("GET", "app/pips/tools"), r.status == 200 else { return nil }
        return (try? JSONDecoder().decode(Page.self, from: r.data))?.tools
    }

    /// nil if it took, otherwise the line to show. Nothing local moves until the server says yes.
    private func change(_ method: String, _ path: String, _ body: (any Encodable)? = nil, took: (Data) -> Void = { _ in }) async -> String? {
        let data = body.flatMap { try? JSONEncoder().encode($0) }
        guard let r = await request(method, path, body: data) else { return String(localized: "Couldn’t reach Otto. Nothing changed.") }
        guard (200..<300).contains(r.status) else {
            return r.status == 404 ? String(localized: "This server can’t do that yet. Nothing changed.") : String(localized: "That didn’t go through. Nothing changed.")
        }
        took(r.data)
        return nil
    }

    private func gotRow(_ d: Data) -> ConversationRow? {
        guard let r = try? JSONDecoder().decode(ConversationRow.self, from: d) else { refreshSoon(); return nil }
        if let i = rows.firstIndex(where: { $0.id == r.id }) { rows[i] = r } else { rows.append(r) }
        return r
    }

    private func gotPip(_ d: Data) {
        if let p = try? JSONDecoder().decode(PipDetail.self, from: d) { details[p.id] = p }
        refreshSoon()   // the name and face are on rows and in headers too
    }

    func update(pip id: String, _ patch: PipPatch) async -> String? {
        await change("PATCH", "app/pips/\(Self.esc(id))", patch, took: gotPip)
    }

    func createPip(_ patch: PipPatch) async -> String? { await change("POST", "app/pips", patch, took: gotPip) }

    func deletePip(_ id: String) async -> String? {
        let failure = await change("DELETE", "app/pips/\(Self.esc(id))")
        guard failure == nil else { return failure }
        path.removeAll { row($0)?.kind == "pip" && row($0)?.pips.first?.id == id }
        details[id] = nil
        await refresh()
        return nil
    }

    func createGroup(name: String, members: [String], created: (String) -> Void) async -> String? {
        struct New: Encodable { let name: String; let members: [String] }
        return await change("POST", "app/groups", New(name: name, members: members)) { if let r = gotRow($0) { created(r.id) } }
    }

    func renameGroup(_ id: String, _ name: String) async -> String? {
        await change("PATCH", "app/groups/\(Self.esc(id))", ["name": name]) { _ = gotRow($0) }
    }

    func addMember(_ pip: String, to id: String) async -> String? {
        await change("POST", "app/groups/\(Self.esc(id))/members", ["pip_id": pip]) { _ = gotRow($0) }
    }

    func removeMember(_ pip: String, from id: String) async -> String? {
        await change("DELETE", "app/groups/\(Self.esc(id))/members/\(Self.esc(pip))") { _ = gotRow($0) }
    }

    /// It's archived on the server and leaves the list; back to that list.
    func deleteGroup(_ id: String) async -> String? {
        let failure = await change("DELETE", "app/groups/\(Self.esc(id))")
        guard failure == nil else { return failure }
        rows.removeAll { $0.id == id }
        sheet = nil
        path = []
        return nil
    }

    func search(_ q: String) async -> [ConversationSearchResult] {
        struct Page: Decodable { let results: [ConversationSearchResult] }
        guard let r = await request("GET", "app/conversations/search", query: [URLQueryItem(name: "q", value: String(q.prefix(200)))]), r.status == 200,
              let page = try? JSONDecoder().decode(Page.self, from: r.data) else { return [] }
        return page.results
    }
}

// MARK: - Otto's own thread

extension OttoStore {
    /// A handoff line, group link or relayed reply. Its id is the server's, so a replay lands on itself.
    func upsert(_ w: ConversationMessage) {
        guard w.kind == "text" || w.kind == "system" else { return }
        if let i = messages.firstIndex(where: { $0.wireID == Message.wire(w.id) }) {
            if w.dir == nil { messages[i].merge(w) }
            return
        }
        guard w.dir == nil else { return }   // the old transport's own, on its way through it
        let m = Message(w)
        messages.insert(m, at: messages.lastIndex { $0.date <= m.date }.map { $0 + 1 } ?? 0)
    }

    func relink(_ g: GroupLink) {
        for i in messages.indices where messages[i].groupLink?.id == g.id { messages[i].groupLink = g }
    }
}
