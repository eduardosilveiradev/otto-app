import SwiftUI

/// Every crew message between everyone, once each, oldest first. A message sits in both the sender's and the
/// recipient's thread under one `id`, so keep the first copy. Tool calls and status lines stay out.
func crewMessages(_ threads: [String: [CrewEvent]]) -> [CrewEvent] {
    var seen = Set<String>()
    return threads.values.joined()
        .filter { $0.kind == "message" && seen.insert($0.id).inserted }
        .sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
}

/// The crew's messages plus your own chat with Otto (both sides) since the crew's first word, so the
/// overview holds everything that was said while they worked.
func overviewMessages(_ threads: [String: [CrewEvent]], otto: [Message]) -> [CrewEvent] {
    let crew = crewMessages(threads)
    guard let first = crew.first?.date else { return crew }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let chat = otto.filter { ($0.from == .me || $0.from == .otto) && $0.date >= first }.map { m in
        let mine = m.from == .me
        return CrewEvent(id: "otto/" + m.id.uuidString, agent: "otto", kind: "message", ts: iso.string(from: m.date),
                         from: mine ? "user" : "otto", to: mine ? "otto" : "user",
                         text: m.text.isEmpty ? (m.image != nil ? "Photo" : "Voice message") : m.text,
                         tool: nil, summary: nil, status: nil, note: nil)
    }
    return (crew + chat).sorted { ($0.date, $0.id) < ($1.date, $1.id) }
}


/// A crew member's picture: Otto's own face, or the role's mascot.
private struct CrewFace: View {
    let id: String
    let size: CGFloat
    @Environment(OttoStore.self) private var store

    var body: some View {
        if id == "otto" { OttoAvatar(size: size) }
        else {
            CrewMascot(role: store.crew.agents.first { $0.id == id }?.role ?? String(id.split(separator: "-").first ?? ""),
                       index: Int(id.split(separator: "-").last ?? "") ?? 1, mood: .calm, size: size)
        }
    }
}

/// The overview's list-row picture: two or three of the latest speakers, overlapping inside one 48pt circle's worth.
struct CrewGroupAvatar: View {
    let ids: [String]
    var size: CGFloat = 48

    var body: some View {
        let face = size * (ids.count > 2 ? 0.6 : 0.68)
        let step = (size - face) / CGFloat(max(1, ids.count - 1))
        ZStack(alignment: .topLeading) {
            ForEach(Array(ids.enumerated()), id: \.offset) { i, id in
                CrewFace(id: id, size: face)
                    .background(Circle().fill(Color(.systemBackground)).padding(-2))
                    .offset(x: step * CGFloat(i), y: ids.count > 2 ? (i == 1 ? size - face : 0) : step * CGFloat(i))
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

/// One read-only thread of the whole crew's conversation.
struct CrewOverview: View {
    @Environment(OttoStore.self) private var store
    var open: (CrewRoot.Route) -> Void = { _ in }

    var body: some View {
        let list = overviewMessages(store.crew.threads, otto: store.messages)
        ScrollView {
            VStack(spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                    if i == 0 || e.date.timeIntervalSince(list[i - 1].date) > 900 { Stamp(date: e.date) }
                    row(e)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle("Crew")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ e: CrewEvent) -> some View {
        let from = e.from ?? e.agent
        let mine = from == "user"
        var text = AttributedString(" " + (e.text ?? ""))
        var at = AttributedString("@" + crewHandle(e.to ?? ""))
        at.font = .system(size: 14, weight: .medium)
        at.foregroundColor = mine ? Color.white.opacity(0.7) : Color.secondary
        text.insert(at, at: text.startIndex)
        // Otto's and the user's rows open the agent they spoke to.
        let target = from == "otto" || mine ? (e.to ?? e.agent) : from
        return Button { open(target == "otto" || target == "user" ? .otto : .agent(target)) } label: {
            HStack(alignment: .top, spacing: 8) {
                if mine { Spacer(minLength: 48) }
                else { CrewFace(id: from, size: 28) }
                VStack(alignment: .leading, spacing: 2) {
                    if !mine { Text(crewName(from)).font(.caption2).foregroundStyle(.secondary) }
                    Text(text).font(.body).lineLimit(2)
                        .foregroundStyle(mine ? Color.white : Color.primary)
                        .padding(.horizontal, mine ? 12 : 0).padding(.vertical, mine ? 7 : 0)
                        .background { if mine { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.blue) } }
                }
                if !mine { Spacer(minLength: 24) }
            }
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: composer

    @State private var draft = ""
    @FocusState private var focused: Bool

    /// Everyone you can tag: Otto first, then the crew, as "@handle" -> id.
    private var members: [(handle: String, id: String)] {
        [("Otto", "otto")] + store.crew.agents.map { (crewHandle($0.id), $0.id) }
    }

    /// The handles in the draft, resolved to ids, in the order written.
    private var tagged: [String] {
        draft.matches(of: #/@(\w+)/#).compactMap { m in
            members.first { $0.handle.lowercased() == m.1.lowercased() }?.id
        }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The word being typed, when it's an unfinished "@…": what the suggestions filter on.
    private var partial: String? {
        guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("@") else { return nil }
        return String(last.dropFirst()).lowercased()
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let partial {
                let hits = members.filter { partial.isEmpty || $0.handle.lowercased().hasPrefix(partial) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(hits, id: \.id) { m in
                            Button {
                                draft = String(draft.dropLast(partial.count + 1)) + "@" + m.handle + " "
                            } label: {
                                HStack(spacing: 6) {
                                    CrewFace(id: m.id, size: 22)
                                    Text("@" + m.handle).font(.system(size: 14, weight: .medium))
                                }
                                .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                                .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 0) {
                TextField(tagged.isEmpty ? "Message Otto, or @ someone" : "To " + tagged.map(crewName).joined(separator: ", "),
                          text: $draft, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.leading, 14).padding(.vertical, 8)
                    .frame(minHeight: 36)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.blue)
                            .frame(width: 36, height: 36)
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 12)
        }
        .animation(.snappy(duration: 0.22), value: partial)
        .padding(.top, 6).padding(.bottom, 4)
    }

    /// Each tagged crew member gets the message (tags and all, so they see who else was asked);
    /// no tag, or @Otto, goes to Otto.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let to = tagged.isEmpty ? ["otto"] : tagged
        for id in to {
            if id == "otto" { store.send(text) } else { Task { await store.crew.send(id, text: text) } }
        }
    }

    private struct Stamp: View {
        let date: Date
        var body: some View {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}
