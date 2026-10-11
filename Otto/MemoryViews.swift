import SwiftUI

/// What Otto remembers: the summary, every memory and note, search, and who's who.
struct MemoryScreen: View {
    var body: some View {
        Loaded(path: "memory") { (m: DashMemory, reload) in MemoryList(m: m, reload: reload) }
            .navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
    }
}

private struct MemoryList: View {
    let m: DashMemory
    let reload: () async -> Void
    @Environment(OttoStore.self) private var store
    @State private var query = ""
    /// Indexes the Mac ranked for `query`, best first; nil while just filtering by text.
    @State private var ranked: [Int]?
    @State private var source = "all"
    @State private var cluster: Int?
    @State private var needsLook = false
    @State private var note: String?

    private var shown: [MemoryItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (ranked ?? m.items.indices.sorted { m.items[$0].updated > m.items[$1].updated }).filter { i in
            let it = m.items[i]
            return (source == "all" || it.store == source)
                && (cluster == nil || m.graph.c?[safe: i] == cluster)
                && (!needsLook || it.badge != nil)
                && (ranked != nil || q.isEmpty || it.name.localizedCaseInsensitiveContains(q) || it.description.localizedCaseInsensitiveContains(q))
        }.map { m.items[$0] }
    }

    var body: some View {
        let items = shown
        List {
            if query.isEmpty && cluster == nil && !needsLook && source == "all" {
                Section {
                    NavigationLink {
                        ScrollView { MarkdownText(text: m.summary.text).padding() }
                            .navigationTitle("Summary").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("What Otto knows about you", systemImage: "text.alignleft")
                    }
                } footer: { Text(m.summary.note) }
            }
            if let note { Section { Text(note).foregroundStyle(.secondary) } }
            Section {
                ForEach(items) { it in
                    NavigationLink { MemoryDetailScreen(item: it) } label: { MemoryRow(item: it) }
                }
            } header: {
                Text(ranked != nil ? "Best matches · \(items.count)" : "\(items.count) of \(m.items.count)")
            } footer: {
                Text("Indexed \(ago(m.generatedAt))")
            }
        }
        .searchable(text: $query, prompt: "Search memory")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { if query.isEmpty { ranked = nil } }
        .refreshable { await reload() }
        .toolbar {
            Menu {
                Picker("Show", selection: $source) {
                    Text("Everything").tag("all")
                    Text("Memories").tag("durable")
                    Text("Notes").tag("notes")
                }
                Toggle("Never recalled or stale", isOn: $needsLook)
                if let cs = m.graph.clusters, !cs.isEmpty {
                    Picker("Topic", selection: $cluster) {
                        Text("All topics").tag(Int?.none)
                        ForEach(cs.sorted { $0.size > $1.size }) { c in Text("\(c.label) · \(c.size)").tag(Int?.some(c.id)) }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                Button("Rebuild the index", systemImage: "arrow.clockwise") { Task { await rebuild() } }
            } label: {
                Image(systemName: source != "all" || cluster != nil || needsLook ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
        }
    }

    private func search() async {
        struct Hits: Decodable { let results: [[Double]] }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { ranked = nil; return }
        if let r: Hits = await store.backend.dash("memory/search", query: ["q": q]) {
            ranked = r.results.compactMap { $0.first.map(Int.init) }.filter { m.items.indices.contains($0) }
        }
    }

    private func rebuild() async {
        struct Started: Decodable { let started: Bool }
        let r: Started? = await store.backend.dash("memory/rebuild", method: "POST")
        note = r == nil ? "Already rebuilding, or the Mac didn't take it." : "Rebuilding. Pull to refresh in a minute."
    }
}

struct MemoryRow: View {
    let item: MemoryItem
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.description).lineLimit(2)
                Spacer(minLength: 8)
                if item.badge == "never" { Pill(text: "never recalled", tint: .orange) }
                else if item.badge == "stale" { Pill(text: "stale", tint: .orange) }
            }
            Text([item.kind, item.scope, item.status, item.due.map { "due \(day($0))" }, ago(item.updated)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct MemoryDetailScreen: View {
    let item: MemoryItem
    var body: some View {
        Loaded(path: "memory/item", query: ["id": item.id]) { (d: MemoryDetail, _) in
            List {
                Section {
                    LabeledContent("Kind", value: item.kind)
                    LabeledContent("Scope", value: item.scope)
                    LabeledContent("Updated", value: ago(item.updated))
                    LabeledContent("Recalled", value: item.hits == 1 ? "once" : "\(item.hits) times")
                    if let s = item.status { LabeledContent("Status", value: s) }
                    if let due = item.due { LabeledContent("Due", value: day(due)) }
                    if let r = item.closedReason { LabeledContent("Closed because", value: r) }
                    if let tags = item.tags, !tags.isEmpty { LabeledContent("Tags", value: tags.joined(separator: ", ")) }
                }
                Section { MarkdownText(text: d.body).textSelection(.enabled) }
            }
        }
        .navigationTitle(item.kind.capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - People

struct PeopleScreen: View {
    @State private var query = ""
    var body: some View {
        let q = query   // by value, or typing wouldn't redraw the list
        Loaded(path: "people") { (p: People, reload) in
            let cards = p.cards.filter { q.isEmpty || [$0.name, $0.relationship, $0.city, $0.org].compactMap { $0 }.joined(separator: " ").localizedCaseInsensitiveContains(q) }
            List {
                if p.cards.isEmpty { Text("Nobody yet. Tell Otto who someone is and they show up here.").foregroundStyle(.secondary) }
                ForEach(cards) { c in
                    NavigationLink { PersonScreen(card: c) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                let sub = [c.relationship, c.city].compactMap { $0 }.joined(separator: " · ")
                                if !sub.isEmpty { Text(sub).font(.footnote).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let tz = c.timezone.flatMap(TimeZone.init(identifier:)), tz.secondsFromGMT() != TimeZone.current.secondsFromGMT() {
                                Text(localTime(tz)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search people")
            .refreshable { await reload() }
        }
        .navigationTitle("People").navigationBarTitleDisplayMode(.inline)
    }
}

struct People: Decodable { let cards: [PersonCard] }

func localTime(_ tz: TimeZone, _ date: Date = .now) -> String {
    var f = Date.FormatStyle(date: .omitted, time: .shortened); f.timeZone = tz
    return date.formatted(f)
}

private struct PersonScreen: View {
    let card: PersonCard
    @Environment(OttoStore.self) private var store
    @State private var mentions: [MemoryItem] = []

    var body: some View {
        List {
            Section {
                if let r = card.relationship { LabeledContent("Relationship", value: r) }
                if let city = card.city { LabeledContent("City", value: city) }
                if let tz = card.timezone.flatMap(TimeZone.init(identifier:)) {
                    TimelineView(.everyMinute) { tl in
                        LabeledContent("Their time", value: "\(localTime(tz, tl.date)) · \(tz.identifier.split(separator: "/").last.map { $0.replacing("_", with: " ") } ?? "")")
                    }
                }
                if let org = card.org { LabeledContent("Works at", value: org) }
                LabeledContent("Messages", value: "\(card.inbound) in · \(card.outbound) out")
                if let last = card.lastContact { LabeledContent("Last contact", value: ago(last)) }
            }
            if !card.notes.isEmpty {
                Section("In your words") {
                    ForEach(card.notes.reversed(), id: \.self) { n in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(n.text)
                            Text(day(n.at)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !mentions.isEmpty {
                Section("In memory") {
                    ForEach(mentions) { it in NavigationLink { MemoryDetailScreen(item: it) } label: { MemoryRow(item: it) } }
                }
            }
        }
        .navigationTitle(card.name).navigationBarTitleDisplayMode(.inline)
        .task {
            guard !card.mentions.isEmpty, let m: DashMemory = await store.backend.dash("memory") else { return }
            mentions = card.mentions.compactMap { m.items[safe: $0] }
        }
    }
}

// MARK: - Markdown

/// Memory bodies and the summary: headings, bullets and inline markdown, one block per line.
struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    inline(String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                        .font(.headline).padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                    .padding(.leading, raw.prefix { $0 == " " }.count >= 2 ? 16 : 0)
                } else if line == "---" {
                    Divider()
                } else if !line.isEmpty {
                    inline(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
