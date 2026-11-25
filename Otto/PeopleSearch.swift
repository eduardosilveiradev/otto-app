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
        let items = cards.map { item($0.name, $0.relationship, $0.org, $0.city) }
        // Someone the Mac no longer lists leaves Search too.
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in index.indexSearchableItems(items) }
    }

    /// One person's entry, from the four fields alone, so nothing else of theirs can reach Search
    /// (Scripts/people-search-check.sh).
    static func item(_ name: String, _ relationship: String?, _ org: String?, _ city: String?) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: .contact)
        a.title = name
        let about = [relationship, org, city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        a.contentDescription = about.isEmpty ? nil : about
        let item = CSSearchableItem(uniqueIdentifier: name, domainIdentifier: domain, attributeSet: a)
        item.expirationDate = .distantFuture   // not the default month: they stay until the Mac's list or one of the above takes them out
        return item
    }

    static func clear() { index.deleteSearchableItems(withDomainIdentifiers: [domain]) }

    /// At launch, with the Mac this app now talks to (nil: none, sample data).
    static func keep(only server: URL?) {
        if let was = UserDefaults.standard.string(forKey: from), was != server?.absoluteString { clear() }
    }
}
