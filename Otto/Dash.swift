import SwiftUI

// The web dashboard's views, on the phone. Everything comes from the Mac's
// dashboard API (/app/dash/*, wire contract in otto/dash-types.ts) with the
// app's own token; nothing here is computed on the phone, except the money
// screen's combined total, from public ECB rates (see ECB below).

// MARK: - Wire types (the parts the app shows)

struct DashTrigger: Codable, Hashable, Identifiable {
    let id: String; let type: String; let schedule: String?; let gist: String
    let repeating: Bool; let enabled: Bool; let nextRun: Double?; let lastFired: String?
}

struct MemoryItem: Decodable, Identifiable, Hashable {
    let id: String; let store: String; let kind: String; let scope: String; let name: String
    let description: String; let updated: String; let status: String?; let due: String?
    let tags: [String]?; let closedReason: String?; let hits: Int; let lastHitDays: Int?; let badge: String?
}

struct MemoryDetail: Decodable { let body: String }

struct DashMemory: Decodable {
    struct Cluster: Decodable, Identifiable { let id: Int; let size: Int; let label: String; let terms: [String] }
    struct Graph: Decodable { let c: [Int]?; let clusters: [Cluster]? }
    struct Summary: Decodable { let text: String; let note: String }
    let items: [MemoryItem]
    /// The Mac forgets a memory itself when asked (POST memory/forget); absent on a server that can't.
    var canForget: Bool? = nil
    let summary: Summary
    let generatedAt: String
    let graph: Graph
}

struct PersonCard: Decodable, Identifiable {
    struct Note: Decodable, Hashable { let at: String; let text: String }
    var id: String { name }
    let name: String; let relationship: String?; let city: String?; let timezone: String?; let org: String?
    let notes: [Note]; let inbound: Int; let outbound: Int; let lastContact: String?; let mentions: [Int]
}

struct LoopRow: Decodable, Identifiable {
    let id: String; let text: String; let tags: [String]; let createdAt: String; let due: String?
    let status: String?; let closedReason: String?; let closedBy: String?; let closedAt: String?; let deferrals: [String]?
}

struct DashLoops: Decodable {
    struct Close: Decodable { let id: String; let status: String; let reason: String }
    struct Propose: Decodable { let id: String; let text: String; let reason: String }
    struct Avoid: Decodable { let id: String; let text: String; let deferrals: Int }
    struct Plan: Decodable { let close: [Close]; let propose: [Propose]; let avoidance: [Avoid] }
    let open: [LoopRow]; let plan: Plan; let recent: [LoopRow]
}

struct DashMoney: Decodable {
    struct Row: Decodable, Identifiable {
        let id: String; let merchant: String; let amount: Double; let currency: String; let date: String
        let category: String?; let method: String?; let note: String?
    }
    struct Total: Decodable, Hashable { let currency: String; let total: Double; let count: Int }
    struct Month: Decodable { let month: String; let totals: [Total] }
    struct Category: Decodable, Hashable { let category: String; let total: Double; let count: Int }
    let records: [Row]; let byCurrency: [Total]; let byMonth: [Month]; let byCategory: [Category]
}

struct DashTrips: Decodable {
    struct Zoned: Decodable { let local: String; let zone: String? }
    struct Segment: Decodable {
        let kind: String
        let flight: String?; let carrier: String?; let from: String?; let to: String?; let depart: Zoned?; let arrive: Zoned?
        let name: String?; let city: String?; let checkIn: String?; let checkOut: String?
    }
    struct Trip: Decodable, Identifiable { let id: String; let start: String; let end: String; let segments: [Segment] }
    struct Current: Decodable { let id: String; let mode: String }
    let trips: [Trip]; let current: Current?; let problems: [String: [String]]
}

struct DashPackages: Decodable {
    struct Event: Decodable, Hashable { let at: String; let status: String; let text: String }
    struct Package: Decodable, Identifiable {
        let id: String; let carrier: String; let carrierName: String; let tracking: String?; let trackingUrl: String?
        let merchant: String?; let item: String?; let status: String
        let eta: String?; let etaLatest: String?; let updatedAt: String; let deliveredAt: String?; let events: [Event]
    }
    /// Active first, then delivered in the last 30 days.
    let packages: [Package]
}

struct SourceStats: Decodable, Identifiable {
    var id: String { src }
    let src: String; let sent: Int; let engaged: Int; let silentStreak: Int; let lastSent: String?; let lastEngaged: String?
}

struct CapRow: Decodable, Identifiable {
    let id: String; let at: String; let what: String; let tier: String; let origin: String; let by: String; let revertedAt: String?
}

struct JobRow: Decodable, Identifiable {
    let id: String; let task: String; let state: String; let createdAt: String; let costUsd: Double?
    let result: String?; let error: String?; let notBefore: String?
}

struct DashStatus: Decodable {
    struct Row: Decodable, Identifiable { let id: String; let label: String; let verdict: String; let at: Double?; let detail: String }
    let rows: [Row]; let repairs: [String]
}

struct Device: Decodable, Identifiable {
    let id: String; let name: String; let created: String; let lastUsed: String?
    let scope: String?; let origin: String?; let expires: String?; let ua: String?
}

// MARK: - Calls

extension OttoBackend {
    func dash<T: Decodable>(_ path: String, query: [String: String] = [:], method: String = "GET", body: [String: Any]? = nil) async -> T? {
        guard let data = await dashData(method, path, query: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) },
                                        body: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
        else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            #if DEBUG
            print("[dash] \(path): \(error)")
            #endif
            return nil
        }
    }

    /// What this page showed the last time it could be read, and when: for a Mac that's out of reach now.
    func dashKept<T: Decodable>(_ path: String, query: [String: String] = [:]) -> (value: T, at: Date)? {
        guard let kept = dashKept(path, query: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }),
              let value = try? JSONDecoder().decode(T.self, from: kept.data) else { return nil }
        return (value, kept.at)
    }
}

/// Fetches one dashboard endpoint and hands it to `content` with a reload, or says the Mac is out of reach.
struct Loaded<T: Decodable, Content: View>: View {
    let path: String
    var query: [String: String] = [:]
    @ViewBuilder let content: (T, @escaping () async -> Void) -> Content
    @Environment(OttoStore.self) private var store
    @State private var value: T?
    @State private var failed = false
    /// When what's on screen was read, and whether a later read failed: it's then old, and the page says how old.
    @State private var loadedAt = Date.now
    @State private var stale = false

    var body: some View {
        Group {
            if let value {
                content(value, load)
                    .safeAreaInset(edge: .bottom) {
                        if stale {
                            HStack(spacing: 8) {
                                Text("\(why.stale) This is from \(loadedAt.formatted(date: Calendar.current.isDateInToday(loadedAt) ? .omitted : .abbreviated, time: .shortened)).")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Try again") { Task { await load() } }.font(.footnote.weight(.semibold))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            // Solid, not glass: rows scrolled under it would read through its words.
                            .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 17, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5) }
                            .padding(.horizontal, 16).padding(.bottom, 8)
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: stale)
            }
            else if failed {
                ContentUnavailableView {
                    Label(why.title, systemImage: why.symbol)
                } description: {
                    Text(why.detail)
                } actions: {
                    // Sample data has no Mac to try again: the line above says what the page needs.
                    if !(store.backend is MockBackend) { Button("Try again") { failed = false; Task { await load() } } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
            } else {
                // The grouped grey the list lands on, so light mode doesn't flash white first.
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemGroupedBackground))
            }
        }
        .task(id: query) { await load() }
    }

    /// What went wrong, told apart by the Mac's answer (otto/dash.ts): the thing asked for is gone (a 404 for
    /// one item), the Mac has nothing for the page (a 404 for a page: no index yet, or an older Otto), it isn't
    /// set up there (501: calls without a callbot), the token was refused, an error; or no answer at all, with
    /// this phone offline or the Mac out of reach.
    private var why: (title: String, symbol: String, detail: String, stale: String) {
        switch store.backend.dashFailure(path) {
        case 404? where !query.isEmpty: ("No longer on your Mac", "questionmark.folder", "It may have been removed since.", "Your Mac no longer has this.")
        case 404?: ("Nothing here yet", "tray", "Your Mac has nothing for this page. If its Otto is older than this app, update it there.", "Your Mac has nothing for this page now.")
        case 501?: ("Not set up on your Mac", "wrench.and.screwdriver", "Otto on your Mac isn’t set up for this yet.", "This isn’t set up on your Mac any more.")
        case 401?, 403?: ("Your Mac didn’t accept this phone", "lock", "Its token doesn’t open this page. Pair again from the contact card.", "Your Mac didn’t accept this phone.")
        case let code? where code >= 400: ("Otto hit an error", "exclamationmark.triangle", "Your Mac answered with an error (\(code)). Try again in a moment.", "Otto hit an error (\(code)).")
        default:
            if store.noNetwork { ("You’re offline", "wifi.slash", "Connect to Wi-Fi or mobile data.", "You’re offline.") }
            else {
                ("Can’t reach your Mac", "wifi.slash",
                 store.backend is MockBackend ? "This page needs your Mac. You’re looking at sample data."
                 : store.backend.isLive ? "Otto didn’t answer. Try again in a moment." : "Check it’s awake and on Tailscale.",
                 "Couldn’t reach your Mac.")
            }
        }
    }

    private func load() async {
        if let v: T = await store.backend.dash(path, query: query) { value = v; failed = false; stale = false; loadedAt = .now }
        // No answer at all (not a refusal or a missing page): what this page showed last time, said to be old.
        else if value == nil, store.backend.dashFailure(path) == 0, let kept: (value: T, at: Date) = store.backend.dashKept(path, query: query) {
            value = kept.value; failed = false; stale = true; loadedAt = kept.at
        }
        else if value == nil { failed = true } else { stale = true }
        #if DEBUG
        // `-staleDash`: as if a later read had failed, for screenshots of the line that says so.
        if value != nil, CommandLine.arguments.contains("-staleDash") { stale = true }
        #endif
    }
}

extension View {
    /// A screen with nothing in it, drawn the way the system draws one (as "Can't reach your Mac" is), over
    /// the empty list so pull to refresh still works.
    func emptyState(_ empty: Bool, _ title: String, systemImage: String, _ description: String? = nil) -> some View {
        overlay {
            if empty {
                ContentUnavailableView(title, systemImage: systemImage, description: description.map(Text.init))
                    .background(Color(.systemGroupedBackground))   // the list's own grey, not white, in light mode
            }
        }
    }
}

extension View {
    /// Behind a sheet's bottom bar: the sheet's grey, faded in over the 24pt above it, so rows scrolled under
    /// dissolve instead of reading through the buttons (the thread composer's treatment).
    func bottomBarFade() -> some View {
        background {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                Color(.systemGroupedBackground)
            }
            .padding(.top, -24)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Formatting

/// A server timestamp or bare date, as a Date.
func dashDate(_ s: String?) -> Date? { LiveBackend.date(s) }

/// "3 hours ago", or "" without a date.
func ago(_ s: String?) -> String { dashDate(s).map(ago) ?? "" }
func ago(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }

/// "Mon 12 Oct" for a bare YYYY-MM-DD, read as a calendar day wherever the phone is.
func day(_ s: String) -> String {
    dashDate(s)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? s
}

/// A wall-clock time where it happens ("2026-08-12T14:35" → "Wed 12 Aug, 14:35"), never converted.
func wallClock(_ local: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .gmt; f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    guard let d = f.date(from: String(local.prefix(16))) else { return local }
    var out = Date.FormatStyle(date: .abbreviated, time: .shortened); out.timeZone = .gmt
    return d.formatted(out)
}

func money(_ amount: Double, _ currency: String) -> String { amount.formatted(.currency(code: currency)) }

/// ECB reference rates from frankfurter.dev, for the money screen's combined total. Only currency
/// codes go out: no amounts, no token.
enum ECB {
    /// Units of each currency per 1 `base`, as published on `date` (the last ECB working day).
    struct Rates: Decodable, Equatable { let base: String; let date: String; let rates: [String: Double] }

    /// Every total in `base`, or nil when a rate is missing or odd: a guessed rate is a wrong number.
    static func combined(_ totals: [DashMoney.Total], in r: Rates) -> Double? {
        var sum = 0.0
        for t in totals {
            if t.currency == r.base { sum += t.total; continue }
            guard let rate = r.rates[t.currency], rate.isFinite, rate > 0 else { return nil }
            sum += t.total / rate
        }
        return sum
    }

    @MainActor private static var cache: [String: Rates] = [:]

    /// Once a day per base and set of currencies. Nil when offline or the answer is incomplete, and never cached then.
    @MainActor static func rates(_ base: String, _ others: [String]) async -> Rates? {
        let to = others.sorted().joined(separator: ",")
        let key = "\(Date.now.formatted(.iso8601.year().month().day())) \(base) \(to)"
        if let hit = cache[key] { return hit }
        var u = URLComponents(string: "https://api.frankfurter.dev/v1/latest")!
        u.queryItems = [URLQueryItem(name: "from", value: base), URLQueryItem(name: "to", value: to)]
        guard let url = u.url, let (data, res) = try? await URLSession.shared.data(from: url),
              (res as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Rates.self, from: data),
              r.base == base, others.allSatisfy({ r.rates[$0] != nil }) else { return nil }
        cache[key] = r
        return r
    }
}

/// A grey rounded square with a symbol, the way the contact card draws its rows.
struct RowIcon: View {
    let symbol: String
    var tint: Color = .secondary
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 7, style: .continuous))
    }
}

/// A small capsule label: "Open", "never recalled", "down".
struct Pill: View {
    let text: String
    var tint: Color = .secondary
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // Tangerine is the "needs you" mark: a dot and a word, never a tinted capsule.
        if tint == .orange { NeedsMark(text: text) } else { capsule }
    }

    private var capsule: some View {
        Text(text.prefix(1).uppercased() + text.dropFirst())   // one case for every badge: "Running", "Live"
            .font(.caption.weight(.medium))
            // Any tint as small text: as is in dark mode, 40% toward black in light, so green, red and
            // orange all clear 4.5:1 on their pale capsule.
            .foregroundStyle(tint == .secondary ? Color.secondary : scheme == .dark ? tint : tint.mix(with: .black, by: 0.4))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint == .secondary ? Color(.tertiarySystemFill) : tint.opacity(0.15), in: .capsule)
    }
}
