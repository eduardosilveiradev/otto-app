import SwiftUI
import Charts

// A card Otto attaches to a message ("card" on the message frame and /app/history rows):
// a few blocks of plain data, drawn natively under the bubble. Decoding never throws, so a
// card from a newer server (a block type this build doesn't know, a field it can't read)
// loses that block, never the message.

struct Card: Codable {
    var title: String?
    var blocks: [Block]
    var actions: [ActionButton]?

    init(title: String? = nil, blocks: [Block], actions: [ActionButton]? = nil) {
        self.title = title; self.blocks = blocks; self.actions = actions
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        title = try? c?.decodeIfPresent(String.self, forKey: .title)
        blocks = (try? c?.decodeIfPresent([Block].self, forKey: .blocks)) ?? []
        actions = try? c?.decodeIfPresent([ActionButton].self, forKey: .actions)
    }
    /// What's drawn: the schema's limits, and nothing a newer server sent that this build can't show.
    var shown: [Block] { Array(blocks.filter { if case .unknown = $0 { false } else { true } }.prefix(12)) }
}

enum Block: Codable {
    struct Stat: Codable { var value: String; var label: String?; var delta: String?; var tone: String? }
    struct ListItem: Codable { var title: String; var detail: String?; var trailing: String?; var icon: String? }
    struct Table: Codable { var columns: [String]; var rows: [[String]] }
    struct Bar: Codable { var label: String; var value: Double }
    struct Bars: Codable { var items: [Bar]; var unit: String? }
    struct Sparkline: Codable { var values: [Double]; var label: String? }
    struct Progress: Codable { var value: Double; var label: String; var detail: String? }
    struct Moment: Codable { var time: String; var title: String; var detail: String?; var done: Bool? }
    struct Pair: Codable { var key: String; var value: String }
    struct Check: Codable { var text: String; var done: Bool }
    struct Picture: Codable { var file: String?; var url: String?; var alt: String }
    struct Words: Codable { var text: String; var style: String? }
    struct Items<T: Codable>: Codable { var items: [T] }

    case stat(Stat), list([ListItem]), table(Table), bars(Bars), sparkline(Sparkline), progress(Progress)
    case timeline([Moment]), keyvalue([Pair]), checklist([Check]), image(Picture), text(Words)
    case unknown

    private enum Key: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        do {
            let t = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .type)
            switch t {
            case "stat": self = .stat(try Stat(from: decoder))
            case "list": self = .list(try Items<ListItem>(from: decoder).items)
            case "table": self = .table(try Table(from: decoder))
            case "bars": self = .bars(try Bars(from: decoder))
            case "sparkline": self = .sparkline(try Sparkline(from: decoder))
            case "progress": self = .progress(try Progress(from: decoder))
            case "timeline": self = .timeline(try Items<Moment>(from: decoder).items)
            case "keyvalue": self = .keyvalue(try Items<Pair>(from: decoder).items)
            case "checklist": self = .checklist(try Items<Check>(from: decoder).items)
            case "image": self = .image(try Picture(from: decoder))
            case "text": self = .text(try Words(from: decoder))
            default: self = .unknown
            }
        } catch { self = .unknown }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .stat(let v): try c.encode("stat", forKey: .type); try v.encode(to: encoder)
        case .list(let v): try c.encode("list", forKey: .type); try Items(items: v).encode(to: encoder)
        case .table(let v): try c.encode("table", forKey: .type); try v.encode(to: encoder)
        case .bars(let v): try c.encode("bars", forKey: .type); try v.encode(to: encoder)
        case .sparkline(let v): try c.encode("sparkline", forKey: .type); try v.encode(to: encoder)
        case .progress(let v): try c.encode("progress", forKey: .type); try v.encode(to: encoder)
        case .timeline(let v): try c.encode("timeline", forKey: .type); try Items(items: v).encode(to: encoder)
        case .keyvalue(let v): try c.encode("keyvalue", forKey: .type); try Items(items: v).encode(to: encoder)
        case .checklist(let v): try c.encode("checklist", forKey: .type); try Items(items: v).encode(to: encoder)
        case .image(let v): try c.encode("image", forKey: .type); try v.encode(to: encoder)
        case .text(let v): try c.encode("text", forKey: .type); try v.encode(to: encoder)
        case .unknown: try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Views

/// Under Otto's bubble, as wide as the widest bubble, in the bubble's grey (Messages' rich previews).
struct CardView: View {
    let card: Card
    /// What a tapped action does: the row's own button handling, so it matches the message's buttons.
    let press: (ActionButton) -> Void

    var body: some View {
        let actions = Array((card.actions ?? []).prefix(4))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let t = card.title, !t.isEmpty {
                    Text(t).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(card.shown.enumerated()), id: \.offset) { _, b in BlockView(block: b) }
            }
            .padding(14)
            if !actions.isEmpty {
                Divider()
                // Plain blue text, like Otto's buttons under a bubble.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { buttons(actions) }
                    VStack(alignment: .leading, spacing: 0) { buttons(actions) }
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.incomingBubble, in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func buttons(_ a: [ActionButton]) -> some View {
        ForEach(a) { b in
            Button(b.label) { press(b) }
                .font(.subheadline).tint(.blue)
                .frame(minHeight: 44)
        }
    }
}

private struct BlockView: View {
    let block: Block

    var body: some View {
        switch block {
        case .stat(let s): StatBlock(stat: s)
        case .list(let items): ListBlock(items: items)
        case .table(let t): TableBlock(table: t)
        case .bars(let b): BarsBlock(bars: b)
        case .sparkline(let s): SparkBlock(spark: s)
        case .progress(let p): ProgressBlock(progress: p)
        case .timeline(let m): TimelineBlock(items: m)
        case .keyvalue(let p): KeyValueBlock(items: p)
        case .checklist(let c): ChecklistBlock(items: c)
        case .image(let p): ImageBlock(picture: p)
        case .text(let w):
            Text(w.text)
                .font(w.style == "caption" ? .footnote : .body)
                .foregroundStyle(w.style == "caption" ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown: EmptyView()
        }
    }
}

/// "12.5" with its unit: a currency sign before, anything else after.
private func amount(_ v: Double, _ unit: String?) -> String {
    guard let u = unit, !u.isEmpty else { return v.formatted(.number.precision(.fractionLength(0...2))) }
    // Money shows its cents or none: €72.40, €31.
    if u.count == 1 && !u.first!.isLetter { return u + v.formatted(.number.precision(.fractionLength(v == v.rounded() ? 0 : 2))) }
    return "\(v.formatted(.number.precision(.fractionLength(0...2)))) \(u)"
}

/// Side by side while it fits, stacked at accessibility sizes.
private struct Row<Lead: View, Trail: View>: View {
    @Environment(\.dynamicTypeSize) private var size
    @ViewBuilder let lead: Lead
    @ViewBuilder let trail: Trail
    var body: some View {
        if size.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) { lead; trail }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) { lead; Spacer(minLength: 0); trail.multilineTextAlignment(.trailing) }
        }
    }
}

private struct StatBlock: View {
    let stat: Block.Stat
    /// The server says which way it moved, not whether that's good (spending up isn't), so the
    /// arrow carries it and the colour stays neutral.
    private var arrow: String? {
        switch stat.tone { case "up": "arrow.up.right"; case "down": "arrow.down.right"; default: nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(stat.value).font(.largeTitle.weight(.semibold)).monospacedDigit()
                .lineLimit(2).minimumScaleFactor(0.6)
            if stat.label != nil || stat.delta != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let l = stat.label { Text(l).foregroundStyle(.secondary) }
                    if let d = stat.delta {
                        Label { Text(d).monospacedDigit() } icon: { if let arrow { Image(systemName: arrow) } }
                            .labelStyle(.titleAndIcon).font(.subheadline.weight(.medium))
                    }
                }
                .font(.subheadline)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([stat.label, stat.value].compactMap { $0 }.joined(separator: ": "))
        .accessibilityValue(stat.delta.map { d in "\(stat.tone == "up" ? "up " : stat.tone == "down" ? "down " : "")\(d)" } ?? "")
    }
}

private struct ListBlock: View {
    let items: [Block.ListItem]
    @ScaledMetric private var dot: CGFloat = 30
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, i in
                HStack(spacing: 10) {
                    if let icon = i.icon {
                        Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.blue)
                            .frame(width: dot, height: dot).background(Color.blue.opacity(0.12), in: .circle)
                            .accessibilityHidden(true)
                    }
                    Row {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.title)
                            if let d = i.detail { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    } trail: {
                        if let t = i.trailing { Text(t).monospacedDigit().foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct TableBlock: View {
    let table: Block.Table
    @Environment(\.dynamicTypeSize) private var size
    private var cols: [String] { Array(table.columns.prefix(4)) }
    private func cell(_ r: [String], _ c: Int) -> String { c < r.count ? r[c] : "" }
    var body: some View {
        if size.isAccessibilitySize { stacked } else { grid }
    }
    /// At accessibility sizes four columns break words mid-letter: each row becomes its own small group.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { n, r in
                if n > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text(cell(r, 0)).font(.subheadline.weight(.semibold))
                    ForEach(cols.indices.dropFirst(), id: \.self) { c in
                        Row { Text(cols[c]).foregroundStyle(.secondary) } trail: { Text(cell(r, c)) }.font(.subheadline)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(cols.indices.map { c in "\(cols[c]): \(cell(r, c))" }.joined(separator: ", "))
            }
        }
    }
    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                ForEach(cols.indices, id: \.self) { c in
                    Text(cols[c]).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .gridColumnAlignment(c == 0 ? .leading : .trailing)
                }
            }
            .accessibilityAddTraits(.isHeader)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    ForEach(cols.indices, id: \.self) { c in
                        Text(cell(r, c))
                            .font(c == 0 ? .subheadline : .subheadline.monospacedDigit())
                            .multilineTextAlignment(c == 0 ? .leading : .trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(cols.indices.map { c in "\(cols[c]): \(cell(r, c))" }.joined(separator: ", "))
            }
        }
    }
}

private struct BarsBlock: View {
    let bars: Block.Bars
    @ScaledMetric private var row: CGFloat = 30
    var body: some View {
        Chart(Array(bars.items.enumerated()), id: \.offset) { _, b in
            BarMark(x: .value("Value", b.value), y: .value("Label", b.label), height: .ratio(0.6))
                .foregroundStyle(Color.blue)
                .cornerRadius(4)
                .annotation(position: .trailing, spacing: 6) {
                    Text(amount(b.value, bars.unit)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel().font(.footnote) } }
        // Room on the right for the longest bar's figure.
        .chartXScale(domain: 0...((bars.items.map(\.value).max() ?? 1) * 1.25))
        .frame(height: row * CGFloat(max(bars.items.count, 1)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bar chart")
        .accessibilityValue(bars.items.map { "\($0.label), \(amount($0.value, bars.unit))" }.joined(separator: "; "))
    }
}

private struct SparkBlock: View {
    let spark: Block.Sparkline
    @ScaledMetric private var height: CGFloat = 44
    var body: some View {
        let v = spark.values
        let lo = v.min() ?? 0, hi = v.max() ?? 1, pad = max((hi - lo) * 0.15, 0.5)
        VStack(alignment: .leading, spacing: 6) {
            if let l = spark.label {
                Row { Text(l).font(.subheadline).foregroundStyle(.secondary) } trail: {
                    if let last = v.last { Text(amount(last, nil)).font(.subheadline.weight(.semibold)).monospacedDigit() }
                }
            }
            Chart(Array(v.enumerated()), id: \.offset) { i, y in
                LineMark(x: .value("Index", i), y: .value("Value", y))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.blue)
                if i == v.count - 1 {
                    PointMark(x: .value("Index", i), y: .value("Value", y)).symbolSize(30).foregroundStyle(Color.blue)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .frame(height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spark.label ?? "Trend")
        .accessibilityValue(v.isEmpty ? "" : "from \(amount(v.first!, nil)) to \(amount(v.last!, nil)), low \(amount(lo, nil)), high \(amount(hi, nil))")
    }
}

private struct ProgressBlock: View {
    let progress: Block.Progress
    var body: some View {
        let p = min(max(progress.value, 0), 1)
        VStack(alignment: .leading, spacing: 6) {
            Row { Text(progress.label).font(.subheadline) } trail: {
                Text(p.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: p).tint(.blue)
            if let d = progress.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress.label)
        .accessibilityValue([p.formatted(.percent.precision(.fractionLength(0))), progress.detail].compactMap { $0 }.joined(separator: ", "))
    }
}

private struct TimelineBlock: View {
    let items: [Block.Moment]
    @ScaledMetric private var timeWidth: CGFloat = 48
    @ScaledMetric private var dotTop: CGFloat = 6
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { n, m in
                let done = m.done == true
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(m.time).font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: timeWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).font(.subheadline).foregroundStyle(done ? .secondary : .primary)
                        if let d = m.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding(.leading, 18)
                    .padding(.bottom, n == items.count - 1 ? 0 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The dot, and the rule down to the next one.
                    .background(alignment: .topLeading) {
                        ZStack(alignment: .top) {
                            if n < items.count - 1 {
                                Rectangle().fill(.quaternary).frame(width: 1.5).padding(.top, dotTop + 9)
                            }
                            Circle().strokeBorder(done ? Color.secondary : Color.blue, lineWidth: 1.5)
                                .background(Circle().fill(done ? Color.secondary : .clear))
                                .frame(width: 9, height: 9).padding(.top, dotTop)
                        }
                        .frame(width: 9)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(m.time), \(m.title)\(m.detail.map { ", \($0)" } ?? "")")
                .accessibilityValue(done ? "Done" : "")
            }
        }
    }
}

private struct KeyValueBlock: View {
    let items: [Block.Pair]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { n, p in
                if n > 0 { Divider() }
                Row { Text(p.key).foregroundStyle(.secondary) } trail: { Text(p.value) }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ChecklistBlock: View {
    let items: [Block.Check]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, c in
                Label {
                    Text(c.text).strikethrough(c.done).foregroundStyle(c.done ? .secondary : .primary)
                } icon: {
                    Image(systemName: c.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(c.done ? Color.blue : Color.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(c.text)
                .accessibilityValue(c.done ? "Done" : "Not done")
            }
        }
    }
}

private struct ImageBlock: View {
    let picture: Block.Picture
    @Environment(OttoStore.self) private var store
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        // The frame comes from the card; a filling photo must never widen it (it would push the whole row off screen).
        Rectangle().fill(Color(.systemBackground).opacity(0.5))
            .frame(maxWidth: .infinity).frame(height: 180)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else if missing { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
                else { ProgressView() }
            }
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(picture.alt)
        .accessibilityAddTraits(.isImage)
        .task(id: picture.file ?? picture.url) { await load() }
    }

    private func load() async {
        var data: Data?
        if let id = picture.file {
            data = await MediaCache.load(RemoteFile(id: id, name: "card", kind: "image"), from: store.backend)
        } else if let s = picture.url, let u = URL(string: s), u.scheme == "https" {
            data = try? await URLSession.shared.data(from: u).0
        }
        if let data, let img = UIImage(data: data) { image = img } else { missing = true }
    }
}

#if DEBUG
extension Card {
    /// `-cardThread [types]`: one message per block type and a mixed one, invented data only.
    /// `types` is a comma list (`stat,list,mixed`) to show a few at a time for screenshots.
    @MainActor static func demoThread(_ only: String?) -> [Message] {
        // A photo for the image block, put where the file fetch finds it, so no server is needed.
        MediaCache.data["demo-card-photo"] = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 450)).jpegData(withCompressionQuality: 0.8) { ctx in
            UIColor.systemTeal.withAlphaComponent(0.55).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 450))
            UIColor.systemOrange.withAlphaComponent(0.7).setFill(); ctx.fill(CGRect(x: 0, y: 300, width: 800, height: 150))
            UIColor.white.setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 560, y: 70, width: 110, height: 110))
        }
        let all: [(String, String, String, Card)] = [
            ("mixed", "how much did i spend this week", "€184.60 so far, a bit more than last week. groceries are most of it.",
             Card(title: "Spending this week", blocks: [
                .stat(.init(value: "€184.60", label: "Mon–Sun", delta: "12% vs last week", tone: "up")),
                .bars(.init(items: [.init(label: "Groceries", value: 72.4), .init(label: "Eating out", value: 48.2),
                                    .init(label: "Transport", value: 31), .init(label: "Other", value: 33)], unit: "€")),
                .list([.init(title: "Northside Grocer", detail: "Groceries · Thu", trailing: "€41.20", icon: "cart"),
                       .init(title: "Linden Café", detail: "Eating out · Wed", trailing: "€18.50", icon: "cup.and.saucer"),
                       .init(title: "City Rail", detail: "Transport · Mon", trailing: "€31.00", icon: "tram")]),
                .progress(.init(value: 0.74, label: "Weekly budget", detail: "€65.40 left of €250")),
             ], actions: [ActionButton(label: "Show all", data: "show all spending this week"),
                          ActionButton(label: "Set a budget", data: "set a weekly budget")])),
            ("stat", "how many steps today", "a good day for walking.",
             Card(blocks: [.stat(.init(value: "9,412", label: "Steps today", delta: "1,280", tone: "down"))])),
            ("list", "what's on my list for the hardware store", "four things.",
             Card(title: "Hardware store", blocks: [.list([
                .init(title: "Wall anchors", detail: "8 mm, pack of 20", trailing: "€4.90", icon: "wrench.and.screwdriver"),
                .init(title: "Lightbulbs", detail: "E27, warm white", trailing: "×3", icon: "lightbulb"),
                .init(title: "Painter's tape", trailing: "€3.20", icon: "paintbrush"),
                .init(title: "Door stop", detail: "the grey one, not the brass", icon: "door.left.hand.open")])])),
            ("table", "compare the three flats", "side by side:",
             Card(title: "Flats", blocks: [.table(.init(columns: ["Flat", "Rent", "Size", "Walk"],
                rows: [["Elm Street", "€980", "54 m²", "12 min"], ["Harbour Road", "€1,120", "61 m²", "6 min"], ["Mill Lane", "€890", "48 m²", "21 min"]]))])),
            ("bars", "which day did i sleep least", "wednesday, by a lot.",
             Card(title: "Sleep", blocks: [.bars(.init(items: [.init(label: "Mon", value: 7.2), .init(label: "Tue", value: 6.8), .init(label: "Wed", value: 4.9),
                                                             .init(label: "Thu", value: 7.5), .init(label: "Fri", value: 6.1)], unit: "h"))])),
            ("sparkline", "how's the electricity use looking", "trending down since the new fridge.",
             Card(blocks: [.sparkline(.init(values: [14.2, 13.8, 15.1, 12.9, 12.4, 11.8, 12.1, 11.2, 10.9, 10.4], label: "kWh per day, last 10 days"))])),
            ("progress", "how far along is the photo backup", "almost there.",
             Card(blocks: [.progress(.init(value: 0.82, label: "Photo backup", detail: "4,120 of 5,030 photos"))])),
            ("timeline", "what's tomorrow look like", "a light one.",
             Card(title: "Tomorrow", blocks: [.timeline([
                .init(time: "08:30", title: "Gym", detail: "Leg day", done: true),
                .init(time: "10:00", title: "Design review", detail: "Room 4 · 45 min", done: true),
                .init(time: "13:00", title: "Lunch with Sam"),
                .init(time: "17:30", title: "Pick up the parcel", detail: "Post office on Birch Ave")])])),
            ("keyvalue", "what's the wifi at the cabin", "here it is.",
             Card(title: "Cabin", blocks: [.keyvalue([.init(key: "Network", value: "Pinewood-5G"), .init(key: "Password", value: "mossy-trail-42"),
                                                     .init(key: "Check-in", value: "after 15:00"), .init(key: "Host", value: "Riley")])],
                  actions: [ActionButton(label: "Copy password", data: nil, copy: "mossy-trail-42")])),
            ("checklist", "packing list for the weekend", "two left.",
             Card(title: "Weekend packing", blocks: [.checklist([.init(text: "Charger", done: true), .init(text: "Rain jacket", done: true),
                                                                .init(text: "Hiking boots", done: false), .init(text: "Snacks for the drive", done: false)])])),
            ("image", "what did the bike shop send", "the quote came with a photo of the wheel.",
             Card(blocks: [.image(.init(file: "demo-card-photo", url: nil, alt: "The rear wheel on a work stand")),
                           .text(.init(text: "Replacing the rim and spokes: €96, ready Friday.", style: nil)),
                           .text(.init(text: "Quote valid for 14 days.", style: "caption"))],
                  actions: [ActionButton(label: "Accept", data: "accept the bike shop quote"),
                            ActionButton(label: "Website", data: nil, url: "https://example.com")])),
            ("text", "anything i should know about the move", "one thing.",
             Card(blocks: [.text(.init(text: "The movers need the lift booked for Saturday morning. The building office closes at noon on Friday.", style: nil)),
                           .text(.init(text: "From the email on Tuesday.", style: "caption"))])),
        ]
        let keep = only.map { Set($0.split(separator: ",").map(String.init)) }
        let t = Date.now.addingTimeInterval(-600)
        return all.filter { keep?.contains($0.0) ?? true }.flatMap { _, ask, answer, card in
            [Message(from: .me, text: ask, date: t, read: true), Message(from: .otto, text: answer, date: t, card: card)]
        }
    }
}
#endif
