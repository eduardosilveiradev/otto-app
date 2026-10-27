import Foundation

// MARK: - Models

/// `terminal` is a prompt you typed into Otto's terminal on the Mac: a system line in the
/// thread (its first few words), not a bubble, and nothing to notify, answer or react to.
enum Sender: String, Codable { case me, otto, terminal }

struct ActionButton: Identifiable, Hashable, Codable {
    var id: String { data ?? url ?? copy ?? label }
    let label: String
    /// Self-contained instruction, same contract as Telegram button data. Nil on a link button.
    let data: String?
    /// A link button opens this page and never comes back as an event.
    var url: String? = nil
    /// Copy button: tapping puts this on the clipboard and never comes back as an event.
    var copy: String? = nil
}

struct Message: Identifiable, Codable {
    var id = UUID()
    let from: Sender
    var text: String
    var date = Date()
    var buttons: [ActionButton] = []
    var isVoice = false
    /// A photo you sent, as the JPEG that went up. Kept small (see `OttoStore.sendPhoto`).
    var image: Data? = nil
    /// Yours, written but not yet handed to the server. Saved with the thread, so a
    /// restart resends it. Optional so threads saved before it existed still decode.
    var pending: Bool? = nil
    /// Came in through the share sheet: the server treats it as someone else's words, not a request.
    var shared: Bool? = nil
    /// Emoji reaction shown on the bubble's corner (Otto reacting to yours, or yours to Otto's).
    var reaction: String? = nil
    /// Otto's id for its own messages; yours go up under `id`. See `wireID`.
    var serverID: String? = nil
    /// Yours, once Otto has actually taken it in (it may sit queued while Otto is busy).
    var read: Bool? = nil
    /// The wireID of the message this one answers (a swipe-reply, either way).
    var replyTo: String? = nil
    /// Photos and files Otto sent, fetched on demand with `OttoBackend.file`.
    var files: [RemoteFile]? = nil
    /// Otto's spoken version of `text`.
    var audio: RemoteFile? = nil
    /// Which notification stack it belongs to ("chat", or the topic of something Otto raised
    /// on its own), and "timeSensitive" when it shouldn't wait. See `Notifier.post`.
    var thread: String? = nil
    var level: String? = nil
    /// Where an unprompted message of Otto's came from, as the server states it ("trigger:<id>",
    /// "email-scan", "nudge:loops", …) and in plain words. Nil on replies: no "Why this?" for those.
    var src: String? = nil
    var why: String? = nil
    var failed: Bool? = nil
    /// What Otto armed while writing this, shown as a chip in the bubble (Schedules.swift).
    var scheduled: [DashTrigger]? = nil

    /// The id both ends use for this message.
    var wireID: String { serverID ?? id.uuidString }
}

struct RemoteFile: Codable, Hashable {
    let id: String
    let name: String
    /// "image", "audio" or "file".
    let kind: String
}

struct CalEvent: Identifiable { let id = UUID(); let title: String; let start: Date; let minutes: Int }
struct MailItem: Identifiable { let id = UUID(); let from: String; let subject: String }
/// `id` is the server's note id, which closing one needs.
struct Loop: Identifiable { var id = UUID().uuidString; let title: String; let due: Date? }
struct Trigger: Identifiable { let id = UUID(); let title: String; let next: Date }

/// The hold on Otto's non-urgent messages (`/app/snooze`). `until` is nil when there's none.
struct Snooze: Decodable {
    struct Held: Decodable, Hashable { let text: String; let at: Date }
    var until: Date?
    var since: Date?
    var held: [Held]

    /// The server's dates are ISO 8601 with milliseconds, which `.iso8601` won't read.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))) ?? (try? Date(s, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not a date: \(s)"))
        }
        return d
    }()
}

enum SnoozeChange { case minutes(Int), clear }

/// A build the Mac is offering (`GET /app/update`). `ipa` is a public link SideStore can fetch.
struct Release: Decodable {
    let version: String
    let build: String
    let ipa: String
    let source: String
}

struct Brief {
    var asOf: Date
    var events: [CalEvent]
    var inbox: [MailItem]
    var bulk: Int
    var loops: [Loop]
    var triggers: [Trigger]
}

// MARK: - The backend seam

/// Everything the app knows about the server goes through here.
/// The real one is a websocket to otto/server.ts over Tailscale, carrying the
/// same events the Telegram transport does. Swap it in at `OttoApp`.
protocol OttoBackend: AnyObject {
    var name: String { get }
    var isLive: Bool { get }
    /// Bumps on every successful (re)connect, so a drop too brief to see still triggers a catch-up.
    var connections: Int { get }
    /// Messages Otto sends, whenever it sends them (replies and proactive).
    var incoming: AsyncStream<Message> { get }
    /// Otto's tapbacks: (wireID of the message, emoji).
    var reactions: AsyncStream<(String, String)> { get }
    /// What Otto is doing right now ("Reading ChatView.swift"), while a reply is on its way.
    var statuses: AsyncStream<String> { get }
    /// wireIDs of your messages Otto has just taken in.
    var reads: AsyncStream<[String]> { get }
    /// Whether Otto is working on something you sent, as the server sees it.
    var typing: AsyncStream<Bool> { get }
    /// Approval screens the server raised, and ones it settled or dropped.
    var approvalUpdates: AsyncStream<ApprovalUpdate> { get }
    /// A reply's voice, landing after its text: (wireID, the clip, or nil when none is coming).
    var voices: AsyncStream<(String, RemoteFile?)> { get }
    /// Otto rewriting a message it already sent: (wireID, new text).
    var edits: AsyncStream<(String, String)> { get }
    func decide(approval id: String, approve: Bool) async
    func history(background: Bool) async -> [Message]
    /// True once the server has the message; false means try again later.
    func send(_ text: String, id: String, replyTo: String?, shared: Bool) async -> Bool
    func tap(_ button: ActionButton) async
    func react(to id: String, emoji: String) async
    func sendPhoto(_ jpeg: Data, caption: String, id: String, shared: Bool) async
    /// Uploads an m4a voice note and returns its transcript ("" when there is none),
    /// or nil when the upload didn't make it, so the note stays pending and is retried.
    func sendVoice(_ m4a: Data, id: String) async -> String?
    /// A file Otto sent (RemoteFile.id). Nil when it's gone, e.g. after a server restart.
    func file(_ id: String) async -> Data?
    func brief() async -> Brief
    func release() async -> Release?
    /// Reads the snooze (nil), snoozes or extends it by `.minutes`, or ends it and delivers what it held.
    func snooze(_ change: SnoozeChange?) async -> Snooze?
    /// Closes an open loop, or reopens it. False when the Mac didn't take it.
    func setLoop(_ id: String, done: Bool) async -> Bool
    /// "Speak replies when I speak", which lives on the Mac. `set` nil just reads it.
    func speakReplies(set: Bool?) async -> Bool?
    /// The Mac's /settings switches. `flip` nil just reads them.
    func settings(flip id: String?) async -> SettingsPage?
    /// One call to the dashboard API (`/app/dash/<path>`), the body of a 2xx or nil.
    func dashData(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async -> Data?
    /// The flight-day card (`/app/gate`); nil when the Mac didn't answer.
    func gate() async -> GateReply?
    /// The passport page (`/app/stamps`); nil when the Mac didn't answer.
    func stamps() async -> StampsReply?
}

extension OttoBackend {
    var voices: AsyncStream<(String, RemoteFile?)> { AsyncStream { _ in } }
    var edits: AsyncStream<(String, String)> { AsyncStream { _ in } }
    func release() async -> Release? { nil }
    func snooze(_ change: SnoozeChange?) async -> Snooze? { nil }
    func setLoop(_ id: String, done: Bool) async -> Bool { !isLive }
    func speakReplies(set: Bool?) async -> Bool? { nil }
    func settings(flip id: String?) async -> SettingsPage? { nil }
    func dashData(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async -> Data? { nil }
    func gate() async -> GateReply? { nil }
    func stamps() async -> StampsReply? { nil }
    var typing: AsyncStream<Bool> { AsyncStream { _ in } }
    var approvalUpdates: AsyncStream<ApprovalUpdate> { AsyncStream { _ in } }
    func decide(approval id: String, approve: Bool) async {}
}

/// One switch on the Mac's settings page; `section` is otto, recurring or connectors.
struct SettingToggle: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let on: Bool
    let section: String
}

struct SettingsPage: Decodable {
    let toggles: [SettingToggle]
    /// Set after a flip; starts with "couldn't" when the Mac refused it.
    let note: String?
}

// MARK: - Mock

final class MockBackend: OttoBackend {
    let name = "Mock data"
    let isLive = false
    let connections = 0
    let incoming: AsyncStream<Message>
    let reactions = AsyncStream<(String, String)> { _ in }
    let statuses = AsyncStream<String> { _ in }
    let reads = AsyncStream<[String]> { _ in }
    private let out: AsyncStream<Message>.Continuation

    init() {
        (incoming, out) = AsyncStream.makeStream()
    }

    func react(to id: String, emoji: String) async {}
    func file(_ id: String) async -> Data? { nil }

    static let triggers: [DashTrigger] = {
        let h: Double = 3_600_000, now = Date().timeIntervalSince1970 * 1000
        return [
            DashTrigger(id: "a1", type: "cron", schedule: nil, gist: "overnight voice fix", repeating: false, enabled: true, nextRun: now + 14 * h, lastFired: nil),
            DashTrigger(id: "a2", type: "cron", schedule: "57 8 * * *", gist: "morning brief", repeating: true, enabled: true, nextRun: now + 20 * h, lastFired: nil),
            DashTrigger(id: "a3", type: "cron", schedule: "0 18 * * 1-5", gist: "homework run", repeating: true, enabled: true, nextRun: now + 5 * h, lastFired: nil),
            DashTrigger(id: "a4", type: "email", schedule: nil, gist: "tell me when the landlord replies", repeating: false, enabled: true, nextRun: nil, lastFired: nil),
            DashTrigger(id: "a5", type: "cron", schedule: nil, gist: "desk google login reminder", repeating: false, enabled: false, nextRun: nil, lastFired: "2026-10-26T07:00:28Z"),
        ]
    }()

    func dashData(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) async -> Data? {
        let enc = JSONEncoder()
        if path == "triggers" { return try? enc.encode(["triggers": Self.triggers]) }
        guard path == "triggers/item", let t = Self.triggers.first(where: { $0.id == query.first?.value }) else { return nil }
        var o = (try? JSONSerialization.jsonObject(with: enc.encode(t))) as? [String: Any] ?? [:]
        o["action"] = "Overnight fix the user asked for: replies in the app sound robotic. Find out why from the voice daemon's own log, fix it on a branch, self-test it, and leave one line in the morning."
        o["createdAt"] = "2026-10-26T12:19:40Z"
        return try? JSONSerialization.data(withJSONObject: o)
    }

    func history(background: Bool) async -> [Message] {
        return []
    }

    func send(_ text: String, id: String, replyTo: String?, shared: Bool) async -> Bool {
        Task {
            try? await Task.sleep(for: .seconds(60))
            out.yield(Message(from: .otto, text: "(mock) got it — \"\(text)\". the real me isn't plugged in yet."))
        }
        return true
    }

    func tap(_ button: ActionButton) async {
        try? await Task.sleep(for: .milliseconds(600))
        out.yield(Message(from: .otto, text: "(mock) \(button.data ?? button.url ?? "") ✓"))
    }

    func sendPhoto(_ jpeg: Data, caption: String, id: String, shared: Bool) async {
        out.yield(Message(from: .otto, text: "(mock) nice photo"))
    }

    func sendVoice(_ m4a: Data, id: String) async -> String? {
        out.yield(Message(from: .otto, text: "(mock) heard you"))
        return "(mock transcript)"
    }

    /// `-snoozed` starts it snoozed, for the card.
    private var snoozed: Snooze? = ProcessInfo.processInfo.arguments.contains("-snoozed")
        ? Snooze(until: .now.addingTimeInterval(1800), since: .now.addingTimeInterval(-1800),
                 held: [.init(text: "Marco read your message", at: .now.addingTimeInterval(-1500)),
                        .init(text: "A Figma newsletter", at: .now.addingTimeInterval(-900)),
                        .init(text: "Enel bill, €112, due Friday", at: .now.addingTimeInterval(-300))])
        : nil

    func snooze(_ change: SnoozeChange?) async -> Snooze? {
        switch change {
        case nil: break
        case .clear?: snoozed = nil
        case .minutes(let m)?:
            let from = snoozed?.until ?? .now
            snoozed = Snooze(until: from.addingTimeInterval(Double(m) * 60), since: snoozed?.since ?? .now, held: snoozed?.held ?? [])
        }
        return snoozed ?? Snooze(until: nil, since: nil, held: [])
    }

    func gate() async -> GateReply? {
        let dep = Date().addingTimeInterval(3 * 3600)
        return GateReply(card: GateCard(
            key: "TA482@mock", flight: "TA482", carrier: "TA", from: "SFO", to: "JFK",
            fromCity: "San Francisco", toCity: "New York", date: String(ISO8601DateFormatter().string(from: dep).prefix(10)),
            departs: "08:45", arrives: "17:05", departsEst: "09:25", arrivesEst: "17:45",
            departsAt: ISO8601DateFormatter().string(from: dep), durationMinutes: 320, state: "scheduled",
            delayMinutes: 40, gate: "B12", terminal: "2", seat: "14A", cabin: "Economy", booking: "ABC123"))
    }

    func stamps() async -> StampsReply? {
        StampsReply(stamps: [
            TravelStamp(id: "new york", city: "New York", code: "JFK", country: "US", first: "2026-03-02", last: "2026-06-12", visits: 3,
                  places: [StampPlace(name: "Café Lume", kind: "cafe", status: "loved", note: "the cortado, and the window seat")]),
            TravelStamp(id: "lisboa", city: "Lisboa", country: "PT", first: "2026-05-01", last: "2026-05-01", visits: 1),
            TravelStamp(id: "san francisco", city: "San Francisco", code: "SFO", country: "US", first: "2026-06-20", last: "2026-06-20", visits: 1),
            TravelStamp(id: "tokyo", city: "Tokyo", code: "HND", country: "JP", first: "2026-08-14", last: "2026-08-14", visits: 1),
        ])
    }

    func brief() async -> Brief {
        let cal = Calendar.current
        func today(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        return Brief(
            asOf: Date(),
            events: [CalEvent(title: "Dentist", start: today(15, 30), minutes: 45),
                     CalEvent(title: "Call with design team", start: today(18), minutes: 30)],
            inbox: [MailItem(from: "Landlord", subject: "Boiler service this week"),
                    MailItem(from: "Electric Co.", subject: "Your bill is ready — €64.20")],
            bulk: 9,
            loops: [Loop(title: "Pay electric bill", due: cal.date(byAdding: .day, value: 2, to: Date())),
                    Loop(title: "Waiting on passport renewal", due: nil)],
            triggers: [Trigger(title: "Morning brief", next: cal.date(byAdding: .day, value: 1, to: today(8, 57))!),
                       Trigger(title: "Bill reminder", next: cal.date(byAdding: .day, value: 1, to: today(9))!)]
        )
    }
}
