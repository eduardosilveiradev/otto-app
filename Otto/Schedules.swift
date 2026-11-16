import SwiftUI

// What Otto has scheduled: the chip a reply carries when it armed something
// ("scheduled" on the message frame), the full trigger behind it, and the list
// of everything armed. All from the dashboard API's triggers routes.

struct TriggerDetail: Decodable {
    let id: String; let type: String; let schedule: String?; let gist: String
    let repeating: Bool; let enabled: Bool; let nextRun: Double?; let lastFired: String?
    let action: String; let condition: String?; let tz: String?; let createdAt: String
}

extension DashTrigger {
    var next: Date? { nextRun.map { Date(timeIntervalSince1970: $0 / 1000) } }
    /// When it runs, in words, and how soon: one line for Schedules and Activity alike.
    var whenLine: String {
        let line = scheduleLine(type: type, schedule: schedule, repeating: repeating, next: next)
        if !enabled { return lastFired.map { "ran \(ago($0))" } ?? "paused" }
        if repeating, let n = next { return "\(line) · next \(ago(n))" }
        if let n = next { return "\(line) · \(ago(n))" }
        return line
    }
    var icon: String { type == "email" ? "envelope.badge" : repeating ? "repeat" : "alarm" }
}

/// "Tue 27 Oct, 03:00", "Every day at 08:57", "When matching mail arrives".
func scheduleLine(type: String, schedule: String?, repeating: Bool, next: Date?) -> String {
    if type == "email" { return "When matching mail arrives" }
    if repeating, let s = schedule { return humanCron(s) ?? s }
    guard let next else { return schedule ?? "" }
    // "Today at 4:35 PM", "Tomorrow at 9:00 AM", as first-party apps say it; later days keep their date.
    if Calendar.current.isDateInToday(next) || Calendar.current.isDateInTomorrow(next) {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
        return f.string(from: next)
    }
    return next.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
}

/// The common shapes of a 5-field cron in words; nil for anything else, which then shows as written.
func humanCron(_ s: String) -> String? {
    let f = s.split(separator: " ").map(String.init)
    guard f.count == 5, f[2] == "*", f[3] == "*" else { return nil }
    if let n = f[0].stepValue, f[1] == "*" { return "Every \(n) minutes" }
    if let n = f[1].stepValue, let m = Int(f[0]) { return "Every \(n) hours at :\(String(format: "%02d", m))" }
    guard let m = Int(f[0]), let h = Int(f[1]) else { return nil }
    // In the phone's own clock style: "7:30 AM" or "07:30", as every other time on screen.
    let at = Calendar.current.date(from: DateComponents(hour: h, minute: m))?.formatted(date: .omitted, time: .shortened)
        ?? String(format: "%02d:%02d", h, m)
    let names = Calendar.current.weekdaySymbols   // Sunday first, as cron counts
    switch f[4] {
    case "*": return "Every day at \(at)"
    case "1-5": return "Weekdays at \(at)"
    case "0,6", "6,0": return "Weekends at \(at)"
    default:
        let days = f[4].split(separator: ",").compactMap { Int($0) }.map { names[$0 % 7] }
        return days.isEmpty ? nil : "\(days.formatted(.list(type: .and))) at \(at)"
    }
}

private extension String {
    var stepValue: Int? { hasPrefix("*/") ? Int(dropFirst(2)) : nil }
}

/// Sits inside Otto's bubble under the text: what was just scheduled, tap for the whole of it.
struct ScheduleChip: View {
    let trigger: DashTrigger
    #if DEBUG
    /// `-scheduleOpen`: the chip's sheet already up and at full height, for screenshots.
    private static let shot = CommandLine.arguments.contains("-scheduleOpen")
    #else
    private static let shot = false
    #endif
    @State private var open = shot
    @Environment(OttoStore.self) private var store

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 10) {
                GlyphDisc(symbol: trigger.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(trigger.gist).font(size: 15, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.primary).lineLimit(2)
                    Text(scheduleLine(type: trigger.type, schedule: trigger.schedule, repeating: trigger.repeating, next: trigger.next))
                        .font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(size: 12, weight: .semibold, relativeTo: .caption).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color.chip, in: .rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scheduled: \(trigger.gist)")
        .sheet(isPresented: $open) {
            NavigationStack {
                ScheduleDetail(id: trigger.id)
                    .toolbar { Button("Done") { open = false } }
            }
            .buttonStyle(.automatic)   // not the chip's plain style, which would come down into its sheet
            .environment(store)
            .presentationDetents(Self.shot ? [.large] : [.medium, .large])
        }
    }
}

struct ScheduleDetail: View {
    let id: String
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Loaded(path: "triggers/item", query: ["id": id]) { (t: TriggerDetail, reload) in
            detail(t).refreshable { await reload() }
        }
        .navigationTitle("Schedule").navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ t: TriggerDetail) -> some View {
        let next = t.nextRun.map { Date(timeIntervalSince1970: $0 / 1000) }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t.gist).font(.headline)
                    if !t.enabled { Pill(text: t.lastFired == nil ? "paused" : "done", tint: .secondary) }
                }
            }
            Section("When") {
                LabeledContent(t.repeating ? "Repeats" : "Runs",
                               value: scheduleLine(type: t.type, schedule: t.schedule, repeating: t.repeating, next: next))
                if t.repeating, t.enabled, let next { LabeledContent("Next", value: next.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())) }
                if let tz = t.tz { LabeledContent("Time zone", value: tz) }
                if let last = t.lastFired { LabeledContent("Last ran", value: ago(last)) }
                LabeledContent("Set up", value: ago(t.createdAt))
            }
            if let c = t.condition { Section("Watching for") { Text(c) } }
            Section("What Otto will do") {
                Text(t.action).font(.callout).textSelection(.enabled)
            }
            // Otto changes its own schedules, so both open the composer on the words that ask it: you finish
            // the sentence or just send, and Otto answers in the chat. The schedule goes in by a slug of its
            // line, as a memory does: its words come from the Mac and could be anything, and what's sent from
            // here is sent as you.
            if t.enabled {
                let name = MemoryDetailScreen.slug(t.gist)
                Section {
                    // Coloured here, not left to the tint: opened from a chip, the sheet inherits the bubble's ink.
                    Button("Change", systemImage: "pencil") { ask("change schedule \(name): ") }.foregroundStyle(.blue)
                    Button(t.repeating ? "Stop It" : "Cancel It", systemImage: "stop.circle", role: .destructive) { ask("stop schedule \(name)") }.foregroundStyle(.red)
                } footer: {
                    Text("Opens the chat with the words ready. Nothing changes until you send them.")
                }
            }
        }
    }

    private func ask(_ words: String) { store.prefill = words; dismiss() }
}

/// Everything armed, soonest first, and what has already run.
struct SchedulesScreen: View {
    var body: some View {
        Loaded(path: "triggers") { (t: Triggers, reload) in list(t).refreshable { await reload() } }
            .navigationTitle("Schedules").navigationBarTitleDisplayMode(.inline)
    }

    private func list(_ t: Triggers) -> some View {
        let on = t.triggers.filter(\.enabled)
        let once = on.filter { $0.type == "cron" && !$0.repeating }.sorted { ($0.nextRun ?? .infinity) < ($1.nextRun ?? .infinity) }
        let repeating = on.filter { $0.type == "cron" && $0.repeating }.sorted { ($0.nextRun ?? .infinity) < ($1.nextRun ?? .infinity) }
        let mail = on.filter { $0.type == "email" }
        let off = t.triggers.filter { !$0.enabled }.sorted { ($0.lastFired ?? "") > ($1.lastFired ?? "") }
        return List {
            if on.isEmpty && !off.isEmpty { Text("Nothing scheduled.").foregroundStyle(.secondary) }
            if !once.isEmpty { Section("Coming up") { ForEach(once) { row($0) } } }
            if !repeating.isEmpty { Section("Repeating") { ForEach(repeating) { row($0) } } }
            if !mail.isEmpty { Section("Watching mail") { ForEach(mail) { row($0) } } }
            if !off.isEmpty {
                Section {
                    NavigationLink("Done or paused · \(off.count)") {
                        List { ForEach(off) { row($0) } }.navigationTitle("Done or paused").navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
        .emptyState(t.triggers.isEmpty, "Nothing scheduled", systemImage: "calendar.badge.clock", "Ask Otto to remind you, or to check something on a schedule.")
    }

    private func row(_ t: DashTrigger) -> some View {
        NavigationLink { ScheduleDetail(id: t.id) } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.gist).lineLimit(2)
                    Text(t.whenLine).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: { RowIcon(symbol: t.icon) }
            .opacity(t.enabled ? 1 : 0.5)
        }
    }

}
