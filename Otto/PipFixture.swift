#if DEBUG
import SwiftUI
import UserNotifications

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

    private nonisolated(unsafe) static var changed: [ConversationRow]?
    private static var rows: [ConversationRow] {
        get { changed ?? seedRows }
        set { changed = newValue }
    }

    private static var seedRows: [ConversationRow] {
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
        if screen == "otto-only" { return r.filter { $0.kind == "otto" } }
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

    private nonisolated(unsafe) static var edited: [String: PipDetail] = [:]

    private static func detail(_ id: String) -> PipDetail? {
        if let e = edited[id] { return e }
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
            runsOn: .init(model: "gpt-6.1-sol", requestedModel: "gpt-6.1-sol", available: true, reason: "Claude’s weekly limit is low.", claudeReturnsAt: monday.formatted(.iso8601)),
            instructions: "Plan around the calendar and warn before anyone has to leave.", tools: ["calendar", "routes"])
    }

    static func respond(_ method: String, _ path: String, query: [URLQueryItem], body: Data?) -> PipResponse? {
        guard on else { return nil }
        struct Rows: Encodable { let conversations: [ConversationRow] }
        struct Messages: Encodable { let messages: [ConversationMessage] }
        struct Sent: Encodable { let message: ConversationMessage }
        func ok(_ v: some Encodable) -> PipResponse? { (try? JSONEncoder().encode(v)).map { PipResponse(status: 200, data: $0) } }
        let parts = path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        // `*-fail`: a server without the sibling job's routes.
        if screen.hasSuffix("-fail"), parts[1] == "groups" || (parts[1] == "pips" && (method != "GET" || parts.last == "tools")) { return PipResponse(status: 404, data: Data()) }
        let f = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any] ?? [:]
        func changeGroup(_ id: String, _ edit: (inout ConversationRow) -> Void) -> PipResponse? {
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return PipResponse(status: 404, data: Data()) }
            edit(&rows[i])
            return ok(rows[i])
        }
        func asMember(_ id: String) -> PipMember? { detail(id).map { PipMember(id: $0.id, name: $0.name, solid: $0.solid, colour: $0.colour, state: .rest) } }
        switch (method, parts.dropFirst().first, parts.count) {
        case ("GET", "pips", 2):
            struct All: Encodable { let pips: [PipDetail] }
            let ids = Set(rows.flatMap(\.members)).subtracting(["otto"]).sorted()
            return ok(All(pips: ids.compactMap(detail)))
        case ("GET", "pips", 3) where parts[2] == "tools":
            struct Tool: Encodable { let id, label: String }
            struct Tools: Encodable { let tools: [Tool] }
            return ok(Tools(tools: [.init(id: "calendar", label: "Calendar"), .init(id: "routes", label: "Places and routes"), .init(id: "web", label: "Web search"), .init(id: "mail", label: "Mail")]))
        case ("POST", "pips", 2):
            guard let template = detail("planner") else { return nil }
            let id = "made-\(rows.count)", name = f["name"] as? String ?? "", solid = FaceSolid(rawValue: f["solid"] as? String ?? "") ?? .gem, colour = f["colour"] as? String ?? ""
            let d = PipDetail(id: id, name: name, job: f["job"] as? String ?? "", description: "", solid: solid, colour: colour, paused: false, state: .rest, schedules: [], canReach: [], runsOn: template.runsOn, instructions: f["instructions"] as? String, tools: f["tools"] as? [String])
            edited[id] = d
            rows.append(row(id, "pip", name, [PipMember(id: id, name: name, solid: solid, colour: colour, state: .rest), member("otto", .rest)], sender: id, text: "Ready when you are.", ts: Date.now.formatted(.iso8601)))
            return ok(d)
        case ("DELETE", "pips", 3):
            rows.removeAll { $0.kind == "pip" && $0.members.contains(parts[2]) }
            for i in rows.indices { rows[i].members.removeAll { $0 == parts[2] }; rows[i].memberStates.removeAll { $0.id == parts[2] } }
            return PipResponse(status: 204, data: Data())
        case ("POST", "groups", 2):
            let name = f["name"] as? String ?? "", members = (f["members"] as? [String] ?? []).compactMap(asMember) + [member("otto", .rest)]
            let r = row("group-\(rows.count)", "group", name, members, sender: "otto", text: "Group started", ts: Date.now.formatted(.iso8601))
            rows.append(r)
            return ok(r)
        case ("PATCH", "groups", 3): return changeGroup(parts[2]) { $0.name = f["name"] as? String ?? $0.name }
        case ("POST", "groups", 4):
            guard let m = asMember(f["pip_id"] as? String ?? "") else { return PipResponse(status: 404, data: Data()) }
            return changeGroup(parts[2]) { $0.members.append(m.id); $0.memberStates.insert(m, at: 0) }
        case ("DELETE", "groups", 5):
            if parts[4] == "otto" { return PipResponse(status: 400, data: Data()) }
            return changeGroup(parts[2]) { r in r.members.removeAll { $0 == parts[4] }; r.memberStates.removeAll { $0.id == parts[4] } }
        case ("DELETE", "groups", 3):
            rows.removeAll { $0.id == parts[2] }
            return PipResponse(status: 204, data: Data())
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
        case ("GET", "conversations", 4) where parts[3] == "history": return ok(Messages(messages: thread(parts[2]).map { var m = $0; m.read = m.sender == "user" ? true : nil; return m }))
        case ("POST", "conversations", 4) where parts[3] == "messages":
            return ok(Sent(message: ConversationMessage(id: f["id"] as? String ?? "", conversation_id: parts[2], sender: "user", kind: "text", text: f["text"] as? String ?? "", ts: Date.now.formatted(.iso8601))))
        case ("POST", "conversations", 4): return PipResponse(status: 204, data: Data())
        case ("GET", "pips", 3): return detail(parts[2]).flatMap(ok)
        case ("PATCH", "pips", 3):
            guard var d = detail(parts[2]) else { return PipResponse(status: 404, data: Data()) }
            d.paused = f["paused"] as? Bool ?? d.paused
            d.name = f["name"] as? String ?? d.name
            d.job = f["job"] as? String ?? d.job
            d.instructions = f["instructions"] as? String ?? d.instructions
            d.solid = (f["solid"] as? String).flatMap(FaceSolid.init(rawValue:)) ?? d.solid
            d.colour = f["colour"] as? String ?? d.colour
            d.tools = f["tools"] as? [String] ?? d.tools
            if let s = f["schedules"] as? [[String: String]] {
                d.schedules = s.enumerated().map { PipSchedule(id: "s\($0)", name: $1["name"] ?? "", label: $1["label"] ?? "", schedule: $1["schedule"] ?? "", tz: $1["tz"] ?? "", ask: $1["ask"] ?? "") }
            }
            edited[parts[2]] = d
            return ok(d)
        case ("GET", "handoffs", 3): return handoffs.first { $0.id == parts[2] }.flatMap(ok)
        case ("POST", "handoffs", 4): return PipResponse(status: 200, data: Data("{}".utf8))
        default: return PipResponse(status: 404, data: Data())
        }
    }

    // MARK: Otto's thread, per section, and opening it

    /// `jump`: enough after the match that it's beyond the page a thread first lays out.
    private static func thread(_ id: String) -> [ConversationMessage] {
        let h = histories[id] ?? []
        guard screen == "jump", let last = h.last else { return h }
        return h + (0..<80).map { say("x\($0)", id, "fares", "Still checking fares, \($0 + 1) of 80.", last.ts) }
    }

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
        // `-pipsSaveDemo <id>`: the editor's save against a real server.
        if let i = CommandLine.arguments.firstIndex(of: "-pipsSaveDemo"), i + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[i + 1], when = ScheduleWhen()
            Task {
                try? await Task.sleep(for: .seconds(2))
                let failure = await store.pips.update(pip: id, PipPatch(name: "Renamed", job: "A new job", schedules: [.init(name: "Check in", label: when.label, schedule: when.cron, tz: "Europe/Lisbon", ask: "Say what changed")]))
                print("PIPTEST save failure=\(failure ?? "none") \(store.pips.details[id]?.schedules.map(\.label) ?? [])")
            }
        }
        guard on else { return }
        if CommandLine.arguments.contains("-pipsNotifyTest") { Task { await notifyTest(store) } }
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
            // What the real server sends: its announcement as the text, and its member line without an "and".
            var link = Message(from: .otto, text: "I started Lisbon in March.", date: t(0, 18, 20))
            link.groupLink = GroupLink(id: "lisbon-a", name: "Lisbon in March", members: lisbonMembers, memberList: "Otto, Fares, Stays, Planner")
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

    /// Real delivery through the real paths: provisional permission needs no tap on an alert.
    /// The caller sends the app to the background during the first sleep.
    @MainActor private static func notifyTest(_ store: OttoStore) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.provisional, .badge])
        center.removeAllDeliveredNotifications()
        try? await Task.sleep(for: .seconds(9))
        let now = Date.now.addingTimeInterval(1).formatted(.iso8601)
        print("PIPTEST foreground=\(store.foreground)")
        store.pips.handle(.message(ConversationMessage(id: "n1", conversation_id: "saturday-b", sender: "planner", kind: "text", text: "Live in a group", ts: now)))
        store.pips.handle(.message(ConversationMessage(id: "n2", conversation_id: "saturday-b", sender: "user", kind: "text", text: "Mine: no banner", ts: now)))
        store.pips.handle(.message(ConversationMessage(id: "n3", conversation_id: "saturday-b", sender: "planner", kind: "text", text: "Replayed: no second banner", ts: now)))
        try? await Task.sleep(for: .seconds(1))
        func delivered() async -> [UNNotification] { await center.deliveredNotifications() }
        print("PIPTEST live delivered=\(await delivered().count)")
        UserDefaults.standard.set(Date(timeIntervalSinceNow: -40 * 86400), forKey: "pips.notifiedThrough")
        await store.pips.backgroundCatchUp()
        try? await Task.sleep(for: .seconds(1))
        let first = await delivered().count
        await store.pips.backgroundCatchUp()
        try? await Task.sleep(for: .seconds(1))
        print("PIPTEST catchup delivered=\(first) again=\(await delivered().count)")
        for n in await delivered().prefix(6) { let c = n.request.content; print("PIPTEST \(c.title) | \(c.body) | \(c.threadIdentifier) | \(c.categoryIdentifier) | \(c.userInfo)") }
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
        case "jump":
            let hit = await p.search("Alfama").first { $0.conversation.id == "lisbon-a" }
            p.open("lisbon-a", at: hit?.matches.last)
        case "group-card", "group-confirm", "group-fail":
            p.open("lisbon-a"); try? await Task.sleep(for: .seconds(1.2)); p.sheet = .group("lisbon-a")
        case "group-changed":
            p.open("lisbon-a")
            let a = await p.renameGroup("lisbon-a", "Lisbon in April")
            let b = await p.addMember("code", to: "lisbon-a")
            let c = await p.removeMember("planner", from: "lisbon-a")
            print("PIPTEST group \([a, b, c])")
            p.sheet = .group("lisbon-a")
        case "gone":
            p.open("lisbon-a")
            let a = await p.deleteGroup("lisbon-a"), b = await p.deletePip("school")
            let n = await p.createPip(PipPatch(name: "Scout", job: "Finds things", instructions: "Look first", solid: .drum, colour: "#9656C4", tools: []))
            let g = await p.createGroup(name: "Weekend crew", members: ["code"]) { print("PIPTEST created \($0)") }
            print("PIPTEST deleted \([a, b]) made \([n, g]) rows \(p.rows.map(\.name)) path \(p.path)")
            p.path = []
        case "details", "edit-pip", "edit-schedule", "pip-confirm": p.open("app"); try? await Task.sleep(for: .seconds(1.2)); p.sheet = .pip("planner")
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
