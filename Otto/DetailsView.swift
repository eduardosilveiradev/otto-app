import SwiftUI

/// The contact card: what Otto knows about today, and the few settings there are.
struct DetailsView: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Server URL and token persist (LiveBackend.fromDefaults reads them at launch);
    // the rest is local state, not yet sent anywhere.
    @AppStorage("serverURL") private var server = ""
    @AppStorage("serverToken") private var token = ""
    @AppStorage("callNumber") private var callNumber = ""
    @State private var speakReplies = true
    /// Keepalive: instant notifications for some battery. Read by Keepalive.enabled.
    @AppStorage("stayAwake") private var stayAwake = true
    @State private var snoozedUntil: Date?
    @State private var done: Set<Loop.ID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        OttoAvatar(size: 96, asleep: store.asleep)
                        Text("Otto").font(.title.weight(.semibold))
                        // isLive isn't observable, so re-read it every second while the sheet is open.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(store.backend is MockBackend ? "mock data"
                                 : !store.connected ? "asleep — can't reach the server" : "connected")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if let b = store.brief { today(b) }

                Section {
                    if let until = snoozedUntil {
                        Button("Snoozed until \(until.formatted(date: .omitted, time: .shortened)) — wake") { snoozedUntil = nil }
                    } else {
                        Menu("Snooze notifications") {
                            ForEach([1, 2, 4], id: \.self) { h in
                                Button("\(h) hour\(h == 1 ? "" : "s")") { snoozedUntil = .now.addingTimeInterval(Double(h) * 3600) }
                            }
                        }
                    }
                    Toggle("Speak replies when I speak", isOn: $speakReplies)
                    Toggle("Stay connected in background", isOn: $stayAwake)
                }

                Section {
                    TextField("https://your-mac.your-tailnet.ts.net", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("App token", text: $token)
                    TextField("Otto's phone number", text: $callNumber).keyboardType(.phonePad)
                } header: { Text("Server") } footer: {
                    Text("Over Tailscale. Quit and reopen the app after changing these.")
                }
            }
            .refreshable { await store.refreshBrief() }
            .toolbar { Button("Done") { dismiss() } }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private func today(_ b: Brief) -> some View {
        Section {
            if b.events.isEmpty { Text("Nothing on the calendar").foregroundStyle(.secondary) }
            ForEach(b.events) { e in
                LabeledContent(e.title, value: e.start.formatted(date: .omitted, time: .shortened))
            }
        } header: { Text("Today") } footer: {
            Text("as of \(b.asOf.formatted(date: .omitted, time: .shortened)) \(TimeZone.current.abbreviation() ?? "")")
        }

        if !b.loops.isEmpty {
            Section("Open loops") {
                ForEach(b.loops) { l in
                    let closed = done.contains(l.id)
                    Button { done.formSymmetricDifference([l.id]) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: closed ? "checkmark" : l.title.contains("€") ? "eurosign" : "arrow.turn.up.left")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 7, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.title).strikethrough(closed)
                                    .foregroundStyle(closed ? .secondary : .primary)
                                if let due = l.due, !closed {
                                    Text("due \(due.formatted(.dateTime.weekday(.wide)))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(closed ? "Closed" : "Open")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(closed ? Color.secondary : Color.orange)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(closed ? Color(.tertiarySystemFill) : Color.orange.opacity(0.15), in: .capsule)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
