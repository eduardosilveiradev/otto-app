import SwiftUI

/// The root once the server runs a crew: Messages-style list, Otto pinned first, one thread per agent.
struct CrewRoot: View {
    let store: OttoStore
    enum Route: Hashable { case otto, agent(String), overview }
    @State private var path: [Route] = ProcessInfo.processInfo.arguments.contains("-crewOverview") ? [.overview]
        : UserDefaults.standard.string(forKey: "crewThread").map { [.agent($0)] } ?? []

    var body: some View {
        NavigationStack(path: $path) {
            ChatListView { path.append($0) }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .otto:
                        ChatScreen(store: store)
                            .ignoresSafeArea(.keyboard)
                            .toolbar(.hidden, for: .navigationBar)
                    case .agent(let id):
                        // Otto's own chat, on this agent's thread.
                        ChatScreen(store: store, agent: id)
                            .ignoresSafeArea(.keyboard)
                            .toolbar(.hidden, for: .navigationBar)
                    case .overview:
                        CrewOverview { path.append($0) }
                    }
                }
        }
        #if DEBUG
        // `-crewMoods`: every role in every mood, for screenshots.
        .overlay { if ProcessInfo.processInfo.arguments.contains("-crewMoods") { MoodGallery() } }
        #endif
        .onChange(of: path, initial: true) { _, p in
            store.crew.back = p.isEmpty ? nil : { path.removeAll() }
        }
        .onChange(of: store.crew.pendingThread, initial: true) { _, route in
            guard let route else { return }
            path = [route]
            store.crew.pendingThread = nil
        }
    }
}

// Hiding the bar drops the edge-swipe pop; restore it for every stack.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}

struct ChatListView: View {
    @Environment(OttoStore.self) private var store
    @AppStorage("crewShowTools") private var showTools = false
    /// Pushes a thread, for the compose menu.
    var open: (CrewRoot.Route) -> Void = { _ in }

    var body: some View {
        let crew = store.crew
        List {
            NavigationLink(value: CrewRoot.Route.otto) {
                HStack(spacing: 12) {
                    OttoAvatar(size: 48, asleep: store.asleep)
                    Row(title: "Otto", line: ottoLine, when: store.messages.last(where: { $0.from != .terminal })?.date, unread: 0)
                }
            }
            overviewRow
            // Newest conversation first, like Messages; Otto stays pinned above. Ties keep roster order.
            ForEach(crew.agents.enumerated().sorted { l, r in
                let a = crew.latest(l.element), b = crew.latest(r.element)
                return a == b ? l.offset < r.offset : a > b
            }.map(\.element)) { a in
                NavigationLink(value: CrewRoot.Route.agent(a.id)) {
                    HStack(spacing: 12) {
                        CrewAvatar(agent: a, size: 48)
                        Row(title: a.name, line: line(a), when: LiveBackend.date(a.lastAt), unread: crew.unread(a.id))
                    }
                }
                .swipeActions(edge: .trailing) {
                    if a.status == "working" {
                        Button("Stop", role: .destructive) { Task { await crew.stop(a.id) } }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Toggle("Show tool calls", isOn: $showTools)
                    if crew.agents.contains(where: { crew.unread($0.id) > 0 }) {
                        Button("Mark All as Read", systemImage: "envelope.open") {
                            for a in crew.agents { crew.markSeen(a.id) }
                        }
                    }
                    let busy = crew.agents.filter { $0.status == "working" }
                    if !busy.isEmpty {
                        Button("Stop all", systemImage: "stop.fill", role: .destructive) {
                            Task { for a in busy { await crew.stop(a.id) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Messages").font(.system(size: 17, weight: .semibold))
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .animation(.snappy, value: summary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Otto") { open(.otto) }
                    Section("Crew") {
                        ForEach(crew.agents) { a in Button(a.name) { open(.agent(a.id)) } }
                    }
                } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New message")
            }
        }
        .refreshable { await crew.refresh() }
    }

    /// Who's busy, at a glance: "2 working · 1 waiting", or how many are on the crew.
    private var summary: String {
        let a = store.crew.agents
        let parts = [("working", "working"), ("waiting", "waiting"), ("error", "stuck")].compactMap { s, word in
            let n = a.filter { $0.status == s }.count
            return n > 0 ? "\(n) \(word)" : nil
        }
        return parts.isEmpty ? "\(a.count) on the crew, all free" : parts.joined(separator: " · ")
    }

    /// Pinned under Otto: the whole crew's conversation, with the latest speakers as its picture.
    private var overviewRow: some View {
        let last = crewMessages(store.crew.threads)
        let speakers = last.reversed().compactMap(\.from).filter { $0 != "user" }
        var faces: [String] = []
        for id in speakers where !faces.contains(id) && faces.count < 3 { faces.append(id) }
        for a in store.crew.agents where faces.count < 2 && !faces.contains(a.id) { faces.append(a.id) }
        let line = last.last.map { (($0.from == "user" ? "You" : crewName($0.from ?? $0.agent)) + ": ") + ($0.text ?? "") } ?? "No messages yet"
        return NavigationLink(value: CrewRoot.Route.overview) {
            HStack(spacing: 12) {
                CrewGroupAvatar(ids: faces)
                Row(title: "Crew", line: line, when: last.last?.date, unread: 0)
            }
        }
    }

    private var ottoLine: String {
        guard let m = store.messages.last(where: { $0.from != .terminal }) else { return "" }
        let text = m.text.isEmpty ? (m.image != nil ? "Photo" : "") : m.text
        return m.from == .me ? "You: " + text : text
    }

    private func line(_ a: CrewAgent) -> String {
        guard let l = a.lastLine else { return "No messages yet" }
        guard let from = a.lastFrom, from != a.id else { return l }
        return "\(crewName(from)): \(l)"
    }

    private struct Row: View {
        let title: String
        let line: String
        let when: Date?
        let unread: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    if let when { Text(shortWhen(when)).font(.system(size: 15)).foregroundStyle(.secondary) }
                }
                HStack(alignment: .top) {
                    Text(line).font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if unread > 0 {
                        Text("\(unread)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                            .background(Capsule().fill(Color.blue))
                    }
                }
            }
        }
    }
}

/// Time today, weekday this week, else the date: the way Messages dates a conversation.
func shortWhen(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    if d > Date().addingTimeInterval(-6 * 86400) { return d.formatted(.dateTime.weekday(.wide)) }
    return d.formatted(date: .numeric, time: .omitted)
}

/// A thread's back button, as Messages draws it: the chevron, plus how many unread messages wait in
/// the other threads. `current` is the thread on screen, left out of the count; nil (Otto) counts every agent.
struct ThreadBackButton: View {
    var current: String?
    @Environment(OttoStore.self) private var store

    var body: some View {
        let crew = store.crew
        let unread = crew.agents.filter { $0.id != current }.reduce(0) { $0 + crew.unread($1.id) }
        Button { crew.back?() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, unread > 0 ? 12 : 0)
            .frame(minWidth: 40, minHeight: 40)
            .glassEffect(.regular.interactive(), in: .capsule)
            .animation(.snappy, value: unread)
        }
        .tint(.primary)
        .accessibilityLabel(unread > 0 ? "Messages, \(unread) unread" : "Messages")
    }
}

/// The role's mascot, its face following the agent's status, with the status dot ringed onto its corner.
/// A run that finishes gets a couple of seconds of happy before it settles.
struct CrewAvatar: View {
    let agent: CrewAgent
    let size: CGFloat
    @State private var cheer = false

    static func color(_ status: String) -> Color {
        switch status {
        case "working": .blue
        case "waiting": .orange
        case "error": .red
        default: Color(.systemGray3)
        }
    }

    var body: some View {
        CrewMascot(role: agent.role, index: Int(agent.id.split(separator: "-").last ?? "") ?? 1,
                   mood: cheer ? .happy : .init(status: agent.status), size: size)
            .overlay(alignment: .bottomTrailing) {
                let dot = max(10, size * 0.25)
                Circle().fill(Self.color(agent.status))
                    .frame(width: dot, height: dot)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 1, y: 1)
            }
            .onChange(of: agent.status) { old, new in
                guard old == "working", new == "idle" else { return }
                cheer = true
                Task { try? await Task.sleep(for: .seconds(2.5)); cheer = false }
            }
            .accessibilityElement()
            .accessibilityLabel("\(agent.name), \(agent.status)")
    }
}

#if DEBUG
private struct MoodGallery: View {
    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 18) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(CrewMascot.Mood.allCases, id: \.self) { Text($0.rawValue).font(.caption2).foregroundStyle(.secondary) }
            }
            ForEach(["pm", "planner", "designer", "writer", "reviewer"], id: \.self) { role in
                GridRow {
                    Text(role).font(.caption2).foregroundStyle(.secondary)
                    ForEach(CrewMascot.Mood.allCases, id: \.self) { CrewMascot(role: role, mood: $0, size: 52) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
#endif
