import SwiftUI

// MARK: - Activity

/// How often Otto speaks up unasked and whether you answer, what it changed about itself,
/// its background jobs, and what's armed.
struct ActivityScreen: View {
    enum Tab: String, CaseIterable { case messages = "Unasked", changes = "Changes", jobs = "Jobs", triggers = "Triggers" }
    @State private var tab = Tab.messages
    /// Trigger gists, to name "trigger:<id>" sources.
    @State private var gists: [String: String] = [:]
    @Environment(OttoStore.self) private var store

    var body: some View {
        // Captured by value, so the list redraws when the names arrive after it.
        let names = gists
        Group {
            switch tab {
            case .messages: Loaded(path: "proactivity") { (p: Proactivity, reload) in proactivity(p, names).refreshable { await reload() } }
            case .changes: Loaded(path: "capabilities") { (c: Capabilities, reload) in changes(c).refreshable { await reload() } }
            case .jobs: Loaded(path: "jobs") { (j: Jobs, reload) in jobs(j).refreshable { await reload() } }
            case .triggers: Loaded(path: "triggers") { (t: Triggers, reload) in triggers(t).refreshable { await reload() } }
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6)
        }
        .navigationTitle("Activity").navigationBarTitleDisplayMode(.inline)
        .task {
            if let t: Triggers = await store.backend.dash("triggers") {
                gists = Dictionary(t.triggers.map { ($0.id, $0.gist) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private func source(_ src: String, _ names: [String: String]) -> String {
        if src.hasPrefix("trigger:"), let g = names[String(src.dropFirst(8))] { return g }
        let s = src.replacing(#/[-_:]+/#, with: " ").trimmingCharacters(in: .whitespaces)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func proactivity(_ p: Proactivity, _ names: [String: String]) -> some View {
        let sent = p.stats.reduce(0) { $0 + $1.sent }, engaged = p.stats.reduce(0) { $0 + $1.engaged }
        return List {
            Section {
                LabeledContent("Sent unasked", value: "\(sent)")
                LabeledContent("Got a reply", value: sent > 0 ? "\(engaged) · \(Int((Double(engaged) / Double(sent) * 100).rounded()))%" : "—")
            } footer: { Text("Last 30 days.") }
            Section("By source") {
                ForEach(p.stats.sorted { $0.sent > $1.sent }) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(source(s.src, names)).lineLimit(2)
                            Spacer(minLength: 8)
                            if s.engaged == 0 && s.sent >= 3 { Pill(text: "never answered", tint: .orange) }
                        }
                        Text("\(s.sent) sent · \(s.engaged) answered\(s.silentStreak > 1 ? " · last \(s.silentStreak) unanswered" : "")\(s.lastSent.map { " · \(ago($0))" } ?? "")")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func changes(_ c: Capabilities) -> some View {
        List {
            if c.entries.isEmpty { Text("Nothing changed in the last 30 days.").foregroundStyle(.secondary) }
            ForEach(c.entries) { e in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.what).lineLimit(4)
                        Spacer(minLength: 8)
                        if e.revertedAt != nil { Pill(text: "undone") }
                    }
                    Text("\(ago(e.at)) · \(e.by) · \(e.tier) · \(e.origin.replacing("-", with: " "))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func jobs(_ j: Jobs) -> some View {
        List {
            if j.jobs.isEmpty { Text("No background jobs.").foregroundStyle(.secondary) }
            ForEach(j.jobs.sorted { $0.createdAt > $1.createdAt }) { job in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(job.task).font(.headline)
                            if let r = job.result { MarkdownText(text: r).textSelection(.enabled) }
                            if let e = job.error { Text(e).foregroundStyle(.red) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                    .navigationTitle(job.state.capitalized).navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(job.task).lineLimit(2)
                            Spacer(minLength: 8)
                            Pill(text: job.state, tint: job.state == "running" ? .orange : job.state == "failed" ? .red : .secondary)
                        }
                        Text([ago(job.createdAt), job.costUsd.map { $0.formatted(.currency(code: "USD")) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func triggers(_ t: Triggers) -> some View {
        let on = t.triggers.filter(\.enabled).sorted { ($0.nextRun ?? .infinity) < ($1.nextRun ?? .infinity) }
        let off = t.triggers.filter { !$0.enabled }
        return List {
            Section("Armed · \(on.count)") {
                if on.isEmpty { Text("Nothing armed.").foregroundStyle(.secondary) }
                ForEach(on) { trig($0) }
            }
            if !off.isEmpty {
                Section {
                    NavigationLink("Spent or paused · \(off.count)") {
                        List { ForEach(off) { trig($0) } }.navigationTitle("Spent or paused").navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
    }

    private func trig(_ t: DashTrigger) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.gist).lineLimit(3)
            let when: String = if let n = t.nextRun { "next \(ago(Date(timeIntervalSince1970: n / 1000)))" }
                else if t.type == "email" { "on matching mail" }
                else { t.lastFired.map { "fired \(ago($0))" } ?? "" }
            Text([when, t.repeating ? "repeats" : nil, t.type == "cron" && t.repeating ? t.schedule : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct Proactivity: Decodable { let stats: [SourceStats] }
struct Capabilities: Decodable { let entries: [CapRow] }
struct Jobs: Decodable { let jobs: [JobRow] }
struct Triggers: Decodable { let triggers: [DashTrigger] }

// MARK: - Status

/// Every moving part on the Mac and when it last checked in.
struct StatusScreen: View {
    var body: some View {
        Loaded(path: "status") { (s: DashStatus, reload) in
            List {
                Section {
                    ForEach(s.rows) { r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(color(r.verdict)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.label)
                                Text(r.detail).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if r.verdict != "up" { Text(r.verdict).font(.footnote).foregroundStyle(color(r.verdict)) }
                        }
                    }
                } footer: {
                    let bad = s.rows.filter { $0.verdict == "down" || $0.verdict == "degraded" }.count
                    Text(bad == 0 ? "Everything that's on is up." : "\(bad) need\(bad == 1 ? "s" : "") a look.")
                }
                if !s.repairs.isEmpty {
                    Section("Recent repairs") {
                        ForEach(Array(s.repairs.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Status").navigationBarTitleDisplayMode(.inline)
    }

    private func color(_ v: String) -> Color {
        switch v { case "up": .green; case "degraded": .orange; case "down": .red; default: .gray }
    }
}

// MARK: - Devices

/// Paired apps and dashboards. A dashboard can be signed out from here; an app token only from the Mac.
struct DevicesScreen: View {
    struct Devices: Decodable { let devices: [Device] }
    struct Me: Decodable { let id: String }
    @Environment(OttoStore.self) private var store
    @State private var me: String?

    var body: some View {
        Loaded(path: "devices") { (d: Devices, reload) in
            List {
                Section {
                    ForEach(d.devices.sorted { ($0.lastUsed ?? $0.created) > ($1.lastUsed ?? $1.created) }) { dev in
                        HStack(spacing: 12) {
                            RowIcon(symbol: dev.origin == nil ? "iphone" : "macbook")
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(dev.name)
                                    if dev.id == me { Pill(text: "this phone", tint: .orange) }
                                }
                                Text(detail(dev)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if dev.origin != nil {
                                Button("Sign Out", role: .destructive) {
                                    Task {
                                        struct Revoked: Decodable { let revoked: Bool }
                                        let _: Revoked? = await store.backend.dash("devices/\(dev.id)", method: "DELETE")
                                        await reload()
                                    }
                                }
                            }
                        }
                    }
                } footer: { Text("Swipe a dashboard to sign it out. App tokens are revoked on the Mac.") }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Devices").navigationBarTitleDisplayMode(.inline)
        .task { me = (await store.backend.dash("me") as Me?)?.id }
    }

    private func detail(_ d: Device) -> String {
        var bits: [String] = []
        if let o = d.origin { bits.append("\(d.scope == "write" ? "control" : "read only") · \(URL(string: o)?.host() ?? o)") } else { bits.append("app") }
        if let ua = d.ua { bits.append(ua) }
        bits.append(d.lastUsed.map { "used \(ago($0))" } ?? "never used")
        if let e = d.expires { bits.append(dashDate(e).map { $0 < .now ? "expired" : "until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "") }
        return bits.joined(separator: " · ")
    }
}
