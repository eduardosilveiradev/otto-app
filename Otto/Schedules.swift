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
    var icon: String { type == "email" ? "envelope.badge" : repeating ? "repeat" : "alarm" }
}

/// "Tue 27 Oct, 03:00", "Every day at 08:57", "When matching mail arrives".
func scheduleLine(type: String, schedule: String?, repeating: Bool, next: Date?) -> String {
    if type == "email" { return "When matching mail arrives" }
    if repeating, let s = schedule { return humanCron(s) ?? s }
    return next?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) ?? schedule ?? ""
}

/// The common shapes of a 5-field cron in words; nil for anything else, which then shows as written.
func humanCron(_ s: String) -> String? {
    let f = s.split(separator: " ").map(String.init)
    guard f.count == 5, f[2] == "*", f[3] == "*" else { return nil }
    if let n = f[0].stepValue, f[1] == "*" { return "Every \(n) minutes" }
    if let n = f[1].stepValue, let m = Int(f[0]) { return "Every \(n) hours at :\(String(format: "%02d", m))" }
    guard let m = Int(f[0]), let h = Int(f[1]) else { return nil }
    let at = String(format: "%02d:%02d", h, m)
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
    @State private var open = false
    @Environment(OttoStore.self) private var store

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 10) {
                Image(systemName: trigger.icon)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.blue)
                    .frame(width: 30, height: 30).background(Color.blue.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(trigger.gist).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(scheduleLine(type: trigger.type, schedule: trigger.schedule, repeating: trigger.repeating, next: trigger.next))
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(.systemBackground).opacity(0.7), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scheduled: \(trigger.gist)")
        .sheet(isPresented: $open) {
            NavigationStack {
                ScheduleDetail(id: trigger.id)
                    .toolbar { Button("Done") { open = false } }
            }
            .environment(store)
            .presentationDetents([.medium, .large])
        }
    }
}

struct ScheduleDetail: View {
    let id: String

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
        }
    }
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
            if on.isEmpty { Text("Nothing scheduled.").foregroundStyle(.secondary) }
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
    }

    private func row(_ t: DashTrigger) -> some View {
        NavigationLink { ScheduleDetail(id: t.id) } label: {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.gist).lineLimit(2)
                    Text(sub(t)).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: t.icon).foregroundStyle(t.enabled ? .blue : .secondary) }
        }
    }

    private func sub(_ t: DashTrigger) -> String {
        let line = scheduleLine(type: t.type, schedule: t.schedule, repeating: t.repeating, next: t.next)
        if !t.enabled { return t.lastFired.map { "ran \(ago($0))" } ?? "paused" }
        if t.repeating, let n = t.next { return "\(line) · next \(ago(n))" }
        if let n = t.next { return "\(line) · \(ago(n))" }
        return line
    }
}
