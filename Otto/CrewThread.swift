import SwiftUI
import CryptoKit

/// One crew agent's thread as Otto's chat reads it (ChatThread): its events as Messages.
/// Messages are bubbles, a run of tool calls is one CrewSteps card (behind "Show tool
/// calls"), and only a run that broke gets a status line; the thinking bubble shows the rest.
@MainActor @Observable final class CrewThread: ChatThread {
    let id: String
    private let store: OttoStore
    var replyingTo: Message.ID?
    var animated = false

    init(store: OttoStore, id: String) { self.store = store; self.id = id }

    private var crew: CrewStore { store.crew }
    var agent: CrewAgent? { crew.agents.first { $0.id == id } }
    var name: String { crewName(id) }
    var isOtto: Bool { false }
    var connected: Bool { store.connected }
    var loaded: Bool { crew.loaded.contains(id) || !(crew.threads[id] ?? []).isEmpty }
    var typing: Bool { agent?.status == "working" }

    /// What it's doing right now, in the words Otto's own thinking bubble uses: its latest
    /// step since this run started, or just thinking.
    var typingStatus: String? {
        guard typing else { return nil }
        let thread = crew.threads[id] ?? []
        let start = thread.lastIndex { $0.kind == "status" && $0.status == "working" } ?? thread.startIndex
        guard let t = thread[start...].last(where: { $0.kind == "tool" }) else { return "Thinking…" }
        return CrewStep(event: t).doing
    }

    /// The chat view reads `messages` several times per redraw, and a long crew thread made rebuilding it
    /// every time the lag. It is rebuilt only when something it is made of changed. Reading the inputs
    /// here also keeps the views observing them.
    @ObservationIgnored private var cache: (key: [AnyHashable], messages: [Message])?

    var messages: [Message] {
        let events = crew.threads[id] ?? []
        let key: [AnyHashable] = [events.count, events.last?.key, UserDefaults.standard.bool(forKey: "crewShowTools"),
                                  crew.replies, crew.reactions, crew.failed]
        if let cache, cache.key == key { return cache.messages }
        let built = build(events)
        cache = (key, built)
        return built
    }

    private func build(_ events: [CrewEvent]) -> [Message] {
        let showTools = UserDefaults.standard.bool(forKey: "crewShowTools")
        var out: [Message] = []
        /// Who wrote the message before, so a run from one sender is captioned once.
        var lastFrom: String?
        for e in events {
            switch e.kind {
            case "message":
                let mine = e.from == "user"
                var text = e.text ?? ""
                let reply = crew.replies[e.key]
                // A reply went to the agent with its quote as a first "> " line; the bubble shows the quote instead.
                if reply != nil, text.hasPrefix("> "), let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
                var m = Message(id: Self.uuid(e.key), from: mine ? .me : .otto, text: text, date: e.date)
                m.serverID = e.key
                m.replyTo = reply
                m.reaction = crew.reactions[e.key]
                if crew.failed.contains(e.key) { m.failed = true }
                if let from = e.from, !mine, from != id, from != lastFrom { m.caption = crewName(from) }
                if e.from == id, let to = e.to, to != "user" { m.mention = crewHandle(to) }
                lastFrom = e.from
                out.append(m)
            case "tool" where showTools:
                if out.last?.steps != nil { out[out.count - 1].steps?.append(e) }
                else {
                    var m = Message(id: Self.uuid(e.key), from: .system, text: "", date: e.date)
                    m.steps = [e]
                    out.append(m)
                }
                lastFrom = nil
            case "status" where e.status == "error":
                out.append(Message(id: Self.uuid(e.key), from: .system, text: "error" + (e.note.map { " · \($0)" } ?? ""), date: e.date))
                lastFrom = nil
            default: continue
            }
        }
        return out
    }

    /// The same key always makes the same id, so a rebuilt thread keeps its rows (and their animations).
    private static func uuid(_ key: String) -> UUID {
        if let id = ids[key] { return id }
        let id = UUID(uuid: Insecure.MD5.hash(data: Data(key.utf8)).withUnsafeBytes { $0.load(as: uuid_t.self) })
        ids[key] = id
        return id
    }
    /// `messages` is rebuilt on every redraw; hashing each key once keeps that cheap.
    private static var ids: [String: UUID] = [:]

    func send(_ text: String) {
        let quote = replyingTo.flatMap { r in messages.first { $0.id == r } }
        replyingTo = nil
        Task { await crew.send(id, text: text, reply: quote.map { ($0.wireID, $0.text) }) }
    }

    /// Local only: the server has no crew reactions.
    func react(_ emoji: String, on id: Message.ID) {
        guard let key = messages.first(where: { $0.id == id })?.wireID else { return }
        crew.reactions[key] = crew.reactions[key] == emoji ? nil : emoji
    }

    /// Crew messages carry no buttons.
    func tap(_ button: ActionButton, on id: Message.ID) {}

    func appear() async {
        crew.open = id
        await crew.load(id)
        crew.markSeen(id)
        animated = true
    }

    func disappear() {
        if crew.open == id { crew.open = nil }
        crew.markSeen(id)
    }
}

/// A crew thread's header, Otto's (ChatView) with the agent's face: glass back and menu
/// buttons, the face with a name pill under it that opens the contact card.
struct CrewHeader: View {
    let thread: CrewThread
    @Environment(OttoStore.self) private var store
    @AppStorage("crewShowTools") private var showTools = false
    /// `-crewCard`: open on the contact card, for screenshots.
    @State private var card = ProcessInfo.processInfo.arguments.contains("-crewCard")

    var body: some View {
        ZStack {
            HStack {
                ThreadBackButton(current: thread.id)
                Spacer()
                Menu {
                    Toggle("Show tool calls", isOn: $showTools)
                    Button("Stop", role: .destructive) { Task { await store.crew.stop(thread.id) } }
                        .disabled(!thread.typing)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
            }
            Button { card = true } label: {
                VStack(spacing: 4) {
                    if let agent = thread.agent { CrewAvatar(agent: agent, size: 56) }
                    HStack(spacing: 3) {
                        Text(thread.name).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .tint(.primary)
            .accessibilityHint("Opens the contact card")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        // Solid behind the buttons and face, then a fade below them: the deeper fade Otto's
        // header gets with a banner under it. Crew messages are long and read through the plain one.
        .background(alignment: .top) {
            LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                           startPoint: UnitPoint(x: 0.5, y: 0.6), endPoint: .bottom)
                .padding(.bottom, -16)
                .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: $card) { CrewContactCard(id: thread.id) }
    }
}

/// A crew thread's `system` row: a run of tool calls, or a centred grey line.
struct CrewNote: View {
    let message: Message
    var body: some View {
        if let steps = message.steps {
            CrewSteps(steps: steps).padding(.vertical, 4)
        } else {
            Text(message.text)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
    }
}

/// One tool call, in words: what it did, to what.
struct CrewStep {
    let symbol: String
    let verb: String
    /// The file name, the command or the pattern: the part worth reading.
    let target: String
    /// The folder a file sits in, for a path.
    let detail: String?
    let mono: Bool
    let doing: String

    init(event e: CrewEvent) {
        let s = e.summary ?? ""
        let file = (s as NSString).lastPathComponent
        let dir = (s as NSString).deletingLastPathComponent
        let path = (file, dir.isEmpty ? nil : dir)
        switch e.tool ?? "" {
        case "Read": (symbol, verb, target, detail, mono, doing) = ("doc.text", "Read", path.0, path.1, false, "Reading \(file)")
        case "Edit", "NotebookEdit": (symbol, verb, target, detail, mono, doing) = ("pencil", "Edited", path.0, path.1, false, "Editing \(file)")
        case "Write": (symbol, verb, target, detail, mono, doing) = ("square.and.pencil", "Wrote", path.0, path.1, false, "Writing \(file)")
        case "Bash":
            // "cd <worktree> && " opens nearly every command; the folder goes under it instead.
            let cd = s.firstMatch(of: #/^cd (\S+) && /#)
            let cmd = cd.map { String(s[$0.range.upperBound...]) } ?? s
            (symbol, verb, target, detail, mono) = ("terminal", "Ran", cmd, cd.map { String($0.1) }, true)
            doing = "Running \(cmd.split(separator: " ").prefix(3).joined(separator: " "))"
        case "Grep": (symbol, verb, target, detail, mono, doing) = ("magnifyingglass", "Searched for", s, nil, true, "Searching for \(s)")
        case "Glob": (symbol, verb, target, detail, mono, doing) = ("folder", "Looked for", s, nil, true, "Looking for \(s)")
        case "WebFetch": (symbol, verb, target, detail, mono, doing) = ("globe", "Opened", s, nil, false, "Reading \(s)")
        default: (symbol, verb, target, detail, mono, doing) = ("wrench.and.screwdriver", e.tool ?? "Step", s, nil, true, "Working")
        }
    }
}

/// A run of tool calls as a card of steps, newest last. Long runs fold to their last few.
struct CrewSteps: View {
    let steps: [CrewEvent]
    @State private var open = false
    private static let folded = 4

    var body: some View {
        let shown = open ? steps[...] : steps.suffix(Self.folded)
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(steps.count == 1 ? "1 step" : "\(steps.count) steps")
                        .font(.system(size: 13, weight: .semibold))
                    if steps.count > Self.folded {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(steps.count <= Self.folded)
            .padding(.bottom, 6)
            if !open && steps.count > Self.folded {
                Text("\(steps.count - Self.folded) earlier")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .padding(.leading, 30).padding(.bottom, 6)
            }
            ForEach(Array(shown), id: \.key) { e in row(CrewStep(event: e)) }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
        .padding(.trailing, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ s: CrewStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: s.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(s.verb).font(.system(size: 15)).foregroundStyle(.secondary)
                    if !s.mono { Text(s.target).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.middle) }
                }
                if s.mono {
                    Text(s.target)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(3)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8, style: .continuous))
                }
                if let d = s.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
