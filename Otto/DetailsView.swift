import SwiftUI

/// The contact card: what Otto knows about today, and the few settings there are.
struct DetailsView: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Server URL and token persist (LiveBackend.fromDefaults reads them at launch).
    // speakReplies and `done` are still local only: nothing reads them yet.
    @AppStorage("serverURL") private var server = ""
    @AppStorage("serverToken") private var token = ""
    @AppStorage("callNumber") private var callNumber = ""
    @State private var speakReplies = true
    /// Keepalive: instant notifications for some battery. Read by Keepalive.enabled.
    @AppStorage("stayAwake") private var stayAwake = true
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

                if let s = store.snooze, let until = s.until, until > .now { snoozed(s, until: until) }

                if let b = store.brief { today(b) }

                Section {
                    if store.snooze?.until.map({ $0 > .now }) != true {
                        Menu("Snooze notifications") {
                            ForEach([1, 2, 4], id: \.self) { h in
                                Button("\(h) hour\(h == 1 ? "" : "s")") { Task { await store.setSnooze(.minutes(h * 60)) } }
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
            .refreshable { await store.refreshBrief(); await store.setSnooze(nil) }
            .task { await store.setSnooze(nil) }
            .toolbar { Button("Done") { dismiss() } }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// The clock while Otto is holding things back, how far through the hold, and what's waiting.
    @ViewBuilder private func snoozed(_ s: Snooze, until: Date) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let start = s.since ?? tl.date
                let span = until.timeIntervalSince(start)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tl.date, format: .dateTime.hour().minute())
                            .font(.system(size: 44, weight: .light).monospacedDigit())
                        Spacer()
                        Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color(.tertiarySystemFill), in: .capsule)
                    }
                    ProgressView(value: span > 0 ? min(1, max(0, tl.date.timeIntervalSince(start) / span)) : 1)
                        .tint(.orange)
                    HStack(spacing: 10) {
                        Button { Task { await store.setSnooze(.clear) } } label: {
                            Text("Hand them over now").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(Color(.label)).foregroundStyle(Color(.systemBackground))
                        Button { Task { await store.setSnooze(.minutes(60)) } } label: {
                            Text("Another hour").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.secondary).foregroundStyle(.primary)
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 6)
            }
        }
        if !s.held.isEmpty {
            Section("Held for later · \(s.held.count)") {
                ForEach(s.held, id: \.self) { h in
                    LabeledContent {
                        Text(h.at, format: .dateTime.hour().minute())
                    } label: {
                        Text(h.text).lineLimit(1)
                    }
                }
            }
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
