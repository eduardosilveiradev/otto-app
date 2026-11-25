import Charts
import SwiftUI

// MARK: - Loops

/// Every open loop, what tonight's hygiene pass would do with them, and what it closed lately.
struct LoopsScreen: View {
    var body: some View {
        Loaded(path: "loops") { (l: DashLoops, reload) in LoopsList(l: l, reload: reload) }
            .navigationTitle("Loops").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LoopsList: View {
    let l: DashLoops
    let reload: () async -> Void
    @Environment(OttoStore.self) private var store
    /// Flipped here at once, put back if the Mac doesn't take it.
    @State private var flipped: Set<String> = []

    var body: some View {
        let text = Dictionary(l.open.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        List {
            if !l.open.isEmpty {
                Section {
                    ForEach(l.open) { row($0, closed: flipped.contains($0.id)) }
                } header: { Text("Open · \(l.open.count)") }
            }

            let p = l.plan
            if !p.close.isEmpty || !p.propose.isEmpty || !p.avoidance.isEmpty {
                Section {
                    ForEach(p.close, id: \.id) { c in
                        plan("checkmark.circle", text[c.id] ?? c.id, "Will close it · \(c.reason)")
                    }
                    ForEach(p.propose, id: \.id) { c in plan("questionmark.circle", c.text, "Will ask you · \(c.reason)") }
                    ForEach(p.avoidance, id: \.id) { c in plan("arrow.uturn.right.circle", c.text, "pushed back \(c.deferrals)×") }
                } header: { Text("Overnight tidy-up") } footer: {
                    Text("Runs at \(Self.fiveAM). Closes what’s clearly done, asks you about the rest.")
                }
            }

            if !l.recent.isEmpty {
                Section("Closed lately") {
                    ForEach(l.recent) { row($0, closed: !flipped.contains($0.id)) }
                }
            }
        }
        .emptyState(l.open.isEmpty && l.recent.isEmpty && l.plan.close.isEmpty && l.plan.propose.isEmpty && l.plan.avoidance.isEmpty,
                    "Nothing open", systemImage: "checklist", "Things you said you’d do show up here.")
        .refreshable { await reload() }
    }

    private func row(_ r: LoopRow, closed: Bool) -> some View {
        NavigationLink {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(r.text).textSelection(.enabled)
                    Text(meta(r)).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle(closed ? "Closed loop" : "Open loop").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(closed ? "Reopen" : "Done") { flip(r.id, done: !closed) } }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: closed ? "checkmark.circle.fill" : "circle")   // Reminders' mark, bare
                    .font(.title3.weight(.light)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.text).lineLimit(3).strikethrough(closed).foregroundStyle(closed ? .secondary : .primary)
                    let m = meta(r)
                    // Only the date goes red when it's passed, as in Reminders; the rest stays secondary.
                    let due = late(r) ? r.due.map { "was due \(day($0))" } : nil
                    if let due, m.hasPrefix(due) {
                        Text("\(Text(due).foregroundStyle(Color.redInk))\(Text(String(m.dropFirst(due.count))).foregroundStyle(.secondary))")
                            .font(.footnote).lineLimit(2)
                    } else if !m.isEmpty {
                        Text(m).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .swipeActions {
            Button(closed ? "Reopen" : "Done") { flip(r.id, done: !closed) }.tint(closed ? .gray : .blue)
        }
    }

    /// The tidy-up's 05:00 in the phone's own clock style ("5:00 AM" or "05:00").
    private static var fiveAM: String {
        Calendar.current.date(bySettingHour: 5, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "05:00"
    }

    /// Open and past its day. Compared as calendar days ("2026-11-07"), so a time zone can't shift it.
    private func late(_ r: LoopRow) -> Bool {
        guard let due = r.due, r.status == nil || r.status == "open" else { return false }
        return due.prefix(10) < Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    private func meta(_ r: LoopRow) -> String {
        var bits: [String] = []
        if let due = r.due { bits.append("\(late(r) ? "was due" : "due") \(day(due))") }
        if let n = r.deferrals?.count, n > 0 { bits.append("pushed back \(n)×") }
        if let why = r.closedReason { bits.append(why) } else if let at = r.closedAt { bits.append("closed \(ago(at))") }
        if r.status == nil || r.status == "open" { bits.append("opened \(ago(r.createdAt))") }
        return bits.joined(separator: " · ")
    }

    private func plan(_ symbol: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2)
                Text(sub).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func flip(_ id: String, done: Bool) {
        flipped.formSymmetricDifference([id])
        Task {
            if await store.backend.setLoop(id, done: done) { await reload(); flipped.remove(id) }
            else { flipped.formSymmetricDifference([id]) }
        }
    }
}

// MARK: - Money

/// Spend from receipts and bank mail, by month and category. Totals stay per currency; the one
/// combined figure is marked approximate and names its ECB rates.
struct MoneyScreen: View {
    @State private var month: String?
    @State private var currency: String?
    @State private var category: String?

    private var query: [String: String] {
        var q: [String: String] = [:]
        q["month"] = month; q["currency"] = currency; q["category"] = category
        return q
    }

    var body: some View {
        Loaded(path: "money", query: query) { (m: DashMoney, reload) in
            MoneyList(m: m, reload: reload, month: $month, currency: $currency, category: $category)
        }
        .navigationTitle("Money").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MoneyList: View {
    let m: DashMoney
    let reload: () async -> Void
    @Binding var month: String?
    @Binding var currency: String?
    @Binding var category: String?
    @Environment(OttoStore.self) private var store
    @State private var rates: ECB.Rates?

    var body: some View {
        // byCategory is in the requested currency, else the most used one.
        let cur = currency ?? m.byCurrency.first?.currency ?? "EUR"
        let top = m.byCategory.map(\.total).max() ?? 0
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(money(m.byCurrency.first { $0.currency == cur }?.total ?? 0, cur))
                        .monospacedDigit().font(size: 40, weight: .semibold, relativeTo: .largeTitle)
                    Text("\(month.map(monthName) ?? "All time")\(category.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    let others = m.byCurrency.filter { $0.currency != cur }
                    if !others.isEmpty {
                        Text("plus " + others.map { money($0.total, $0.currency) }.joined(separator: ", "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let r = rates, m.byCurrency.count > 1, m.byCurrency.first?.currency == r.base,
                       let all = ECB.combined(m.byCurrency, in: r) {
                        let on = dashDate(r.date)?.formatted(.dateTime.day().month(.abbreviated)) ?? r.date
                        Text("≈ \(money(all, r.base)) total · ECB \(on)")
                            .monospacedDigit().font(.footnote).foregroundStyle(.secondary)
                            .accessibilityLabel("About \(money(all, r.base)) in all, at European Central Bank rates of \(on)")
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Menu(month.map(monthName) ?? "All months") {
                        Button("All months") { month = nil }
                        ForEach(m.byMonth.map(\.month).sorted(by: >), id: \.self) { mo in Button(monthName(mo)) { month = mo } }
                    }
                    Spacer()
                    Menu(cur) {
                        ForEach(m.byCurrency, id: \.self) { c in Button("\(c.currency) · \(c.count)") { currency = c.currency } }
                    }
                }
            }

            let series = m.byMonth.compactMap { mo in mo.totals.first { $0.currency == cur }.map { (mo.month, $0.total) } }
                .sorted { $0.0 < $1.0 }.suffix(12)
            if series.count > 1 {
                Section("By month · \(cur)") {
                    Chart(Array(series), id: \.0) { mo, total in
                        BarMark(x: .value("Month", String(monthName(mo).prefix(3))), y: .value("Spent", total), width: .ratio(0.45))
                            .foregroundStyle(month == nil || mo == month ? Color.primary : Color.primary.opacity(0.3))
                            .cornerRadius(5)
                    }
                    .chartXAxis { AxisMarks { AxisValueLabel() } }   // month names, no vertical rules
                    .frame(height: 160)
                    .padding(.vertical, 6)
                }
            }

            if !m.byCategory.isEmpty {
                Section {
                    ForEach(m.byCategory, id: \.self) { c in
                        Button { category = category == c.category ? nil : c.category } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(c.category.prefix(1).uppercased() + c.category.dropFirst())   // sentence case, "Eating out"
                                    if category == c.category { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.primary) }
                                    Spacer()
                                    Text(money(c.total, cur)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                GeometryReader { g in
                                    Capsule().fill(Color.primary.opacity(category == nil || category == c.category ? 1 : 0.25))
                                        .frame(width: top > 0 ? max(4, g.size.width * c.total / top) : 4)
                                }
                                .frame(height: 4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("By category · \(cur)") } footer: { Text("Tap one to see only its charges.") }
            }

            Section("Charges · \(m.records.count)") {
                if m.records.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(m.records) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.merchant)
                            Text([day(r.date), r.category, r.method].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(r.amount, r.currency)).monospacedDigit()
                    }
                }
            }
        }
        .refreshable { await reload() }
        // The main currency is the most used one, first in byCurrency; it can change with the month.
        .task(id: m.byCurrency.map(\.currency)) {
            let codes = m.byCurrency.map(\.currency)
            guard codes.count > 1 else { return }
            rates = store.backend is MockBackend ? MockDash.rates : await ECB.rates(codes[0], Array(codes.dropFirst()))
        }
    }

    private func monthName(_ ym: String) -> String {
        dashDate(ym + "-01")?.formatted(.dateTime.month(.wide).year()) ?? ym
    }
}

// MARK: - Health

/// What the watch sent: today's four numbers, two weeks of steps, the walks. Laid out like Money.
struct HealthScreen: View {
    var body: some View {
        Loaded(path: "health") { (h: DashHealth, reload) in
            HealthList(h: h).refreshable { await reload() }
        }
        .navigationTitle("Health").navigationBarTitleDisplayMode(.inline)
    }
}

private struct HealthList: View {
    let h: DashHealth
    var body: some View {
        let t = h.today
        List {
            Section {
                NavigationLink { SleepScreen(h: h) } label: {
                    LabeledContent("Sleep") { Text(t.sleep.map { hm($0.minutes) } ?? "Not recorded").monospacedDigit() }
                }
                LabeledContent("Body battery") { reading(t.bodyBattery.map { "\($0.now)" }) }
                LabeledContent("Steps") { reading(t.steps.map { t.stepGoal > 0 ? "\($0.formatted()) of \(t.stepGoal.formatted())" : $0.formatted() }) }
                LabeledContent("Resting heart rate") { reading(t.restingHr.map { "\($0) bpm" }) }
            } header: {
                if h.stale { Text(day(h.day)) }   // the numbers belong to that day, not today
            } footer: { SyncedLine(h: h) }

            Section("Steps · 14 days") {
                DayBars(days: h.days, name: "Steps, last 14 days", value: { $0.steps.map(Double.init) },
                        rule: t.stepGoal > 0 ? Double(t.stepGoal) : nil, ruleLabel: "goal",
                        format: { Int($0).formatted() }, tick: { $0 >= 1000 ? "\(($0 / 1000).formatted())k" : Int($0).formatted() })
            }

            if !h.activity.isEmpty {
                Section("Walks") {
                    ForEach(Array(h.activity.enumerated()), id: \.offset) { _, a in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label).lineLimit(1)
                                Text("\(a.date == Date.now.formatted(.iso8601.year().month().day()) ? "Today" : day(a.date)) · \(hm(a.minutes))")
                                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 12)
                            Text("\(a.km.formatted(.number.precision(.fractionLength(1)))) km").monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// A number, or a dash that says "No reading" aloud.
    @ViewBuilder private func reading(_ s: String?) -> some View {
        if let s { Text(s).monospacedDigit() } else { Text("—").accessibilityLabel("No reading") }
    }
}

/// Last night, split into its stages, against the last two weeks.
struct SleepScreen: View {
    let h: DashHealth
    var body: some View {
        let s = h.today.sleep
        let night = h.stale ? day(h.day) : "Last night"
        List {
            Section {
                if let s {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hm(s.minutes)).monospacedDigit().font(size: 40, weight: .semibold, relativeTo: .largeTitle)
                            Text(s.from.flatMap { f in s.to.map { "\(night) · \(f) to \($0)" } } ?? night).monospacedDigit().font(.subheadline).foregroundStyle(.secondary)
                            if let score = s.score {
                                Text("Score \(score)\(s.qualifier.map { ", \($0)" } ?? "")").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        SleepStages(stages: s.stages)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No sleep recorded").font(.title2.weight(.semibold))
                        Text(night).font(.subheadline).foregroundStyle(.secondary)
                        Text("The watch may have been off your wrist.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Hours · 14 nights") {
                DayBars(days: h.days, name: "Hours asleep, last 14 nights", value: \.sleepHours, rule: 8, ruleLabel: "8 h",
                        format: { hm(Int(($0 * 60).rounded())) }, tick: { "\(Int($0)) h" })
            }

            Section {
                if let s {
                    if let n = s.awakeCount { LabeledContent("Woke up", value: n == 0 ? "Not once" : n == 1 ? "Once" : n == 2 ? "Twice" : "\(n) times") }
                    if let r = s.respiration { LabeledContent("Breathing", value: "\(Int(r.rounded())) a minute") }
                    if let o = s.spo2 { LabeledContent("Blood oxygen", value: "\(Int(o.rounded()))% average") }
                } else if let last = h.days.last(where: { $0.sleepHours != nil }) {
                    LabeledContent("Last recorded night", value: day(last.date))
                }
            }
            .monospacedDigit()
        }
        .navigationTitle("Sleep").navigationBarTitleDisplayMode(.inline)
    }
}

/// "Last synced" under today's numbers; when the watch has gone quiet, the waiting mark and what to do.
private struct SyncedLine: View {
    let h: DashHealth
    var body: some View {
        let at = dashDate(h.syncedAt)
        if h.stale {
            VStack(alignment: .leading, spacing: 4) {
                // NeedsMark's dot and ink, as words that can wrap at large sizes (NeedsMark is fixed to one line).
                HStack(spacing: 6) {
                    Circle().fill(Color.otto).frame(width: 7, height: 7)
                    Text(at.map { "Not synced since \(clock($0, weekday: true))" } ?? "Not synced yet")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Color.ottoInk)
                }
                Text("Open Garmin Connect on your phone and the watch catches up.")
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(at.map { "Watch synced \(clock($0))" } ?? "Not synced yet").monospacedDigit()
        }
    }
}

/// One bar a day, today's at full strength: Money's "By month" chart, with a dashed line for the goal.
/// A day without a reading leaves its slot empty, never a zero.
private struct DayBars: View {
    let days: [DashHealth.Day]
    let name: String
    let value: (DashHealth.Day) -> Double?
    /// The dashed line (the step goal, 8 h), or none: a goal of 0 means the server doesn't know it.
    let rule: Double?
    let ruleLabel: String
    let format: (Double) -> String
    let tick: (Double) -> String

    var body: some View {
        let last = days.last?.date
        Chart {
            ForEach(days, id: \.date) { d in
                if let v = value(d) {
                    BarMark(x: .value("Day", d.date), y: .value("Value", v), width: .ratio(0.45))
                        .foregroundStyle(d.date == last ? Color.primary : Color.primary.opacity(0.3))
                        .cornerRadius(5)
                }
            }
            if let rule {
                RuleMark(y: .value(ruleLabel, rule))
                    .foregroundStyle(Color.primary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) { Text(ruleLabel).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .chartXScale(domain: days.map(\.date))   // every day keeps its slot, read or not
        .chartXAxis {
            AxisMarks(values: days.map(\.date)) { v in
                AxisValueLabel { Text(dashDate(v.as(String.self))?.formatted(.dateTime.weekday(.narrow)) ?? "") }
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { Text(v.as(Double.self).map(tick) ?? "") }
            }
        }
        .frame(height: 160)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(days.map { "\(day($0.date)), \(value($0).map(format) ?? "no reading")" }.joined(separator: "; ")
                            + (rule.map { "; \(ruleLabel == "goal" ? "goal \(format($0))" : "line at \(ruleLabel)")" } ?? ""))
    }
}

/// The night as one bar split by stage, with a two-column legend under it.
private struct SleepStages: View {
    let stages: DashHealth.Stages
    var body: some View {
        let parts: [(name: String, minutes: Int, color: Color)] = [
            ("Deep", stages.deep, .sleepDeep), ("Light", stages.light, .sleepLight),
            ("REM", stages.rem, .sleepREM), ("Awake", stages.awake, .sleepAwake)]
        let shown = parts.filter { $0.minutes > 0 }
        let total = CGFloat(shown.reduce(0) { $0 + $1.minutes })
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { g in
                let room = g.size.width - CGFloat(max(shown.count - 1, 0)) * 2   // 2pt gaps between stages
                HStack(spacing: 2) {
                    ForEach(shown, id: \.name) { p in
                        Rectangle().fill(p.color).frame(width: total > 0 ? room * CGFloat(p.minutes) / total : 0)
                    }
                }
            }
            .frame(height: 10)
            .clipShape(.rect(cornerRadius: 3))   // not a capsule: it would swallow a few minutes awake at the end
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stages")
            .accessibilityValue(parts.map { "\($0.name) \(hm($0.minutes))" }.joined(separator: ", "))

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(parts, id: \.name) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Circle().fill(p.color).frame(width: 7, height: 7)
                            Text(p.name).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(hm(p.minutes)).font(.subheadline).monospacedDigit()
                    }
                }
            }
            .accessibilityHidden(true)   // the bar above says the same
        }
    }
}

/// "7 h 42 min", "5 h 02 min", "6 min".
private func hm(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
}

/// "14:52", or "Fri 23:10": the watch's own 24-hour clock, as the server sends sleep times.
private func clock(_ d: Date, weekday: Bool = false) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = weekday ? "EEE HH:mm" : "HH:mm"
    return f.string(from: d)
}

// MARK: - Trips

/// Bookings Otto has on file. Times are where they happen, never converted.
struct TripsScreen: View {
    var body: some View {
        Loaded(path: "trips") { (t: DashTrips, reload) in
            let today = Date.now.formatted(.iso8601.year().month().day())
            let upcoming = t.trips.filter { $0.end >= today }.sorted { $0.start < $1.start }
            let past = t.trips.filter { $0.end < today }.sorted { $0.start > $1.start }
            List {
                if upcoming.isEmpty && !past.isEmpty { Section("Coming up") { Text("No trips planned.").foregroundStyle(.secondary) } }
                ForEach(upcoming) { trip($0, t) }
                if !past.isEmpty {
                    Section {
                        NavigationLink("Past trips · \(past.count)") {
                            List { ForEach(past) { trip($0, t) } }.navigationTitle("Past trips").navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
            }
            .emptyState(t.trips.isEmpty, "No trips", systemImage: "airplane", "Forward a booking confirmation to Otto.")
            .refreshable { await reload() }
        }
        .navigationTitle("Trips").navigationBarTitleDisplayMode(.inline)
    }

    private func trip(_ trip: DashTrips.Trip, _ t: DashTrips) -> some View {
        Section {
            ForEach(Array(trip.segments.enumerated()), id: \.offset) { _, s in
                if s.kind == "flight" {
                    HStack(spacing: 12) {
                        RowIcon(symbol: "airplane")
                        VStack(alignment: .leading, spacing: 2) {
                            Text([s.flight, [s.from, s.to].compactMap { $0 }.joined(separator: " → ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            if let d = s.depart { Text("departs \(wallClock(d.local))").font(.footnote).foregroundStyle(.secondary) }
                            if let a = s.arrive { Text("arrives \(wallClock(a.local))").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        RowIcon(symbol: "bed.double")
                        VStack(alignment: .leading, spacing: 2) {
                            Text([s.name, s.city].compactMap { $0 }.joined(separator: " · "))
                            if let i = s.checkIn, let o = s.checkOut { Text("\(day(i)) → \(day(o))").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(trip.start == trip.end ? day(trip.start) : "\(day(trip.start)) – \(day(trip.end))")
                if t.current?.id == trip.id { Pill(text: t.current?.mode == "current" ? "Now" : "Next") }
            }
        } footer: {
            if let ps = t.problems[trip.id], !ps.isEmpty { Text(ps.joined(separator: "\n")).foregroundStyle(Color.ottoInk) }
        }
    }
}

// MARK: - Packages

/// Orders on their way, read from shipping mail on the Mac, and what arrived lately.
struct PackagesScreen: View {
    var body: some View {
        Loaded(path: "packages") { (p: DashPackages, reload) in PackagesList(p: p, reload: reload) }
            .navigationTitle("Packages").navigationBarTitleDisplayMode(.inline)
    }
}

private let stages = ["ordered", "shipped", "in_transit", "out_for_delivery", "delivered"]

struct PackagesList: View {
    let p: DashPackages
    let reload: () async -> Void
    @Environment(OttoStore.self) private var store
    @Environment(\.openURL) private var openURL
    /// Off once the Mac refuses a write (a read-only token), so the action stops being offered.
    @State private var canWrite = true

    var body: some View {
        let active = p.packages.filter { $0.status != "delivered" }
        let delivered = p.packages.filter { $0.status == "delivered" }
        List {
            ForEach(active) { pkg in
                package(pkg, header: pkg.id == active.first?.id ? "On the way · \(active.count)" : nil)
            }
            ForEach(delivered) { pkg in
                package(pkg, header: pkg.id == delivered.first?.id ? "Delivered" : nil)
            }
        }
        .emptyState(p.packages.isEmpty, "No packages", systemImage: "shippingbox", "Packages show up here as shipping emails arrive.")
        .refreshable { await reload() }
    }

    private func package(_ pkg: DashPackages.Package, header: String?) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(pkg.item ?? pkg.merchant ?? pkg.carrierName).font(.headline).lineLimit(2)
                if pkg.item != nil, let m = pkg.merchant { Text(m).font(.subheadline).foregroundStyle(.secondary) }
                StageBar(status: pkg.status, events: pkg.events)
                HStack {
                    Text(arrival(pkg)).font(.subheadline.weight(.medium))
                        .foregroundStyle(pkg.status == "exception" ? Color.redInk : .primary)
                    Spacer()
                    Text("Updated \(ago(pkg.updatedAt))").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .swipeActions {
                if canWrite && pkg.status != "delivered" {
                    Button("Mark delivered") { Task { await markDelivered(pkg.id) } }.tint(.green)
                }
            }

            Group {
                // Only a row with somewhere to go is a button.
                if let u = pkg.trackingUrl.flatMap(URL.init(string:)) {
                    Button { openURL(u) } label: { carrierRow(pkg, link: true) }.buttonStyle(.plain)
                } else {
                    carrierRow(pkg, link: false)
                }
            }
            .contextMenu {
                if let t = pkg.tracking {
                    Button("Copy Tracking Number", systemImage: "doc.on.doc") { UIPasteboard.general.string = t }
                }
            }

            if !pkg.events.isEmpty {
                DisclosureGroup("Updates · \(pkg.events.count)") {
                    ForEach(pkg.events.sorted { (dashDate($0.at) ?? .distantPast) > (dashDate($1.at) ?? .distantPast) }, id: \.self) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.text).foregroundStyle(e.status == "exception" ? Color.redInk : .primary)
                            Text(dashDate(e.at)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) ?? e.at)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: { if let header { Text(header) } }
    }

    /// "Arrives Tue 20 Oct", "Arrives 16–20 Oct", "Delivered Mon 19 Oct".
    private func carrierRow(_ pkg: DashPackages.Package, link: Bool) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: "shippingbox")
            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.carrierName).foregroundStyle(.primary)
                if let t = pkg.tracking { Text(t).font(.footnote.monospaced()).foregroundStyle(.secondary) }
            }
            Spacer()
            if link { Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary) }
        }
        .contentShape(.rect)
    }

    private func arrival(_ pkg: DashPackages.Package) -> String {
        if pkg.status == "delivered" {
            let d = dashDate(pkg.deliveredAt) ?? dashDate(pkg.updatedAt)
            return "Delivered" + (d.map { " " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? "")
        }
        if pkg.status == "exception" && pkg.eta == nil { return "Delivery problem" }
        guard let eta = pkg.eta else { return pkg.status == "ordered" ? "Not shipped yet" : "No delivery date yet" }
        // Still on the way after its last possible day: say it was due, as Loops does, not that it arrives.
        if (pkg.etaLatest ?? eta).prefix(10) < Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) {
            return "Was due \(day(eta))"
        }
        if let late = pkg.etaLatest, late != eta, let a = dashDate(eta), let b = dashDate(late), a < b {
            return "Arrives " + (a..<b).formatted(.interval.day().month(.abbreviated))
        }
        return "Arrives \(day(eta))"
    }

    private func markDelivered(_ id: String) async {
        let body = try? JSONSerialization.data(withJSONObject: ["id": id])
        if await store.backend.dashData("POST", "packages/done", query: [], body: body) != nil { await reload(); await store.syncArriving() }
        else { canWrite = false }
    }
}

/// Five segments, ordered → delivered, filled up to where the package is. Red while something's wrong.
private struct StageBar: View {
    let status: String
    let events: [DashPackages.Event]

    var body: some View {
        // An exception sits at the last real stage it reached.
        let reached = stages.firstIndex(of: status)
            ?? events.sorted { $0.at > $1.at }.lazy.compactMap { stages.firstIndex(of: $0.status) }.first
            ?? 2
        // On its way is the text colour: blue is for actions, and this bar is not one.
        let tint: Color = status == "exception" ? .red : status == "delivered" ? .green : .primary
        HStack(spacing: 4) {
            ForEach(stages.indices, id: \.self) { i in
                Capsule().fill(i <= reached ? AnyShapeStyle(tint) : AnyShapeStyle(Color(.tertiarySystemFill))).frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(status.replacingOccurrences(of: "_", with: " "))
    }
}

#Preview("Packages · sample data") {
    // Sample data for the canvas only.
    let json = """
    {"packages":[
     {"id":"a","carrier":"ups","carrierName":"UPS","tracking":"1Z999AA10123456784","trackingUrl":"https://example.com/track",
      "merchant":"Example Store","item":"Desk lamp","status":"in_transit","eta":"2026-10-16","etaLatest":"2026-10-20",
      "updatedAt":"2026-10-14T09:00:00Z","events":[
       {"at":"2026-10-13T08:00:00Z","status":"shipped","text":"Shipped"},
       {"at":"2026-10-14T09:00:00Z","status":"in_transit","text":"Departed facility"}]},
     {"id":"b","carrier":"dhl","carrierName":"DHL","tracking":"JD0000000000","merchant":"Sample Shop","status":"exception",
      "eta":"2026-10-15","updatedAt":"2026-10-14T07:00:00Z","events":[
       {"at":"2026-10-14T07:00:00Z","status":"exception","text":"Address issue"}]},
     {"id":"c","carrier":"usps","carrierName":"USPS","merchant":"Sample Shop","item":"Headphones","status":"delivered",
      "updatedAt":"2026-10-12T15:00:00Z","deliveredAt":"2026-10-12T15:00:00Z","events":[]}
    ]}
    """
    let p = try! JSONDecoder().decode(DashPackages.self, from: Data(json.utf8))
    return NavigationStack { PackagesList(p: p, reload: {}).navigationTitle("Packages") }
        .environment(OttoStore(backend: MockBackend()))
}
