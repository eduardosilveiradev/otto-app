import SwiftUI

/// The same switches as Telegram's /settings, one tap each. They all live on the Mac.
struct SettingsView: View {
    @Environment(OttoStore.self) private var store
    @State private var page: SettingsPage?
    @State private var busy = false
    /// The Mac didn't answer: with no page yet that's the whole screen; with one, a line over what loaded before.
    @State private var failed = false
    /// The switch whose flip got no answer, so it's still as it was: said under it, by name.
    @State private var unchanged: String?

    private static let sections = [("otto", "Otto"), ("recurring", "Recurring"), ("connectors", "Connectors")]

    var body: some View {
        List {
            if page == nil && !failed { ProgressView().frame(maxWidth: .infinity) }
            // With switches on screen, a line over them; with nothing to show, the whole-page state below.
            if failed, page != nil {
                Section {
                    Text("Couldn’t reach your Mac. These are as they were when it last answered.")
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                }
            }
            ForEach(Self.sections, id: \.0) { key, title in
                let ts = page?.toggles.filter { $0.section == key } ?? []
                if !ts.isEmpty {
                    Section {
                        ForEach(ts) { t in
                            let name = t.label.prefix(1).capitalized + t.label.dropFirst()
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(name, isOn: Binding(get: { t.on }, set: { _ in flip(t.id) }))
                                    .disabled(busy)
                                if unchanged == t.id {
                                    Text("Didn’t change: your Mac didn’t answer. Try again.").font(.footnote).foregroundStyle(Color.redInk)
                                }
                            }
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
        // Nothing loaded: the state every other card page shows (Loaded), in the same words.
        .overlay {
            if page == nil && failed {
                ContentUnavailableView {
                    Label(store.noNetwork ? "You’re offline" : "Can’t reach your Mac", systemImage: "wifi.slash")
                } description: {
                    Text(store.noNetwork ? "Connect to Wi-Fi or mobile data."
                         : store.backend is MockBackend ? "This page needs your Mac. You’re looking at sample data."
                         : store.backend.isLive ? "Otto didn’t answer. Try again in a moment." : "Check it’s awake and on Tailscale.")
                } actions: {
                    if !(store.backend is MockBackend) { Button("Try again") { Task { await load() } } }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)   // as every other card page: a large title sat on the first section's header
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        let fresh = await store.backend.settings(flip: nil)
        if let fresh { page = fresh; unchanged = nil }
        failed = fresh == nil
    }

    /// The Mac answers with the whole page as it is now, so a refused flip just shows unflipped (with its
    /// note). No answer at all leaves the switch where it was, and says so under it.
    private func flip(_ id: String) {
        busy = true
        Task {
            let fresh = await store.backend.settings(flip: id)
            if let fresh { page = fresh; failed = false }
            unchanged = fresh == nil ? id : nil
            if fresh == nil { AccessibilityNotification.Announcement("Didn’t change: your Mac didn’t answer.").post() }
            busy = false
        }
    }
}
