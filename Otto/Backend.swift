import Foundation

// MARK: - Models

enum Sender: String, Codable { case me, otto }

struct ActionButton: Identifiable, Hashable, Codable {
    var id: String { data }
    let label: String
    /// Self-contained instruction, same contract as Telegram button data.
    let data: String
}

struct Message: Identifiable, Codable {
    var id = UUID()
    let from: Sender
    let text: String
    var date = Date()
    var buttons: [ActionButton] = []
    var isVoice = false
    /// A photo you sent, as the JPEG that went up. Kept small (see `OttoStore.sendPhoto`).
    var image: Data? = nil
    /// Yours, written but not yet handed to the server. Saved with the thread, so a
    /// restart resends it. Optional so threads saved before it existed still decode.
    var pending: Bool? = nil
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
struct Loop: Identifiable { let id = UUID(); let title: String; let due: Date? }
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
    func history() async -> [Message]
    /// True once the server has the message; false means try again later.
    func send(_ text: String, id: String, replyTo: String?) async -> Bool
    func tap(_ button: ActionButton) async
    func react(to id: String, emoji: String) async
    func sendPhoto(_ jpeg: Data, caption: String, id: String) async
    /// Uploads an m4a voice note and returns its transcript ("" when there is none).
    func sendVoice(_ m4a: Data, id: String) async -> String
    /// A file Otto sent (RemoteFile.id). Nil when it's gone, e.g. after a server restart.
    func file(_ id: String) async -> Data?
    func brief() async -> Brief
    func release() async -> Release?
    /// Reads the snooze (nil), snoozes or extends it by `.minutes`, or ends it and delivers what it held.
    func snooze(_ change: SnoozeChange?) async -> Snooze?
}

extension OttoBackend {
    func release() async -> Release? { nil }
    func snooze(_ change: SnoozeChange?) async -> Snooze? { nil }
    var typing: AsyncStream<Bool> { AsyncStream { _ in } }
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

    init() { (incoming, out) = AsyncStream.makeStream() }

    func react(to id: String, emoji: String) async {}
    func file(_ id: String) async -> Data? { nil }

    func history() async -> [Message] {
        return []
    }

    func send(_ text: String, id: String, replyTo: String?) async -> Bool {
        Task {
            try? await Task.sleep(for: .seconds(60))
            out.yield(Message(from: .otto, text: "(mock) got it — \"\(text)\". the real me isn't plugged in yet."))
        }
        return true
    }

    func tap(_ button: ActionButton) async {
        try? await Task.sleep(for: .milliseconds(600))
        out.yield(Message(from: .otto, text: "(mock) \(button.data) ✓"))
    }

    func sendPhoto(_ jpeg: Data, caption: String, id: String) async {
        out.yield(Message(from: .otto, text: "(mock) nice photo"))
    }

    func sendVoice(_ m4a: Data, id: String) async -> String {
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
