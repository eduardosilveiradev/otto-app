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
    /// Indexes the Mac ranked for a query, best first, the snapshot they index into and the query itself; nil
    /// while just filtering by text. A refresh brings a new snapshot, and old indexes would point anywhere;
    /// an edited query isn't the one ranked, so it filters by text again until it's submitted.
    @State private var rankedIn: (snapshot: String, query: String, order: [Int])?
    private var typed: String { query.trimmingCharacters(in: .whitespaces) }
    private var ranked: [Int]? {
        rankedIn.flatMap { $0.snapshot == m.generatedAt && $0.query == typed ? $0.order.filter(m.items.indices.contains) : nil }
    }
    @State private var source = "all"
    @State private var cluster: Int?
    @State private var needsLook = false
    @State private var note: String?
    /// The Mac's search is running, or didn't answer: said above the list, which shows text matches meanwhile.
    @State private var searching = false
    @State private var searchFailed = false

    private var shown: [MemoryItem] {
        let q = typed
        return (ranked ?? m.items.indices.sorted { m.items[$0].updated > m.items[$1].updated }).filter { i in
            let it = m.items[i]
            return !store.forgotten.contains(it.id)   // gone on the Mac; the index catches up at its next rebuild
                && (source == "all" || it.store == source)
                && (cluster == nil || m.graph.c?[safe: i] == cluster)
                && (!needsLook || it.badge != nil)
                && (ranked != nil || q.isEmpty || it.name.localizedCaseInsensitiveContains(q) || it.description.localizedCaseInsensitiveContains(q))
        }.map { m.items[$0] }
    }

    var body: some View {
        let items = shown
        List {
            // Not on an empty page: the summary would open on nothing.
            if query.isEmpty && cluster == nil && !needsLook && source == "all" && !m.items.isEmpty && !m.summary.text.isEmpty {
                Section {
                    NavigationLink {
                        ScrollView { MarkdownText(text: m.summary.text).padding() }
                            .navigationTitle("Summary").navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label { Text("What Otto knows about you") } icon: { RowIcon(symbol: "text.alignleft") }
                    }
                } footer: { Text(m.summary.note) }
            }
            if let note { Section { Text(note).foregroundStyle(.secondary) } }
            if searching {
                Section { Label { Text("Searching on your Mac…") } icon: { ProgressView() }.foregroundStyle(.secondary) }
            } else if searchFailed {
                Section {
                    Text("Couldn’t reach your Mac to search, so these only match the words.").foregroundStyle(.secondary)
                    Button("Try again") { Task { await search() } }
                }
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { it in
                        NavigationLink { MemoryDetailScreen(item: it, direct: m.canForget == true) } label: { MemoryRow(item: it, asked: store.askedToForget.contains(it.id)) }
                    }
                } header: {
                    let total = m.items.count { !store.forgotten.contains($0.id) }
                    Text(ranked != nil ? "Best matches · \(items.count)" : items.count == total ? "Everything · \(items.count)" : "\(items.count) of \(total)")
                } footer: {
                    Text("Indexed \(ago(m.generatedAt))")
                }
            }
        }
        .overlay { if items.isEmpty { empty } }
        .searchable(text: $query, prompt: "Search memory")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { searchFailed = false; if query.isEmpty { rankedIn = nil } }
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
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(source != "all" || cluster != nil || needsLook ? Color.blue : Color.primary)
            }
        }
    }

    /// Why there's nothing to list: nothing kept yet, nothing matching the search, or filters that leave nothing.
    @ViewBuilder private var empty: some View {
        if m.items.isEmpty {
            ContentUnavailableView("No memories yet", systemImage: "text.alignleft",
                                   description: Text("Tell Otto something worth keeping and it shows up here."))
        } else if !typed.isEmpty {
            ContentUnavailableView.search(text: typed)
        } else {
            ContentUnavailableView {
                Label("Nothing matches these filters", systemImage: "line.3.horizontal.decrease")
            } actions: {
                Button("Show everything") { source = "all"; cluster = nil; needsLook = false }
            }
        }
    }

    private func search() async {
        struct Hits: Decodable { let results: [[Double]]; let generatedAt: String? }
        let q = typed
        guard !q.isEmpty else { rankedIn = nil; return }
        let snapshot = m.generatedAt
        searching = true; searchFailed = false
        let r: Hits? = await store.backend.dash("memory/search", query: ["q": q])
        // A ranking for a query that's since been edited would be shown against the new one: drop it.
        guard q == typed else { searching = false; return }
        searching = false
        searchFailed = r == nil
        // A failed search says the list only matches the words, so it can't keep an older ranking.
        if r == nil { rankedIn = nil }
        if let r {
            // The positions are into the index the Mac searched; if that's newer than this list, reload
            // the list so they line up (until then they're held back, not shown against the old one).
            rankedIn = (r.generatedAt ?? snapshot, q, r.results.compactMap { $0.first.map(Int.init) })
            if let g = r.generatedAt, g != snapshot { await reload() }
        }
    }

    private func rebuild() async {
        struct Started: Decodable { let started: Bool }
        let r: Started? = await store.backend.dash("memory/rebuild", method: "POST")
        note = r == nil ? "Already rebuilding, or the Mac didn’t take it." : "Rebuilding. Pull to refresh in a minute."
    }
}

struct MemoryRow: View {
    let item: MemoryItem
    /// Sent Otto a "forget" for it from its page: said on its row while it's still listed (the index drops a
    /// forgotten one when it's next rebuilt), and true either way: you did ask.
    var asked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.description).lineLimit(2)
                Spacer(minLength: 8)
                if item.badge == "never" { Pill(text: "never recalled", tint: .orange) }
                else if item.badge == "stale" { Pill(text: "stale", tint: .orange) }
            }
            Text(asked ? "Asked Otto to forget" : [item.kind, item.scope, item.status, item.due.map { "due \(day($0))" }, ago(item.updated)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct MemoryDetailScreen: View {
    let item: MemoryItem
    /// The memory's name (its handle, as memviewer lists it) as the thread's "Forget it" chip sends it (`forget memory <name>`), kept to
    /// letters, digits and -_. so a name the server sent can't turn into a sentence sent in your voice.
    static func slug(_ name: String) -> String {
        String(String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "-" }).prefix(80))
    }
    /// The Mac forgets it itself (POST memory/forget, when its memory page says `canForget`). Without that,
    /// forgetting goes through Otto in the chat, as the thread's "Forget it" does.
    var direct = false
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting = false
    @State private var failed = false
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
        // Memories only: a note's name is its first line, not a handle "forget memory" can find.
        .toolbar {
            if item.store != "notes" { Button("Forget", systemImage: "trash") { forgetting = true } }
        }
        // The words say which of the two will happen: gone now, or asked for in the chat.
        .confirmationDialog(direct ? "Forget this?" : "Ask Otto to forget this?", isPresented: $forgetting, titleVisibility: .visible) {
            Button(direct ? "Forget" : "Ask Otto to forget it", role: .destructive) {
                if direct { Task { await forget() } } else {
                    store.send("forget memory \(Self.slug(item.name))")
                    store.askedToForget.insert(item.id)
                    dismiss()
                }
            }
        } message: {
            // A dialog's message is never clipped, so a long memory is cut to about what its row shows.
            let what = item.description.count > 80 ? String(item.description.prefix(79)) + "…" : item.description
            Text(direct ? "“\(what)” is deleted from what Otto keeps. It can’t be brought back."
                 : "“\(what)” goes to Otto as a message in your chat, and Otto confirms there when it’s gone.")
        }
        .alert("Not forgotten", isPresented: $failed) { Button("OK") {} } message: {
            Text("Couldn’t reach your Mac, so Otto still has it. Try again when Otto is back.")
        }
    }

    /// Straight to the Mac. `ok` false means it had no such memory any more, which is what was asked for.
    private func forget() async {
        struct Done: Decodable { let ok: Bool }
        guard (await store.backend.dash("memory/forget", method: "POST", body: ["id": item.id]) as Done?) != nil else { failed = true; return }
        store.forgotten.insert(item.id)
        dismiss()
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
            .emptyState(p.cards.isEmpty, "Nobody yet", systemImage: "person.2", "Tell Otto who someone is and they show up here.")
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
