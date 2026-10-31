import SwiftUI

// What Otto wrote down while answering: money, a memory, a loop, a place, a person,
// a calendar event. Rides the message frame as "recorded", one card each, the same
// shape as the schedule chip. A card's action goes back as a tap, like a button.

struct RecordedCard: Codable, Hashable, Identifiable {
    struct Action: Codable, Hashable { let label: String; let data: String }
    let kind: String; let id: String; let title: String
    let detail: String?; let body: String?; let action: Action?

    var icon: String {
        switch kind {
        case "money": "creditcard"
        case "memory": "brain"
        case "loop": "circle.dashed"
        case "place": "mappin"
        case "person": "person"
        default: detail == "Calendar" ? "calendar" : "checkmark"
        }
    }
    var heading: String {
        switch kind {
        case "money": "Spending"
        case "memory": "Memory"
        case "loop": "Open loop"
        case "place": "Place"
        case "person": "Person"
        default: detail == "Calendar" ? "Calendar" : "Added"
        }
    }
}

/// Sits inside Otto's bubble under the text; tap for the rest and its one action.
struct RecordedChip: View {
    let card: RecordedCard
    let message: Message.ID
    @State private var open = false
    @Environment(OttoStore.self) private var store

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 10) {
                Image(systemName: card.icon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue)
                    .frame(width: 30, height: 30).background(Color.blue.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(card.detail ?? card.heading).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(.systemBackground).opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.heading): \(card.title)")
        .sheet(isPresented: $open) {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.title).font(.headline)
                            if let d = card.detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                    if let b = card.body { Section { Text(b).font(.callout).textSelection(.enabled) } }
                    if let a = card.action {
                        Section {
                            Button(a.label, role: a.data.hasPrefix("forget") || a.data.hasPrefix("undo") ? .destructive : nil) {
                                open = false
                                store.tap(ActionButton(label: a.label, data: a.data), on: message)
                            }
                        }
                    }
                }
                .navigationTitle(card.heading).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { open = false } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
