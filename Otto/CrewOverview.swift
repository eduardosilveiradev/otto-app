import SwiftUI

/// Every crew message between everyone, once each, oldest first. A message sits in both the sender's and the
/// recipient's thread under one `id`, so keep the first copy. Tool calls and status lines stay out.
func crewMessages(_ threads: [String: [CrewEvent]]) -> [CrewEvent] {
    var seen = Set<String>()
    return threads.values.joined()
        .filter { $0.kind == "message" && seen.insert($0.id).inserted }
        .sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
}

/// "@PM", "@Planner", "@Writer1": the crew's name with the spaces taken out.
func handle(_ id: String) -> String { "@" + (id == "pm" ? "PM" : crewName(id).replacing(" ", with: "")) }

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
        let list = crewMessages(store.crew.threads)
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
        .navigationTitle("Crew")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ e: CrewEvent) -> some View {
        let from = e.from ?? e.agent
        let mine = from == "user"
        var text = AttributedString(" " + (e.text ?? ""))
        var at = AttributedString(handle(e.to ?? ""))
        at.font = .system(size: 14, weight: .medium)
        at.foregroundColor = mine ? Color.white.opacity(0.7) : Color.secondary
        text.insert(at, at: text.startIndex)
        // Otto's and the user's rows open the agent they spoke to.
        let target = from == "otto" || mine ? (e.to ?? e.agent) : from
        return Button { open(.agent(target)) } label: {
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

    private struct Stamp: View {
        let date: Date
        var body: some View {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
        }
    }
}
