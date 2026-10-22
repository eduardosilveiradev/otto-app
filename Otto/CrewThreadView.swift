import SwiftUI

/// One agent's thread: messages between roles and you, tool calls behind a toggle.
struct CrewThreadView: View {
    let id: String
    @Environment(OttoStore.self) private var store
    @AppStorage("crewShowTools") private var showTools = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// Long messages fold to six lines until "Read more".
    @State private var expanded: Set<String> = []
    private static let foldAt = 280
    /// `-crewCard`: open on the contact card, for screenshots.
    @State private var card = ProcessInfo.processInfo.arguments.contains("-crewCard")

    private var agent: CrewAgent? { store.crew.agents.first { $0.id == id } }
    private var events: [CrewEvent] {
        (store.crew.threads[id] ?? []).filter { showTools || $0.kind != "tool" }
    }

    /// A run of tool calls reads as one block of steps; everything else stands alone.
    private enum Item: Identifiable {
        case one(CrewEvent), steps([CrewEvent])
        var id: String { switch self { case .one(let e): e.key; case .steps(let s): "steps/" + s[0].key } }
        var first: CrewEvent { switch self { case .one(let e): e; case .steps(let s): s[0] } }
    }

    private static func items(_ events: [CrewEvent]) -> [Item] {
        var out: [Item] = []
        for e in events {
            if e.kind == "tool", case .steps(let s)? = out.last { out[out.count - 1] = .steps(s + [e]) }
            else { out.append(e.kind == "tool" ? .steps([e]) : .one(e)) }
        }
        return out
    }

    /// What it's doing right now, in the words Otto's own thinking bubble uses: its latest
    /// step since this run started, or just thinking.
    private var doing: String? {
        guard agent?.status == "working" else { return nil }
        let thread = store.crew.threads[id] ?? []
        let start = thread.lastIndex { $0.kind == "status" && $0.status == "working" } ?? thread.startIndex
        guard let t = thread[start...].last(where: { $0.kind == "tool" }) else { return "Thinking…" }
        return CrewStep(event: t).doing
    }

    var body: some View {
        let list = Self.items(events)
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy, like Otto's thread: lazily materialised rows went blank when the
                // thread changed under them (a run ending), and a crew thread is short.
                VStack(spacing: 2) {
                    if store.crew.threads[id]?.isEmpty ?? true, !store.crew.loaded.contains(id) {
                        ProgressView().padding(.top, 40)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        let prev = i > 0 ? list[i - 1].first : nil
                        let e = item.first
                        if prev.map({ e.date.timeIntervalSince($0.date) > 3600 }) ?? true { Stamp(date: e.date) }
                        switch item {
                        case .steps(let steps): CrewSteps(steps: steps).padding(.vertical, 4)
                        case .one(let e) where e.kind == "message":
                            let next: CrewEvent? = i + 1 < list.count ? list[i + 1].first : nil
                            bubble(e, prev: prev, tail: next?.kind != "message" || next?.from != e.from)
                        case .one(let e): statusLine(e)
                        }
                    }
                    if let doing {
                        Typing(status: doing, connected: store.connected)
                            .padding(.top, 10)
                            .transition(.scale(scale: 0.5, anchor: .bottomLeading).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: doing)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Tapping the thread puts the keyboard away; bubbles' own buttons still win.
            .contentShape(.rect)
            .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            .onChange(of: events.count) { withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        // Otto's own header and composer, not the system bar: every thread looks like his.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $card) { CrewContactCard(id: id) }
        .task {
            store.crew.open = id
            await store.crew.load(id)
            store.crew.markSeen(id)
        }
        .onDisappear {
            if store.crew.open == id { store.crew.open = nil }
            store.crew.markSeen(id)
        }
        .onChange(of: store.crew.threads[id]?.count) { if store.crew.open == id { store.crew.markSeen(id) } }
    }

    @ViewBuilder private func bubble(_ e: CrewEvent, prev: CrewEvent?, tail: Bool) -> some View {
        let mine = e.from == "user"
        let sameRun = prev?.kind == "message" && prev?.from == e.from
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if !mine, let from = e.from, from != id, !sameRun { caption(crewName(from)) }
            let long = (e.text ?? "").count > Self.foldAt
            let folded = long && !expanded.contains(e.key)
            VStack(alignment: .leading, spacing: 4) {
                Text(body(e))
                    .lineLimit(folded ? 6 : nil)
                    .font(.system(size: 17))
                    .foregroundStyle(mine ? .white : .primary)
                if long {
                    Button(folded ? "Read more" : "Show less") {
                        withAnimation(.snappy) { if folded { expanded.insert(e.key) } else { expanded.remove(e.key) } }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .tint(mine ? .white : .blue)
                    .buttonStyle(.plain)
                    .foregroundStyle(mine ? .white : .blue)
                }
            }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(BubbleShape(mine: mine, tail: tail).fill(mine ? Color.blue : Color(.systemGray5)))
                .padding(mine ? .leading : .trailing, 48)
            if store.crew.failed.contains(e.key) {
                Text("Not delivered").font(.caption2).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.top, sameRun ? 0 : 8)
    }

    /// Its own message to someone else opens with a small grey "@Name", the way a mention reads.
    private func body(_ e: CrewEvent) -> AttributedString {
        var text = AttributedString(e.text ?? "")
        guard e.from == id, let to = e.to, to != "user" else { return text }
        var at = AttributedString("@\(crewName(to).replacing(" ", with: "")) ")
        at.font = .system(size: 14, weight: .medium)
        at.foregroundColor = .secondary
        text.insert(at, at: text.startIndex)
        return text
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12)
    }

    private func statusLine(_ e: CrewEvent) -> some View {
        Text((e.status ?? "") + (e.note.map { " · \($0)" } ?? ""))
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    /// Mirrors Otto's header (ChatView): glass back and menu buttons, the face with a name pill under it.
    private var header: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                .accessibilityLabel("Messages")
                Spacer()
                Menu {
                    Toggle("Show tool calls", isOn: $showTools)
                    Button("Stop", role: .destructive) { Task { await store.crew.stop(id) } }
                        .disabled(agent?.status != "working")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
            }
            Button { card = true } label: {
                VStack(spacing: 4) {
                    if let agent { CrewAvatar(agent: agent, size: 56) }
                    HStack(spacing: 3) {
                        Text(crewName(id)).font(.system(size: 12, weight: .medium))
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
        .background(alignment: .top) {
            LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Otto's composer, minus photos and voice: the crew only takes text for now.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TextField("Text \(crewName(id))", text: $draft, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...6)
                .padding(.leading, 14).padding(.vertical, 8)
                .frame(minHeight: 36)
            if canSend {
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = ""
                    Task { await store.crew.send(id, text: text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.blue)
                        .frame(width: 36, height: 36)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: canSend)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
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
