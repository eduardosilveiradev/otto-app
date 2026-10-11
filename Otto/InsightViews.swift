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
            Section {
                if l.open.isEmpty { Text("Nothing open.").foregroundStyle(.secondary) }
                ForEach(l.open) { row($0, closed: flipped.contains($0.id)) }
            } header: { Text("Open · \(l.open.count)") }

            let p = l.plan
            if !p.close.isEmpty || !p.propose.isEmpty || !p.avoidance.isEmpty {
                Section {
                    ForEach(p.close, id: \.id) { c in
                        plan("checkmark.circle", text[c.id] ?? c.id, "closes it: \(c.reason)")
                    }
                    ForEach(p.propose, id: \.id) { c in plan("questionmark.circle", c.text, "asks you: \(c.reason)") }
                    ForEach(p.avoidance, id: \.id) { c in plan("arrow.uturn.right.circle", c.text, "pushed back \(c.deferrals) times") }
                } header: { Text("Tonight's hygiene pass") } footer: {
                    Text("Runs at 05:00. It only closes what the evidence closes; the rest it asks about.")
                }
            }

            if !l.recent.isEmpty {
                Section("Closed lately") {
                    ForEach(l.recent) { row($0, closed: !flipped.contains($0.id)) }
                }
            }
        }
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
                RowIcon(symbol: closed ? "checkmark" : r.text.contains("€") ? "eurosign" : "arrow.turn.up.left")
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.text).lineLimit(3).strikethrough(closed).foregroundStyle(closed ? .secondary : .primary)
                    let m = meta(r)
                    if !m.isEmpty { Text(m).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .swipeActions {
            Button(closed ? "Reopen" : "Done") { flip(r.id, done: !closed) }.tint(closed ? .orange : .green)
        }
    }

    private func meta(_ r: LoopRow) -> String {
        var bits: [String] = []
        if let due = r.due { bits.append("due \(day(due))") }
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

/// Spend from receipts and bank mail, by month and category. Never converted between currencies.
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

    var body: some View {
        // byCategory is in the requested currency, else the most used one.
        let cur = currency ?? m.byCurrency.first?.currency ?? "EUR"
        let top = m.byCategory.map(\.total).max() ?? 0
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(money(m.byCurrency.first { $0.currency == cur }?.total ?? 0, cur))
                        .font(.system(size: 40, weight: .semibold).monospacedDigit())
                    Text("\(month.map(monthName) ?? "All time")\(category.map { " · \($0)" } ?? "")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    let others = m.byCurrency.filter { $0.currency != cur }
                    if !others.isEmpty {
                        Text("plus " + others.map { money($0.total, $0.currency) }.joined(separator: ", "))
                            .font(.footnote).foregroundStyle(.secondary)
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
                        BarMark(x: .value("Month", String(monthName(mo).prefix(3))), y: .value("Spent", total))
                            .foregroundStyle(mo == month ? Color.orange : Color.orange.opacity(0.45))
                    }
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
                                    Text(c.category.capitalized)
                                    if category == c.category { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.orange) }
                                    Spacer()
                                    Text(money(c.total, cur)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                GeometryReader { g in
                                    Capsule().fill(Color.orange.opacity(category == nil || category == c.category ? 0.8 : 0.25))
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
    }

    private func monthName(_ ym: String) -> String {
        dashDate(ym + "-01")?.formatted(.dateTime.month(.wide).year()) ?? ym
    }
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
                if upcoming.isEmpty { Text(t.trips.isEmpty ? "No bookings on file. Forward a confirmation to Otto." : "Nothing coming up.").foregroundStyle(.secondary) }
                ForEach(upcoming) { trip($0, t) }
                if !past.isEmpty {
                    Section {
                        NavigationLink("Past trips · \(past.count)") {
                            List { ForEach(past) { trip($0, t) } }.navigationTitle("Past trips").navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
            }
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
                if t.current?.id == trip.id { Pill(text: t.current?.mode == "current" ? "Now" : "Next", tint: .orange) }
            }
        } footer: {
            if let ps = t.problems[trip.id], !ps.isEmpty { Text(ps.joined(separator: "\n")).foregroundStyle(.orange) }
        }
    }
}
