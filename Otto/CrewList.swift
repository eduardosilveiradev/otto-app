import SwiftUI

/// The root once the server runs a crew: Messages-style list, Otto pinned first, one thread per agent.
struct CrewRoot: View {
    let store: OttoStore
    enum Route: Hashable { case otto, agent(String) }
    @State private var path: [Route] = UserDefaults.standard.string(forKey: "crewThread").map { [.agent($0)] } ?? []

    var body: some View {
        NavigationStack(path: $path) {
            ChatListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .otto:
                        ChatScreen(store: store)
                            .ignoresSafeArea(.keyboard)
                            .toolbar(.hidden, for: .navigationBar)
                            .onAppear { store.crew.back = { path.removeAll() } }
                            .onDisappear { store.crew.back = nil }
                    case .agent(let id):
                        CrewThreadView(id: id)
                    }
                }
        }
    }
}

struct ChatListView: View {
    @Environment(OttoStore.self) private var store

    var body: some View {
        let crew = store.crew
        List {
            NavigationLink(value: CrewRoot.Route.otto) {
                HStack(spacing: 12) {
                    OttoAvatar(size: 48, asleep: store.asleep)
                    Row(title: "Otto", line: ottoLine, when: store.messages.last(where: { $0.from != .terminal })?.date, unread: 0)
                }
            }
            ForEach(crew.agents) { a in
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
        .refreshable { await crew.refresh() }
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

/// The role's symbol in a muted disc, with the status dot ringed onto its corner.
struct CrewAvatar: View {
    let agent: CrewAgent
    let size: CGFloat

    private var symbol: String {
        switch agent.role {
        case "pm": "person.badge.key"
        case "planner": "list.bullet.rectangle"
        case "designer": "paintbrush"
        case "writer": "hammer"
        default: "magnifyingglass"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "working": .blue
        case "waiting": .orange
        case "error": .red
        default: Color(.systemGray3)
        }
    }

    var body: some View {
        Circle().fill(Color(.systemGray5))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.4)).foregroundStyle(.secondary))
            .overlay(alignment: .bottomTrailing) {
                let dot = max(10, size * 0.25)
                Circle().fill(Self.color(agent.status))
                    .frame(width: dot, height: dot)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 1, y: 1)
            }
            .accessibilityLabel("\(agent.name), \(agent.status)")
    }
}
