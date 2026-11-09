#if DEBUG
import SwiftUI

/// Every mockup state, for screenshots. `-pipsFixture` serves the mockup's made-up data through the
/// real pips API seam, so decoding and the store run as they would against a server. `-pipsScreen`
/// opens a section: conversations, otto, group, handoff, failed, otto-group, new-group, details, faces.
/// Debug builds only.
enum PipFixture {
    static var on: Bool { CommandLine.arguments.contains("-pipsFixture") }
    static var screen: String {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "-pipsScreen"), i + 1 < a.count else { return "conversations" }
        return a[i + 1]
    }

    // The mockup's clock: a Thursday morning.
    private static let cal = Calendar.current
    private static let thursday = cal.nextDate(after: .now, matching: DateComponents(weekday: 5), matchingPolicy: .nextTime)!
    private static func at(_ daysBack: Int, _ h: Int, _ m: Int, real: Bool = false) -> String {
        let base = real ? Date.now : thursday
        let d = cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: -daysBack, to: base)!)!
        return d.formatted(.iso8601)
    }

    private static func member(_ id: String, _ state: FaceState, _ activity: String? = nil, buttons: [PipButton]? = nil) -> PipMember {
        let (name, solid, colour): (String, FaceSolid, String) = switch id {
        case "otto": ("Otto", .sphere, "#FF7C1A")
        case "inbox": ("Inbox", .roundedCube, "#FABA1E")
        case "code": ("Code", .capsule, "#70BC32")
        case "school": ("School", .gumdrop, "#F06284")
        case "planner": ("Planner", .gem, "#4E80EC")
        case "fares": ("Fares", .diamond, "#1A8E9C")
        default: ("Stays", .drum, "#9656C4")
        }
        return PipMember(id: id, name: name, solid: solid, colour: colour, state: state, activity: activity, buttons: buttons)
    }

    private static func row(_ id: String, _ kind: String, _ name: String, _ members: [PipMember], sender: String, text: String, ts: String, unread: Int = 0, wake: Double? = nil) -> ConversationRow {
        ConversationRow(id: id, kind: kind, name: name, members: members.map(\.id),
                        lastMessage: ConversationPreview(sender: sender, text: text, ts: ts), unread: unread,
                        memberStates: members, activity: members.filter { $0.activity != nil }, nextWakeAt: wake)
    }

    private static let saturdayMembers = [member("planner", .gpt), member("inbox", .rest), member("otto", .rest)]
    private static let lisbonMembers = [member("stays", .working), member("fares", .working, "Comparing Friday fares"), member("planner", .rest), member("otto", .rest)]

    private static var saturday: ConversationRow {
        var r = row("saturday-b", "group", "Saturday plan", saturdayMembers, sender: "inbox", text: "Table for 4 at 7 is booked", ts: at(0, 8, 5))
        if screen == "group" { r.activity = [member("inbox", .working, "Checking the reservation")] }
        return r
    }

    private static var rows: [ConversationRow] {
        let tomorrow7 = cal.date(bySettingHour: 7, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: thursday)!)!.timeIntervalSince1970 * 1000
        var r = [
            row("app", "otto", "Otto", [member("otto", .rest)], sender: "otto", text: "On it.", ts: at(0, 8, 13)),
            row("code", "pip", "Code", [member("code", .needs), member("otto", .rest)], sender: "code", text: "Merge or hold PR #214?", ts: at(0, 8, 12), unread: 1),
            // Group ids chosen so each lands on the mockup's cluster.
            saturday,
            row("inbox", "pip", "Inbox", [member("inbox", .working, "Reading 12 new emails"), member("otto", .rest)], sender: "inbox", text: "Three need replies.", ts: at(0, 8, 4)),
            row("planner", "pip", "Planner", [member("planner", .gpt), member("otto", .rest)], sender: "planner", text: "School didn’t answer", ts: at(0, 7, 40)),
            row("school", "pip", "School", [member("school", .asleep), member("otto", .rest)], sender: "school", text: "The form is due Friday.", ts: at(1, 21, 0), wake: tomorrow7),
            row("release-b", "group", "Release 4.2", [member("code", .needs), member("inbox", .working), member("otto", .rest)], sender: "code", text: "Changelog is ready", ts: at(3, 18, 0)),
            row("porto-b", "group", "Porto weekend", [member("school", .asleep), member("planner", .rest), member("otto", .rest)], sender: "planner", text: "Trains are booked", ts: at(4, 12, 0)),
        ]
        if screen != "conversations" { r.append(row("lisbon-a", "group", "Lisbon in March", lisbonMembers, sender: "stays", text: "Three places in Alfama", ts: at(0, 18, 22))) }
        return r
    }

    private static func say(_ id: String, _ c: String, _ s: String, _ text: String, _ ts: String) -> ConversationMessage {
        ConversationMessage(id: id, conversation_id: c, sender: s, kind: "text", text: text, ts: ts)
    }
    private static func sys(_ id: String, _ c: String, _ text: String, _ ts: String, handoff: String? = nil, pip: String? = nil) -> ConversationMessage {
        ConversationMessage(id: id, conversation_id: c, sender: "otto", kind: "system", text: text, ts: ts, handoff_id: handoff, pip_id: pip)
    }

    private static let histories: [String: [ConversationMessage]] = [
        "saturday-b": [
            say("s1", "saturday-b", "planner", "Rain is gone by Saturday morning.", at(1, 20, 10, real: true)),
            say("s2", "saturday-b", "otto", "Good. I’ll hold the afternoon free.", at(1, 20, 11, real: true)),
            say("s3", "saturday-b", "user", "Plan Saturday: bike repair, groceries, dinner at 7", at(0, 8, 2, real: true)),
            say("s4", "saturday-b", "otto", "Splitting it up. Planner first.", at(0, 8, 3, real: true)),
            say("s5", "saturday-b", "planner", "Bike shop is open 9 to 1. Groceries fit after.", at(0, 8, 5, real: true)),
            sys("s6", "saturday-b", "Planner is on GPT while Claude’s weekly limit is low", at(0, 8, 6, real: true)),
            sys("s7", "saturday-b", "Planner asked Inbox about the dinner booking", at(0, 8, 7, real: true), handoff: "h-dinner"),
            say("s8", "saturday-b", "inbox", "The confirmation is in your email. Table for 4 at 7.", at(0, 8, 8, real: true)),
        ],
        "lisbon-a": [
            sys("l1", "lisbon-a", "Otto started this group", at(0, 18, 21, real: true)),
            sys("l2", "lisbon-a", "Otto made Fares", at(0, 18, 21, real: true), pip: "fares"),
            sys("l3", "lisbon-a", "Otto made Stays", at(0, 18, 21, real: true), pip: "stays"),
            sys("l4", "lisbon-a", "Otto added Planner", at(0, 18, 21, real: true), pip: "planner"),
            say("l5", "lisbon-a", "planner", "You’re free from the 12th to the 16th.", at(0, 18, 22, real: true)),
            say("l6", "lisbon-a", "fares", "Morning flights are cheapest so far. Checking the 12th first.", at(0, 18, 22, real: true)),
            say("l7", "lisbon-a", "stays", "Three places in Alfama under €120 a night, all near the tram.", at(0, 18, 22, real: true)),
        ],
        "code": [say("c1", "code", "code", "Merge or hold PR #214?", at(0, 8, 12, real: true))],
    ]

    private static let handoffs: [PipHandoff] = [
        PipHandoff(id: "h-travel", from: "inbox", to: "planner", conversation: "app", ask: "How long to the dentist on Thursday?", reply: "Leave by 8:50.", status: "answered", askedAt: at(0, 8, 6, real: true), toldOttoAt: at(0, 8, 7, real: true), toldUserAt: at(0, 8, 7, real: true)),
        PipHandoff(id: "h-pr", from: "otto", to: "code", conversation: "app", ask: "Can you review PR #214 before lunch? It renames the settings keys, 3 files.", reply: "Read the diff. Two comments, neither blocks the merge. Tests pass.", status: "answered", askedAt: at(0, 8, 12, real: true), toldOttoAt: at(0, 8, 13, real: true), toldUserAt: at(0, 8, 13, real: true)),
        PipHandoff(id: "h-pr-open", from: "otto", to: "code", conversation: "app", ask: "Can you review PR #214 before lunch?", status: "asked", askedAt: at(0, 8, 12, real: true)),
        PipHandoff(id: "h-dinner", from: "planner", to: "inbox", conversation: "saturday-b", ask: "Is the dinner booking confirmed?", reply: "Table for 4 at 7.", status: "answered", askedAt: at(0, 8, 7, real: true), toldOttoAt: at(0, 8, 8, real: true), toldUserAt: at(0, 8, 8, real: true)),
        PipHandoff(id: "h-form", from: "planner", to: "school", conversation: "app", ask: "When is the trip form due?", status: "failed", askedAt: at(0, 8, 20, real: true), error: "School didn’t wake within 30 seconds, so nothing was sent."),
    ]

    private static func detail(_ id: String) -> PipDetail? {
        guard let m = rows.flatMap(\.memberStates).first(where: { $0.id == id }) else { return nil }
        let monday = cal.nextDate(after: .now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        let isPlanner = id == "planner"
        return PipDetail(
            id: id, name: m.name,
            job: isPlanner ? "Keeps your days, routes and errands in order" : "Otto made this pip for one job",
            description: isPlanner ? "Watches your calendar for trips and errands, plans routes, and tells the other pips when you’ll be out." : "Works on what the group needs and reports back to Otto.",
            solid: m.solid, colour: m.colour, paused: false, state: isPlanner ? .gpt : m.state,
            schedules: isPlanner ? [
                PipSchedule(id: "a", name: "Morning route check", label: "Weekdays 7:30", schedule: "30 7 * * 1-5", tz: "Europe/Lisbon", ask: "Check the route"),
                PipSchedule(id: "b", name: "Weekend plan", label: "Fri 18:00", schedule: "0 18 * * 5", tz: "Europe/Lisbon", ask: "Plan the weekend"),
            ] : [],
            canReach: [.init(id: "calendar", name: "Calendar", sharedWithOtto: true), .init(id: "routes", name: "Places and routes", sharedWithOtto: false)],
            runsOn: .init(model: "gpt-6.1-sol", requestedModel: "gpt-6.1-sol", available: true, reason: "Claude’s weekly limit is low.", claudeReturnsAt: monday.formatted(.iso8601)))
    }

    static func respond(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) -> PipResponse? {
        guard on else { return nil }
        struct Rows: Encodable { let conversations: [ConversationRow] }
        struct Messages: Encodable { let messages: [ConversationMessage] }
        struct Sent: Encodable { let message: ConversationMessage }
        func ok(_ v: some Encodable) -> PipResponse? { (try? JSONEncoder().encode(v)).map { PipResponse(status: 200, data: $0) } }
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        switch (method, parts.dropFirst().first, parts.count) {
        case ("GET", "conversations", 2): return ok(Rows(conversations: rows))
        case ("GET", "conversations", 3) where parts[2] == "search":
            struct Hit: Encodable { let conversation: ConversationRow; let matches: [ConversationMessage] }
            struct Found: Encodable { let results: [Hit] }
            let q = query.first?.value ?? ""
            let hits = rows.compactMap { r -> Hit? in
                let m = (histories[r.id] ?? []).filter { $0.text.localizedCaseInsensitiveContains(q) }
                return r.name.localizedCaseInsensitiveContains(q) || !m.isEmpty ? Hit(conversation: r, matches: m) : nil
            }
            return ok(Found(results: hits))
        case ("GET", "conversations", 4) where parts[3] == "history": return ok(Messages(messages: (histories[parts[2]] ?? []).map { var m = $0; m.read = m.sender == "user" ? true : nil; return m }))
        case ("POST", "conversations", 4) where parts[3] == "messages":
            let f = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: String] ?? [:]
            return ok(Sent(message: ConversationMessage(id: f["id"] ?? "", conversation_id: parts[2], sender: "user", kind: "text", text: f["text"] ?? "", ts: Date.now.formatted(.iso8601))))
        case ("POST", "conversations", 4): return PipResponse(status: 204, data: Data())
        case ("GET", "pips", 3): return detail(parts[2]).flatMap(ok)
        case ("PATCH", "pips", 3):
            var d = detail(parts[2])
            d?.paused = ((try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Bool])?["paused"] ?? false
            return d.flatMap(ok)
        case ("GET", "handoffs", 3): return handoffs.first { $0.id == parts[2] }.flatMap(ok)
        case ("POST", "handoffs", 4): return PipResponse(status: 200, data: Data("{}".utf8))
        default: return PipResponse(status: 404, data: Data())
        }
    }

    // MARK: Otto's thread, per section, and opening it

    private static func t(_ daysBack: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: -daysBack, to: .now)!)!
    }
    private static func line(_ text: String, _ date: Date, handoff: String) -> Message {
        var m = Message(from: .terminal, text: text, date: date, serverID: handoff + text)
        m.pip = "otto"; m.handoffID = handoff
        return m
    }

    @MainActor static func seed(_ store: OttoStore) {
        // `-pipsOpen <id>`: open a conversation against a real server, for end-to-end checks.
        if let i = CommandLine.arguments.firstIndex(of: "-pipsOpen"), i + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[i + 1]
            Task { try? await Task.sleep(for: .seconds(2)); store.pips.open(id) }
        }
        guard on else { return }
        PipClock.fixed = cal.date(bySettingHour: 9, minute: 41, second: 0, of: thursday)
        let me = { (text: String, date: Date) in Message(from: .me, text: text, date: date) }
        let read = { (text: String, date: Date) in Message(from: .me, text: text, date: date, read: true) }
        let otto = { (text: String, date: Date) in Message(from: .otto, text: text, date: date) }
        switch screen {
        case "handoff":
            store.messages = [
                otto("Thursday is the busy one. Dentist at 9:30, then the Q3 review at 2.", t(0, 8, 4)),
                read("Can Code look at the PR?", t(0, 8, 11)),
                line("Otto asked Code about PR #214", t(0, 8, 12), handoff: "h-pr"),
                otto("Code read the diff. Two comments, neither blocks the merge.", t(0, 8, 13)),
            ]
        case "failed":
            store.messages = [
                otto("Thursday is the busy one. Dentist at 9:30, then the Q3 review at 2.", t(0, 8, 18)),
                read("When’s the trip form due?", t(0, 8, 19)),
                otto("Planner is asking School now.", t(0, 8, 19)),
                line("School didn’t answer Planner", t(0, 8, 20), handoff: "h-form"),
            ]
        case "otto-group":
            var link = Message(from: .otto, text: "", date: t(0, 18, 20))
            link.groupLink = GroupLink(id: "lisbon-a", name: "Lisbon in March", members: lisbonMembers, memberList: "Otto, Fares, Stays and Planner")
            store.messages = [
                read("Help me plan Lisbon in March, flights and somewhere to stay", t(0, 18, 20)),
                otto("I started a group for it.", t(0, 18, 20)),
                otto("Fares is on flights and Stays is on places to sleep. Planner is in too, for your calendar.", t(0, 18, 20)),
                link,
            ]
        default:
            store.messages = [
                otto("Your parcel moved to Friday. Nothing to do.", t(1, 17, 52)),
                otto("Morning. Nothing urgent came in overnight.", t(0, 8, 4)),
                me("What’s on this week?", t(0, 8, 4)),
                otto("Thursday is the busy one. Dentist at 9:30, then the Q3 review at 2.", t(0, 8, 5)),
                line("Inbox asked Planner about travel time", t(0, 8, 6), handoff: "h-travel"),
                otto("Planner says leave by 8:50. It’s in your calendar.", t(0, 8, 7)),
                read("Can Code look at the PR before lunch?", t(0, 8, 11)),
                line("Otto asked Code about PR #214", t(0, 8, 12), handoff: "h-pr-open"),
                otto("On it. I’ll tell you when Code replies.", t(0, 8, 12)),
            ]
        }
        Task { await open(store) }
    }

    @MainActor private static func open(_ store: OttoStore) async {
        try? await Task.sleep(for: .seconds(0.6))   // the rows, from run()
        let p = store.pips
        switch screen {
        case "otto", "otto-group": p.open("app")
        case "handoff": p.open("app"); try? await Task.sleep(for: .seconds(1.2)); p.sheet = .handoff("h-pr")
        case "failed": p.open("app"); try? await Task.sleep(for: .seconds(1.2)); p.sheet = .handoff("h-form")
        case "group":
            p.open("saturday-b")
            try? await Task.sleep(for: .seconds(0.8))
            store.demoDraft = "@Inbox forward the booking"
        case "new-group": p.open("lisbon-a")
        case "details": p.open("app"); try? await Task.sleep(for: .seconds(1.2)); p.sheet = .pip("planner")
        default: break
        }
    }
}

/// "The faces" section: every solid in every pose, in cached frames.
struct FaceGrid: View {
    private let solids: [(String, FaceSolid, String)] = [
        ("Otto", .sphere, "#FF7C1A"), ("Inbox", .roundedCube, "#FABA1E"), ("Code", .capsule, "#70BC32"), ("School", .gumdrop, "#F06284"),
        ("Planner", .gem, "#4E80EC"), ("Fares", .diamond, "#1A8E9C"), ("Stays", .drum, "#9656C4"),
    ]
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 56, height: 1)
                ForEach(FaceState.allCases, id: \.self) { s in Text(s.rawValue).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            ForEach(solids, id: \.0) { name, solid, colour in
                HStack(spacing: 0) {
                    Text(name).font(.system(size: 13, weight: .semibold)).frame(width: 56, alignment: .leading)
                    ForEach(FaceState.allCases, id: \.self) { s in
                        FaceView(look: FaceLook(solid: solid, colour: colour, state: s), size: 46).frame(width: 46, height: 46).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
#endif
