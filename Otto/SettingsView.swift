import SwiftUI

/// The same switches as Telegram's /settings, one tap each. They all live on the Mac.
struct SettingsView: View {
    @Environment(OttoStore.self) private var store
    @State private var page: SettingsPage?
    @State private var busy = false

    private static let sections = [("otto", "Otto"), ("recurring", "Recurring"), ("connectors", "Connectors")]

    var body: some View {
        List {
            if page == nil { ProgressView().frame(maxWidth: .infinity) }
            ForEach(Self.sections, id: \.0) { key, title in
                let ts = page?.toggles.filter { $0.section == key } ?? []
                if !ts.isEmpty {
                    Section {
                        ForEach(ts) { t in
                            Toggle(t.label.prefix(1).capitalized + t.label.dropFirst(),
                                   isOn: Binding(get: { t.on }, set: { _ in flip(t.id) }))
                                .disabled(busy)
                        }
                    } header: { Text(title) } footer: {
                        if key == "connectors" { Text("A change applies from the next session.") }
                    }
                }
            }
            if let note = page?.note, note.hasPrefix("couldn't") {
                Section { Text(note).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Settings")
        .refreshable { page = await store.backend.settings(flip: nil) ?? page }
        .task { page = await store.backend.settings(flip: nil) }
    }

    /// The Mac answers with the whole page as it is now, so a refused flip just shows unflipped.
    private func flip(_ id: String) {
        busy = true
        Task { page = await store.backend.settings(flip: id) ?? page; busy = false }
    }
}
