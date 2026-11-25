import CoreSpotlight
import UniformTypeIdentifiers

/// Otto's people in iPhone Search: type a name, see who they are to you. Each read of the Mac's people list
/// (GET /app/dash/people) replaces what's there with each person's name, relationship, organisation and city,
/// and nothing else of theirs: no notes, memories, money or email. A tap opens their page (OttoApp).
/// LiveBackend takes them out again on a forget, when the Mac stops taking this phone's token (401), and at
/// launch when the app is now paired with another Mac or none.
enum PeopleSearch {
    private static let domain = "people"
    /// The Mac whose people may be in Search. Never cleared: a launch on any other pairing clears Search again,
    /// which costs nothing when it's already empty, and retries a removal that failed.
    private static let from = "otto.peopleSearchFrom"
    private static var index: CSSearchableIndex { .default() }

    static func index(_ cards: [PersonCard], from server: URL) {
        UserDefaults.standard.set(server.absoluteString, forKey: from)   // before they go in, so a crash can't leave them unclaimed
        let items = cards.map { c in
            let a = CSSearchableItemAttributeSet(contentType: .contact)
            a.title = c.name
            a.contentDescription = [c.relationship, c.org, c.city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            let item = CSSearchableItem(uniqueIdentifier: c.name, domainIdentifier: domain, attributeSet: a)
            item.expirationDate = .distantFuture   // not the default month: they stay until the Mac's list or one of the above takes them out
            return item
        }
        // Someone the Mac no longer lists leaves Search too.
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in index.indexSearchableItems(items) }
    }

    static func clear() { index.deleteSearchableItems(withDomainIdentifiers: [domain]) }

    /// At launch, with the Mac this app now talks to (nil: none, sample data).
    static func keep(only server: URL?) {
        if let was = UserDefaults.standard.string(forKey: from), was != server?.absoluteString { clear() }
    }

    #if DEBUG
    /// `-peopleSearchCheck` (read with `simctl launch --console-pty`): what goes into Search, what never does,
    /// and what takes it out, against this app's own Spotlight items. Ends with nothing of its own left there.
    static func check() async {
        func card(_ name: String, _ rel: String? = nil, _ org: String? = nil, _ city: String? = nil) -> PersonCard {
            PersonCard(name: name, relationship: rel, city: city, timezone: nil, org: org,
                       notes: [.init(at: "2026-11-01", text: "zebracorn deposit")], inbound: 0, outbound: 0, lastContact: nil, mentions: [])
        }
        func found(_ q: String) async -> [CSSearchableItem] {
            let ctx = CSSearchQueryContext(); ctx.fetchAttributes = ["title", "contentDescription"]
            let query = CSSearchQuery(queryString: "** == \"\(q)*\"cd", queryContext: ctx)
            var all: [CSSearchableItem] = []
            query.foundItemsHandler = { all += $0 }
            await withCheckedContinuation { done in query.completionHandler = { _ in done.resume() }; query.start() }
            return all
        }
        func settle() async { try? await Task.sleep(for: .seconds(1.5)) }
        func expect(_ ok: Bool, _ what: String) { print("PEOPLESEARCH \(ok ? "PASS" : "FAIL") \(what)") }
        let a = URL(string: "http://127.0.0.1:1")!
        let long = String(repeating: "Bartholomew-", count: 12) + "Okonkwo"
        index([card("Dana Reyes", "landlord’s contact", "Casa Lettings", "Lisbon"), card("Wren"), card("王小明", "colleague"), card(long)], from: a)
        await settle()
        let dana = await found("Dana")
        expect(dana.count == 1 && dana.first?.attributeSet.contentDescription == "landlord’s contact · Casa Lettings · Lisbon", "name finds who they are to you")
        expect(await found("landlord").count == 1, "relationship is searchable")
        expect(await found("zebracorn").isEmpty, "a note's words never go in")
        expect(await found("Wren").first?.attributeSet.contentDescription == "", "a name alone has no stray separators")
        let (han, longName) = (await found("王小明"), await found("Bartholomew"))
        expect(han.count == 1 && longName.count == 1, "non-Latin and very long names")
        index([card("Wren")], from: a)
        await settle()
        let (gone, kept) = (await found("Dana"), await found("Wren"))
        expect(gone.isEmpty && kept.count == 1, "a new list replaces the old one")
        clear()
        await settle()
        expect(await found("Wren").isEmpty, "a forget or a 401 takes everyone out")
        index([card("Wren")], from: a)
        await settle()
        keep(only: a)
        await settle()
        expect(await found("Wren").count == 1, "the same Mac at launch keeps them")
        keep(only: URL(string: "http://127.0.0.1:2")!)
        await settle()
        expect(await found("Wren").isEmpty, "another Mac at launch takes them out")
        index([card("Wren")], from: a)
        await settle()
        keep(only: nil)
        await settle()
        expect(await found("Wren").isEmpty, "no Mac at launch takes them out")
        print("PEOPLESEARCH done")
    }
    #endif
}
