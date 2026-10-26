import SwiftUI

// The web dashboard's views, on the phone. Everything comes from the Mac's
// dashboard API (/app/dash/*, wire contract in otto/dash-types.ts) with the
// app's own token; nothing here is computed on the phone.

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
}

/// Fetches one dashboard endpoint and hands it to `content` with a reload, or says the Mac is out of reach.
struct Loaded<T: Decodable, Content: View>: View {
    let path: String
    var query: [String: String] = [:]
    @ViewBuilder let content: (T, @escaping () async -> Void) -> Content
    @Environment(OttoStore.self) private var store
    @State private var value: T?
    @State private var failed = false

    var body: some View {
        Group {
            if let value { content(value, load) }
            else if failed {
                ContentUnavailableView {
                    Label("Can't reach your Mac", systemImage: "wifi.slash")
                } description: {
                    Text(store.backend.isLive ? "Otto didn't answer." : "This needs the Otto server.")
                } actions: {
                    Button("Try Again") { failed = false; Task { await load() } }
                }
            } else { ProgressView() }
        }
        .task(id: query) { await load() }
    }

    private func load() async {
        if let v: T = await store.backend.dash(path, query: query) { value = v; failed = false } else if value == nil { failed = true }
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
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint == .secondary ? Color(.tertiarySystemFill) : tint.opacity(0.15), in: .capsule)
    }
}
