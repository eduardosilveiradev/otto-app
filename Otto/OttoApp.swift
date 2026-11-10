import MWDATCore
import SwiftUI
import ThinkingOrbsKit

@main
struct OttoApp: App {
    /// Already paired means already set up: an install from before onboarding existed skips it.
    @AppStorage("onboarded") private var onboarded = UserDefaults.standard.string(forKey: "serverURL")?.isEmpty == false

    init() {
        Notifier.shared.register()   // the background task must be registered before launch ends
        Dictation.shared.setUp()     // the keyboard's mic requests arrive any time
        try? Wearables.configure()
        #if DEBUG
        if CommandLine.arguments.contains("-onboarding") { UserDefaults.standard.set(false, forKey: "onboarded") }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // The store is made only once onboarding is over, so it starts on the server just paired.
            Group {
                if onboarded { MainRoot() } else { OnboardingFlow { withAnimation { onboarded = true } } }
            }
            .onOpenURL { url in
                if url.host == "dictate" { Dictation.shared.openedFromKeyboard(); return }
                // Meta AI comes back here after connecting the glasses; anything else isn't the SDK's.
                guard url.query()?.contains("metaWearablesAction") == true else { return }
                Task { _ = try? await Wearables.shared.handleUrl(url) }
            }
            .modifier(DictationCover())
        }
    }
}

private enum PipRootSwitch {
    #if DEBUG
    static let faces = PipFixture.on && PipFixture.screen == "faces"
    #else
    static let faces = false
    #endif
}

private struct MainRoot: View {
    @State private var store = OttoStore.shared
    @Environment(\.scenePhase) private var phase
    /// Offline at launch: stop waiting on the connection and open the chat. 12s, not less: a phone
    /// reaching the Mac through the tunnel can take several seconds, and that is still loading.
    @State private var gaveUp = false
    @State private var splash = Splash.loading
    enum Splash { case loading, loaded, gone }

    private var ready: Bool { store.connected || !store.backend.isLive || gaveUp }

    var body: some View {
        // A ZStack, not a Group: a Group hands its modifiers to whichever child is showing, so the
        // splash timer, the overlay and store.start() were all restarted when the content swapped in.
        ZStack {
            if !ready {
                Color(.systemBackground).task { try? await Task.sleep(for: .seconds(12)); gaveUp = true }
            } else {
                // Up under the status bar: the header's scroll-edge blur then fades the thread out at the
                // screen's edge. Stopped at the safe area, the blurred bubbles were cut off there in a band.
                if PipRootSwitch.faces {
                    #if DEBUG
                    FaceGrid()
                    #endif
                } else if store.pips.active {
                    PipRoot(store: store)
                } else {
                    ChatScreen(store: store).ignoresSafeArea(.keyboard).ignoresSafeArea(.container, edges: .top)
                }
            }
        }
            // Over the content, so it is already laid out underneath when the splash fades.
            .overlay { if splash != .gone { Connecting(loaded: splash == .loaded).transition(.opacity) } }
            .task {
                do {
                    // The reconnecting orb gets at least a second, even on a fast connect, so it reads.
                    try await Task.sleep(for: .seconds(1))
                    while !ready { try await Task.sleep(for: .milliseconds(100)) }
                    // Offline there is nothing loaded to show off: just fade to the single chat.
                    if store.connected {
                        withAnimation(.easeInOut(duration: 0.25)) { splash = .loaded }
                        try await Task.sleep(for: .seconds(1.7))   // the 0.9s morph, then the still globe for 0.8s
                    }
                } catch { return }   // cancelled: leave the splash to whoever runs next
                withAnimation(.easeOut(duration: 0.4)) { splash = .gone }
            }
            .environment(store)
            .task { Notifier.shared.requestPermission(); await store.start() }
            .onChange(of: phase, initial: true) { _, p in
                if store.foreground && p != .active { store.pips.leftApp() }
                store.foreground = p == .active
                if p == .active { store.sendShared(); Notifier.clearAll(); store.resync() }
                if p == .background { store.flush(); Notifier.scheduleRefresh() }
                Grace.update(background: p == .background)
                Keepalive.update(background: p == .background)
            }
    }
}

/// The orb reconnects until the server answers, then holds still on the searching globe once it is
/// in, so the screen says "loaded" for a beat before it fades.
private struct Connecting: View {
    let loaded: Bool

    var body: some View {
        VStack(spacing: 14) {
            // The reconnecting web draws in and the globe blooms out of it, then holds still.
            MorphingOrb(state: loaded ? .searching : .connecting, size: .px64, morph: 0.9, paused: loaded, displaySize: 96)
            Text("Connecting…").font(.footnote).foregroundStyle(.secondary)
                .opacity(loaded ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

@MainActor @Observable
final class OttoStore {
    /// One store for the app, so a background wake-up and a notification reply reach it too.
    /// Real server when Settings has a URL and token; mock data otherwise.
    static let shared = OttoStore(backend: LiveBackend.fromDefaults() ?? MockBackend())

    let backend: OttoBackend
    /// Pips and groups. Empty until the server says there's a second conversation.
    let pips: PipStore
    /// While false, Otto's messages also go out as local notifications.
    var foreground = true
    var messages: [Message] = [] { didSet { save() } }
    var brief: Brief?
    var snooze: Snooze?
    /// A newer build than this one, when the Mac has published it.
    var update: Release?
    /// Dots under the thread while a reply is on its way. Otto may also say nothing at all,
    /// so they give up after three minutes; a real answer can take that long, rarely longer.
    var ottoTyping = false {
        didSet {
            if !ottoTyping { ottoStatus = nil; ottoTodos = [] }
            if ottoTyping && !oldValue { armTypingTimeout() }
        }
    }
    /// The live line inside the dots bubble: the tool Otto is running right now.
    var ottoStatus: String?
    /// Otto's to-do list for this reply, under the live line; empty for most replies.
    var ottoTodos: [TodoItem] = []
    /// Approval screens waiting on you, newest last; `Later` hides one until the next launch.
    var approvals: [ApprovalRequest] = []
    var hiddenApprovals: Set<String> = []
    /// A code that just came in, open in its drawer (OTP.swift); the chip in its bubble reopens it.
    var otpDrawer: Message? = nil
    var shownApproval: ApprovalRequest? { approvals.last { !hiddenApprovals.contains($0.id) } }
    /// The server sends "typing" frames; until one arrives (an older server), the app guesses.
    @ObservationIgnored private var serverTyping = false

    private func armTypingTimeout() {
        typingTimeout?.cancel()
        // Only a safety net once the server reports typing: a lost "off" can't strand the dots.
        let wait: Double = serverTyping ? 900 : 180
        typingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { self?.ottoTyping = false }
        }
    }
    @ObservationIgnored private var typingTimeout: Task<Void, Never>?
    /// Off for the first load so the saved thread appears at once instead of popping in.
    var animated = false
    /// Otto sleeps while the server is unreachable.
    var asleep = false
    var connected = false
    /// The message a swipe picked to answer; the composer shows it until you send or cancel.
    var replyingTo: Message.ID?
    #if DEBUG
    /// `-scriptDemo` types through these, so the real composer shows the words going in.
    var demoDraft: String?
    var demoFocus = false
    #endif

    /// The thread lives on the phone, one file per backend so mock data never mixes
    /// with the real conversation. The server only keeps the last 50.
    private let file: URL

    init(backend: OttoBackend) {
        self.backend = backend
        pips = PipStore(name: backend.name)
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "chat-\(backend.name.lowercased().replacing(" ", with: "-")).json")
        if let data = try? Data(contentsOf: file) {
            if let saved = try? JSONDecoder().decode([Message].self, from: data) { messages = saved }
            // Unreadable (a bad row, a schema it doesn't know): kept aside, not overwritten by the next save.
            else { try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")) }
        }
        pips.store = self   // a background wake or a notification reply can come before start()
    }

    private func checkForUpdate() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fakeUpdate") {
            update = Release(version: "0.1", build: "999", ipa: "https://example.invalid/Otto.ipa", source: "")
            return
        }
        #endif
        let mine = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        guard let r = await backend.release(), r.build.compare(mine, options: .numeric) == .orderedDescending else { return }
        update = r
    }

    /// The thread carries its photos, so encoding it is megabytes of work: never on the main
    /// thread, and once per burst of changes (a send flips pending, read and typing in a row).
    private func save() {
        saving?.cancel()
        generation += 1
        let snapshot = messages, file = file, gen = generation, cursor = syncCursor
        saving = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(snapshot, gen: gen, to: file, cursor: cursor)
        }
    }
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// Bumped per change; a write only lands if nothing newer is already on disk.
    @ObservationIgnored private var generation = 0
    /// How far catch-up has merged the server's history into `messages`. It is stored only by the
    /// write that puts those messages on disk, so a crash can't leave it ahead of the thread.
    @ObservationIgnored private var syncCursor: Date?

    nonisolated private static let disk = DispatchQueue(label: "otto.thread")
    nonisolated(unsafe) private static var committed = 0   // the generation on disk; only touched on `disk`

    /// One write at a time, and never an older snapshot over a newer one: a slow encode that started
    /// before a `saveNow` must not land after it. True when this snapshot (or a newer one) is on disk.
    @discardableResult
    nonisolated private static func write(_ snapshot: [Message], gen: Int, to file: URL, cursor: Date?) -> Bool {
        disk.sync {
            guard gen > committed else { return true }
            // Photos go to their own files; the thread keeps a flag. One whose file can't be written stays inline.
            let lean = snapshot.map { m -> Message in
                guard let jpeg = m.image, ImageStore.save(jpeg, for: m.id) else { return m }
                var c = m; c.image = nil; c.photo = true; return c
            }
            guard let data = try? JSONEncoder().encode(lean), (try? data.write(to: file, options: .atomic)) != nil else { return false }
            committed = gen
            if let cursor { UserDefaults.standard.set(cursor, forKey: "otto.syncedThrough") }
            return true
        }
    }

    /// Writes now, for when the app is about to be suspended and a pending save could be lost.
    func flush() {
        guard Self.disk.sync(execute: { Self.committed }) < generation else { return }   // nothing newer than disk
        saveNow()
    }

    /// Writes the thread now, whatever is pending. False when it didn't make it to disk.
    @discardableResult func saveNow() -> Bool {
        saving?.cancel()
        saving = nil
        generation += 1
        return Self.write(messages, gen: generation, to: file, cursor: syncCursor)
    }

    /// A reply whose voice never came (the server restarted mid-synthesis, so neither the frame nor
    /// history will ever carry it) stops waiting after 90s and stays as plain text.
    private func expireVoiceWaits() {
        let cutoff = Date().addingTimeInterval(-90)
        for i in messages.indices where messages[i].from == .otto && messages[i].isVoice
            && messages[i].audio == nil && messages[i].date < cutoff {
            messages[i].isVoice = false
        }
    }

    /// isLive isn't observable, so re-read it every second.
    private func tick() async {
        var seen = backend.connections
        var n = 0
        while !Task.isCancelled {
            n += 1
            var live = backend is MockBackend || backend.isLive
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-offline") { live = false }   // the disconnected UI, in the simulator
            #endif
            // A reconnect is when replies sent into a socket iOS had frozen go missing; catch up.
            // Counted, not sampled: the drop usually lasts under a second and a 1s tick misses it.
            if backend.connections != seen {
                seen = backend.connections
                if animated { Task { await catchUp(notify: !foreground) } }
                Task { await resendPending() }
                Task { await reportHealth("connect") }
                Task { await pips.reconnected() }
            }
            expireVoiceWaits()
            markUndelivered()
            // An approval past its time is gone on the Mac too: off the screen, unless it's showing its receipt.
            let lapsed = { (a: ApprovalRequest) in !self.keptApprovals.contains(a.id) && (LiveBackend.date(a.expires).map { $0 < .now } ?? false) }
            if approvals.contains(where: lapsed) { approvals.removeAll(where: lapsed) }
            // An ack that never came on a socket that still looks fine: try again every 15s.
            if live && n % 15 == 0 { Task { await resendPending() } }
            if live != connected { connected = live }
            if !live != asleep { asleep = !live }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func start() async {
        Task { await tick() }
        Task { await pips.run() }
        reconcileDesktop()
        if let sync = backend.desktopSync {
            Task { for await _ in sync.updates { reconcileDesktop(); saveNow() } }
        }
        #if DEBUG
        PipFixture.seed(self)
        // `-seedThread`: a thread with long bubbles (and a link), for checking layout without a server.
        if ProcessInfo.processInfo.arguments.contains("-seedThread") {
            let long = String(repeating: "this is a long message that should wrap onto several lines. ", count: 6)
            messages = (0..<8).map { Message(from: $0 % 2 == 0 ? .me : .otto, text: $0 == 7 ? "LAST https://www.ovs.it and https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=1234567890&scope=openid " + long : long) }
            messages.insert(Message(from: .terminal, text: "check why the dashboard build fails…"), at: 6)
        }
        // `-mediaThread`: three photos, for the media viewer.
        if ProcessInfo.processInfo.arguments.contains("-mediaThread") {
            messages = [UIColor.systemOrange, .systemTeal, .systemPurple].enumerated().map { i, c in
                let img = UIGraphicsImageRenderer(size: CGSize(width: 600, height: i == 1 ? 900 : 450)).image { ctx in c.setFill(); ctx.fill(ctx.format.bounds) }
                return Message(from: .me, text: "photo \(i + 1)", image: img.jpegData(compressionQuality: 0.8))
            }
        }
        // `-scheduleThread`: a reply carrying a schedule chip, against MockBackend's triggers.
        if ProcessInfo.processInfo.arguments.contains("-scheduleThread") {
            messages = [
                Message(from: .me, text: "fix the voice thing at 3am while i'm sleeping", read: true),
                Message(from: .otto, text: "on it. it runs at 3, and you'll get one line on it in the morning.", scheduled: [MockBackend.triggers[0]]),
                Message(from: .otto, text: "logged it, and the race is in your spending.",
                        recorded: [RecordedCard(kind: "money", id: "m1", title: "€49.80 · E-MOTION Roma", detail: "fun · 2026-10-31", body: "This month at E-MOTION Roma: €49.80 (1)", action: nil),
                                   RecordedCard(kind: "loop", id: "n1", title: "Book the next sim session", detail: "Due 2026-11-07", body: nil, action: .init(label: "Done", data: "close loop n1"))]),
                Message(from: .otto, text: "saved all three.",
                        recorded: [RecordedCard(kind: "memory", id: "claude-plan", title: "Stay on Max 5x until Desk launches", detail: "Remembered", body: "Upgrade to Ultra when Desk starts selling, for the API credits.", action: .init(label: "Forget it", data: "forget memory claude-plan")),
                                   RecordedCard(kind: "place", id: "p1", title: "E-MOTION Roma", detail: "loved · Rome", body: "the sim rigs", action: nil),
                                   RecordedCard(kind: "write", id: "w1", title: "Sim racing, Sat 7 Nov 12:00", detail: "Calendar", body: "Undo: delete the event", action: .init(label: "Undo it", data: "undo write w1"))]),
                Message(from: .otto, text: "here, one per seat.",
                        files: [RemoteFile(id: "demo-pass-1", name: "Pass_1.pkpass", kind: "file"), RemoteFile(id: "demo-pass-2", name: "Pass_2.pkpass", kind: "file")]),
            ]
        }
        // `-cardThread [types]`: Otto's cards, one per block type (Cards.swift).
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-cardThread") {
            let args = ProcessInfo.processInfo.arguments
            messages = Card.demoThread(i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : nil)
        }
        // `-paymentDemo`: a payment confirmation up over the thread.
        if ProcessInfo.processInfo.arguments.contains("-paymentDemo") {
            approvals = [ApprovalRequest(id: "demo-pay", title: "Pay 17.00 EUR", summary: "Multisala Lux Roma", files: [], branch: nil, stat: nil, expires: nil,
                payment: .init(merchant: "Multisala Lux Roma", site: "lux.cdr.18tickets.it",
                               items: [.init(name: "Primetime ticket", detail: "Sun 1 Nov 17:50 · Sala 6 · E4", quantity: 1, unit: 8.5),
                                       .init(name: "Primetime ticket", detail: "Sun 1 Nov 17:50 · Sala 6 · E5", quantity: 1, unit: 8.5)],
                               total: 17, currency: "EUR", method: "Link card ending 6983",
                               notes: ["No refunds on cinema tickets", "Seats held until 16:14"], test: nil))]
        }
        // `-otpDemo`: a code arriving, drawer open, for screenshots.
        if ProcessInfo.processInfo.arguments.contains("-otpDemo") {
            let m = Message(from: .otto, text: "Clerk code", serverID: "demo-otp", otp: .init(code: "482915", sender: "Clerk"))
            messages.append(m); otpDrawer = m
        }
        // `-demoThread`: the conversation the website shows, for screen recordings.
        if ProcessInfo.processInfo.arguments.contains("-demoThread") {
            messages = [
                Message(from: .otto, text: "morning. design review at 14:00, then you're free until 16:30. enel bill, €112, due friday. and it's thursday, so: the boiler"),
                Message(from: .me, text: "can you tell the landlord tuesday morning works for the boiler guy", read: true),
                Message(from: .otto, text: "draft:\n\"Hi, Tuesday morning works for the boiler service. I'll be home from 9. Thanks!\"",
                        buttons: [ActionButton(label: "send ✓", data: "send"), ActionButton(label: "discard", data: "discard")]),
                Message(id: UUID(uuidString: "0D0D0D0D-0000-4000-8000-000000000001")!, from: .me, text: "remind me to call the plumber when I'm home, and is tuesday free for the dentist", isVoice: true, read: true),
                Message(from: .otto, text: "plumber reminder set for when you're home. tuesday after 16:00 is free.", isVoice: true,
                        audio: RemoteFile(id: "demo-voice", name: "reply.m4a", kind: "audio")),
                Message(from: .me, text: "whats a good place for dinner near the office thats not pizza", read: true),
            ]
        }
        // `-actionsLab`: one of everything a bubble's actions touch (long text, a photo, voice notes,
        // a link, a reply, tapbacks either way); Otto tapbacks your last text 8s in, to land mid-gesture.
        if ProcessInfo.processInfo.arguments.contains("-actionsLab") {
            let t = Date.now.addingTimeInterval(-300)
            let photo = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 450)).jpegData(withCompressionQuality: 0.8) { ctx in
                UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 450))
                UIColor.systemOrange.setFill(); ctx.fill(CGRect(x: 0, y: 300, width: 600, height: 150))
            }
            let first = Message(from: .otto, text: "morning. design review at 14:00, then you're free until 16:30.", date: t, serverID: "lab-1")
            messages = [
                first,
                Message(from: .me, text: "nice. what's the plan for the boiler?", date: t, read: true, replyTo: "lab-1"),
                Message(from: .otto, text: String(repeating: "Here's the long version, every step spelled out so nothing gets lost between now and Tuesday. ", count: 14), date: t),
                Message(from: .me, text: "", date: t, image: photo, reaction: "❤️", read: true),
                Message(from: .otto, text: "plumber reminder set for when you're home.", date: t, isVoice: true,
                        audio: RemoteFile(id: "demo-voice", name: "reply.m4a", kind: "audio")),
                Message(from: .otto, text: "the menu's here: https://www.apple.com/newsroom/", date: t, reaction: "👍"),
                Message(from: .me, text: "ok", date: t, read: true),
                Message(from: .me, text: "and can you book the 19:30 table for two?", date: t, read: true),
            ]
            // `-farQuote`: 70 messages between the reply and what it quotes, past the first page.
            if ProcessInfo.processInfo.arguments.contains("-farQuote") {
                messages.insert(contentsOf: (0..<70).map { Message(from: $0 % 2 == 0 ? .otto : .me, text: "filler \($0)", date: t, read: true) }, at: 1)
            }
            Task {
                // `-labReactAt <s>` moves it, to land inside a recorded gesture.
                let at = UserDefaults.standard.double(forKey: "labReactAt")
                try? await Task.sleep(for: .seconds(at > 0 ? at : 8))
                if let i = messages.lastIndex(where: { $0.from == .me }) { messages[i].reaction = "😂" }
            }
        }
        // `-refThread`: the bubbles of a Messages reference screenshot, to compare pixel for pixel.
        if ProcessInfo.processInfo.arguments.contains("-refThread") {
            let t = Date.now.addingTimeInterval(-120)
            messages = [
                Message(from: .otto, text: "you're basically reading my baby photos", date: t),
                Message(from: .me, text: "how do you handoff work between the conversation agent and the work agent", date: t, read: true),
                Message(from: .otto, text: "brother you are really obsessed with the backend today", date: t),
                Message(from: .otto, text: "externally there is no handoff, i'm just poke doing stuff in the cloud", date: t),
                Message(from: .otto, text: "if you want to build multi-agent setups yourself though, cognition and devin are hiring, or go play around at", date: t),
                Message(from: .me, text: "i'm building a clone of u. basically ur son but OSS", date: t),
                Message(from: .otto, text: "proud father moment i guess, just don't teach him my bad habitshonestly though, building always-on agents over messaging is fun until you hit carrier rate limits and weird bubble parsinggood luck with the repo, let me know when you need your dad to star it on github", date: t),
            ]
            // `-longRef`: the same exchange many times over, for a thread longer than one page.
            if ProcessInfo.processInfo.arguments.contains("-longRef") {
                messages = (0..<12).flatMap { _ in messages.map { var m = $0; m.id = UUID(); return m } }
            }
            // `-autoSend`: open the keyboard and send through the real path, to record the send.
            if ProcessInfo.processInfo.arguments.contains("-autoSend") {
                Task {
                    try? await Task.sleep(for: .seconds(3)); demoFocus = true
                    try? await Task.sleep(for: .seconds(2)); send("test send")
                }
            }
            // `-shiftLab`: every thing that can move the thread, one at a time, two seconds apart,
            // to record and look for jumps. Each step prints "LAB <seconds> <what>".
            if ProcessInfo.processInfo.arguments.contains("-shiftLab") { Task { await shiftLab() } }
        }
        // `-e2eSend <text>` / `-e2eTapLast`: once connected, send a message or tap the newest button,
        // through the real paths, for the delivery tests against a throwaway server.
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-e2eSend"), i + 1 < ProcessInfo.processInfo.arguments.count {
            let text = ProcessInfo.processInfo.arguments[i + 1]
            Task { try? await Task.sleep(for: .seconds(2)); send(text) }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-e2eWallet"), i + 1 < ProcessInfo.processInfo.arguments.count {
            let amount = ProcessInfo.processInfo.arguments[i + 1]
            Task {
                try? await Task.sleep(for: .seconds(2))
                var intent = LogPayment(); intent.amount = amount; intent.merchant = "E2E Shop"; intent.card = ""
                _ = try? await intent.perform()
            }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-e2eShare"), i + 1 < ProcessInfo.processInfo.arguments.count {
            let text = ProcessInfo.processInfo.arguments[i + 1]
            Task { try? await Task.sleep(for: .seconds(2)); _ = ShareOutbox.put(text: text, jpeg: nil); sendShared() }
        }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-e2eDecide"), i + 1 < ProcessInfo.processInfo.arguments.count {
            let id = ProcessInfo.processInfo.arguments[i + 1]
            Task {
                try? await Task.sleep(for: .seconds(3))
                let outcome = await decide(id, approve: true, keep: true)
                try? "\(outcome)".write(to: .applicationSupportDirectory.appending(path: "e2e-decided"), atomically: true, encoding: .utf8)   // read back by Scripts/delivery-e2e.ts
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-e2eShareLostPhoto") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                _ = ShareOutbox.put(text: "lost photo caption", jpeg: Data([0xFF, 0xD8]))
                // Its JPEG gone before the app drains it.
                if let dir = ShareOutbox.dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in files where f.pathExtension == "jpg" { try? FileManager.default.removeItem(at: f) }
                }
                sendShared()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-e2ePhoto") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in UIColor.systemTeal.setFill(); ctx.fill(ctx.format.bounds) }
                sendPhoto(img, caption: "e2e photo")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-e2eTapLast") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let m = messages.last(where: { !$0.buttons.isEmpty }), let b = m.buttons.first { tap(b, on: m.id) }
            }
        }
        // `-scriptDemo`: a scripted session for the launch film; see scriptDemo().
        if ProcessInfo.processInfo.arguments.contains("-scriptDemo") { Task { await scriptDemo() } }
        // `-thinking`: Otto stuck mid-reply, for the typing avatar.
        if ProcessInfo.processInfo.arguments.contains("-thinking") { ottoTyping = true; ottoStatus = UserDefaults.standard.string(forKey: "thinkingStatus") ?? "Reading ChatView.swift"
            if ProcessInfo.processInfo.arguments.contains("-todos") {
                ottoTodos = [TodoItem(text: "Read the share-sheet code", status: .completed),
                             TodoItem(text: "Echoing shares to the open app", status: .in_progress),
                             TodoItem(text: "Build and push", status: .pending)]
            } }
        #endif
        // Anything the server has that's newer than what's saved here, e.g. replies
        // that landed while the app was closed.
        // The mock's canned thread is only a seed for an empty chat.
        await catchUp(notify: false)
        animated = true
        #if PERFDEMO
        if ProcessInfo.processInfo.arguments.contains("-perfDemo") { Task { await perfDemo() } }
        #endif
        Task { await resendPending() }
        sendShared()
        ShareOutbox.observe(ShareOutbox.ping) { [weak self] in MainActor.assumeIsolated { self?.sendShared() } }
        brief = await backend.brief()
        Task { await checkForUpdate() }
        Task {
            // Each step is proof Otto is still at it, so it also restarts the timeout.
            for await text in backend.statuses {
                ottoTyping = true
                ottoStatus = text
                reconcileVoiceDelivery()
                armTypingTimeout()
            }
        }
        Task {
            for await items in backend.todoLists {
                if !items.isEmpty { ottoTyping = true; reconcileVoiceDelivery(); armTypingTimeout() }
                ottoTodos = items
            }
        }
        Task {
            // The server's word on the dots. Once it has spoken, the guesses below (a reply
            // or a tapback ends them) stop: Otto often answers and then keeps working.
            for await on in backend.typing {
                serverTyping = true
                ottoTyping = on
                if on { reconcileVoiceDelivery(); armTypingTimeout() }
            }
        }
        Task {
            for await u in backend.approvalUpdates {
                switch u {
                case .show(let a): if !approvals.contains(where: { $0.id == a.id }) { approvals.append(a) }
                // A paid payment stays for its receipt even though the Mac has settled it.
                case .done(let id): if !keptApprovals.contains(id) { approvals.removeAll { $0.id == id } }
                }
            }
        }
        Task {
            for await ids in backend.reads {
                for id in ids {
                    if let i = messages.firstIndex(where: { $0.wireID == id }) {
                        messages[i].read = true
                        messages[i].pending = nil
                        messages[i].failed = nil
                    }
                }
            }
        }
        Task {
            for await (id, audio) in backend.voices {
                guard let i = messages.firstIndex(where: { $0.wireID == id }) else { continue }
                messages[i].audio = audio
                messages[i].isVoice = audio != nil
            }
        }
        Task {
            // A focused desktop let go: one banner for what it held. Those messages are already in the thread.
            for await (id, text) in backend.notifies where !foreground {
                guard backend.desktopSync?.snapshot.read.contains(id) != true else { continue }
                Notifier.shared.post(title: "Otto", body: text, thread: "otto", id: id)
            }
        }
        Task {
            for await (id, text) in backend.edits {
                if let i = messages.firstIndex(where: { $0.wireID == id }) { messages[i].text = text; messages[i].otp = nil }
                if otpDrawer?.wireID == id { otpDrawer = nil }
            }
        }
        Task {
            for await (id, emoji) in backend.reactions {
                // A tapback can be Otto's whole answer, so it ends the typing dots too.
                if !serverTyping { ottoTyping = false }
                if let i = messages.firstIndex(where: { $0.wireID == id }) {
                    messages[i].reaction = emoji
                    if messages[i].from == .me { messages[i].pending = nil; messages[i].failed = nil }
                }
            }
        }
        for await m in backend.incoming {
            if !serverTyping && m.from == .otto { ottoTyping = false }
            // A reply held for a closed app is in /app/history too: a fresh launch reads
            // history first, then the socket flushes the held copy.
            guard !messages.contains(where: { $0.wireID == m.wireID }) else { continue }
            messages.append(m)
            reconcileDesktop()
            if m.otp != nil { otpDrawer = m }
            if !foreground && m.from == .otto && m.quiet != true && backend.desktopSync?.snapshot.read.contains(m.wireID) != true { Notifier.shared.post(m) }
        }
    }

    #if PERFDEMO
    /// `-perfDemo` in a build with `-DPERFDEMO`: sends, typing steps, tapbacks and replies
    /// in a loop, then prints how many frames ran late. Release config, so the numbers mean something.
    private func perfDemo() async {
        let frames = FrameClock()
        try? await Task.sleep(for: .seconds(2))
        frames.reset()
        for i in 0..<15 {
            send("perf \(i)")
            try? await Task.sleep(for: .milliseconds(500))
            for s in ["Reading mail", "Searching the web", "Writing"] {
                ottoStatus = s
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let id = messages.dropLast(4).last?.id { react("❤️", on: id) }
            try? await Task.sleep(for: .milliseconds(400))
            ottoTyping = false
            messages.append(Message(from: .otto, text: "reply \(i), see https://example.com/page/\(i)"))
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("PERF late=\(frames.late) of \(frames.count) frames, worst \(Int(frames.worst * 1000))ms, lost \(Int(frames.lost * 1000))ms")
    }
    #endif

    #if DEBUG
    /// `-scriptDemo`: one continuous session, recorded from the simulator for the launch film.
    /// Everything goes straight into the thread, never through the backend, so the mock's
    /// canned "(mock) …" replies can't appear. Timings are tuned for a ~40 s take.
    private func shiftLab() async {
        let t0 = Date.now
        func step(_ what: String, _ f: () -> Void) async {
            try? await Task.sleep(for: .seconds(2))
            print(String(format: "LAB %.2f %@", Date.now.timeIntervalSince(t0), what)); fflush(stdout)
            f()
        }
        await step("keyboard open") { demoFocus = true }
        await step("send") { send("one") }
        await step("typing on") { ottoTyping = true; ottoStatus = "Reading" }
        await step("status change") { ottoStatus = "Searching mail for the receipt" }
        await step("todos appear") { ottoTodos = [TodoItem(text: "Find the receipt", status: .completed), TodoItem(text: "Log it", status: .in_progress), TodoItem(text: "Tell them", status: .pending)] }
        await step("otto message while typing") { messages.append(Message(from: .otto, text: "found it, €17 at lux")) }
        await step("second otto message while typing") { messages.append(Message(from: .otto, text: "logged")) }
        await step("todos cleared") { ottoTodos = [] }
        await step("typing off") { ottoTyping = false; ottoStatus = nil }
        await step("reaction on mine") { if let m = messages.last(where: { $0.from == .me }) { react("❤️", on: m.id) } }
        await step("read receipt") { if let i = messages.lastIndex(where: { $0.from == .me }) { messages[i].read = true } }
        await step("keyboard close") { demoFocus = false }
        await step("otto message, idle") { messages.append(Message(from: .otto, text: "anything else?")) }
        await step("typing on, idle") { ottoTyping = true; ottoStatus = "Thinking" }
        await step("otto message replaces dots") { ottoTyping = false; ottoStatus = nil; messages.append(Message(from: .otto, text: "done")) }
        await step("end") {}
    }

    private func scriptDemo() async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func type(_ text: String) async {
            demoFocus = true
            await wait(0.6)
            var typed = ""
            for c in text {
                typed.append(c)
                demoDraft = typed
                // a little human unevenness: faster mid-word, a beat after spaces
                await wait(c == " " ? 0.11 : Double.random(in: 0.045...0.08))
            }
            await wait(0.45)
        }
        func sendTyped(_ text: String) {
            demoDraft = ""
            messages.append(Message(from: .me, text: text, read: true))
        }
        func think(_ steps: [String], each: Double = 1.1) async {
            ottoTyping = true
            for s in steps { ottoStatus = s; await wait(each) }
        }
        func say(_ text: String, buttons: [ActionButton] = []) {
            ottoTyping = false
            messages.append(Message(from: .otto, text: text, buttons: buttons))
        }

        messages = [Message(from: .otto, text: "morning. dentist at 15:00, then you're free. enel bill, €112, due friday. and it's thursday, so: the boiler",
                            date: Date().addingTimeInterval(-7 * 3600))]
        await wait(2.5)

        let ask = "can you tell the landlord tuesday morning works for the boiler guy"
        await type(ask); sendTyped(ask)
        await wait(0.5)
        await think(["Reading your mail", "Finding the landlord's thread", "Writing"])
        say("draft:\n\"Hi, Tuesday morning works for the boiler service. I'll be home from 9. Thanks!\"",
            buttons: [ActionButton(label: "send ✓", data: "send"), ActionButton(label: "discard", data: "discard")])
        demoFocus = false
        await wait(2.8)

        // the tap on "send ✓": buttons go, the label lands as your reply, like the real tap()
        if let i = messages.lastIndex(where: { !$0.buttons.isEmpty }) { messages[i].buttons = [] }
        messages.append(Message(from: .me, text: "send ✓", read: true))
        await wait(0.4)
        await think(["Sending"], each: 1.0)
        say("sent. I'll tell you when they answer.")
        await wait(2.2)

        let ask2 = "and remind me to call the plumber when I'm home"
        await type(ask2); sendTyped(ask2)
        await wait(0.4)
        await think(["Setting a reminder"], each: 1.2)
        say("done. it'll go off when you get home.")
        demoFocus = false
        await wait(3.5)

        // later, unprompted: the reason it exists
        await think(["Reading your mail"], each: 1.4)
        say("landlord replied: tuesday 9 is perfect, he'll let the boiler guy in 👍")
        await wait(4)
    }
    #endif

    /// A background refresh: pull anything newer than what's saved and notify for Otto's.
    /// Also the proof that refresh runs at all, which the server's status shows.
    func backgroundSync() async {
        UserDefaults.standard.set(Date(), forKey: "lastRefresh")
        await catchUp(notify: true, background: true)
        await pips.backgroundCatchUp()
        await reportHealth("refresh")
    }

    /// Live backend only; the mock has nothing to report and older servers answer 404/405, which post() swallows.
    func reportHealth(_ reason: String) async {
        guard let live = backend as? LiveBackend else { return }
        await live.postHealth(await Notifier.health(reason: reason))
    }

    /// Activity has no message id. Check history rather than assuming it is about our upload.
    private func reconcileVoiceDelivery() {
        guard voiceReconcile == nil, messages.contains(where: { $0.from == .me && $0.isVoice && $0.pending == true }) else { return }
        voiceReconcile = Task {
            defer { voiceReconcile = nil }
            await catchUp(notify: !foreground)
        }
    }
    @ObservationIgnored private var voiceReconcile: Task<Void, Never>?

    /// The server's history against this thread, matched by id. What isn't here goes in, in its
    /// place by time: Otto's replies that went into a socket iOS had frozen, and yours from
    /// elsewhere (the share sheet, the dashboard). What is here gets what a lost frame carried:
    /// its edit, Otto's tapback, a voice clip, a read receipt, and for one still marked sending,
    /// the fact that the server has it after all.
    /// Back in front: a socket iOS froze in the background looks alive but dropped what was sent into it
    /// (a tapback, an edit, a reply), and no reconnect means no catch-up. One history read fills it in.
    func resync() { Task { await catchUp(notify: false) } }

    private func catchUp(notify: Bool, background: Bool = false) async {
        guard !(backend is MockBackend) else { return }
        var all = await backend.history(background: background, limit: 50, since: nil)
        // Continuous with the last sync only if the page reaches back to it. If even the oldest of the 50
        // is newer, more came in than the page holds (a long time offline): go further back. Anything
        // local in the page (a message just sent) says nothing about what's missing before it.
        let synced = syncCursor ?? UserDefaults.standard.object(forKey: "otto.syncedThrough") as? Date ?? .distantPast
        if let oldest = all.first(where: { $0.patch == nil }), oldest.date > synced, !messages.isEmpty {
            // Everything since the last sync, as far back as the server's history goes; the first sync ever takes 500.
            all = await backend.history(background: background, limit: 500, since: synced == .distantPast ? nil : synced)
        }
        // Stored with the save that writes these messages (see write), never ahead of them.
        if let newest = all.map(\.date).max() { syncCursor = max(newest, synced); save() }
        let lastOtto = messages.last(where: { $0.from == .otto })?.date ?? .distantPast
        let index = Dictionary(messages.indices.map { (messages[$0].wireID, $0) }, uniquingKeysWith: { a, _ in a })
        var fresh: [Message] = []
        for h in all {
            if let kind = h.patch {   // an edit or tapback for a message older than the page
                guard let i = index[h.wireID] else { continue }
                // Otto's tapback, only ever on yours: the one on Otto's is your own, and one you took off stays off.
                if kind == "reaction" { if messages[i].from == .me { messages[i].reaction = h.reaction } } else if messages[i].text != h.text { messages[i].text = h.text; messages[i].otp = nil }
                continue
            }
            guard let i = index[h.wireID] else {
                // Otto's rows from before history carried ids can only be matched by time.
                if h.from == .otto && h.serverID == nil && h.date <= lastOtto.addingTimeInterval(1) { continue }
                fresh.append(h)
                continue
            }
            // Otto's tapbacks, only on yours: the one on Otto's is your own, already here, and one you took off stays off.
            if let r = h.reaction, messages[i].from == .me { messages[i].reaction = r }
            if h.from == .me {
                if messages[i].pending == true || messages[i].failed == true { messages[i].pending = nil; messages[i].failed = nil }
                if messages[i].isVoice && !h.text.isEmpty && h.text != "(voice message)" { messages[i].text = h.text }
                if h.read == true { messages[i].read = true }
            } else if h.from == .otto {
                if messages[i].isVoice && messages[i].audio == nil && h.audio != nil { messages[i].audio = h.audio }
                // History is the latest text; only one cut at its 8000-character cap keeps the longer local copy.
                if messages[i].text != h.text && !(h.text.count >= 8000 && messages[i].text.hasPrefix(h.text)) { messages[i].text = h.text }
            }
        }
        guard !fresh.isEmpty else { reconcileDesktop(); return }
        if !serverTyping && fresh.contains(where: { $0.from == .otto }) { ottoTyping = false }
        for m in fresh { messages.insert(m, at: messages.lastIndex { $0.date <= m.date }.map { $0 + 1 } ?? 0) }
        reconcileDesktop()
        if notify { for m in fresh where m.from == .otto && m.quiet != true && backend.desktopSync?.snapshot.read.contains(m.wireID) != true { Notifier.shared.post(m) } }
    }

    func send(_ text: String, shared: Bool = false, id: UUID = UUID()) {
        var m = Message(id: id, from: .me, text: text, pending: true)
        if shared { m.shared = true }
        m.replyTo = takeReply()
        messages.append(m)
        Task { await deliver(m.id) }
    }

    /// The message a swipe picked, by wire id, used up by whatever the composer sends next.
    func takeReply() -> String? {
        defer { replyingTo = nil }
        return replyingTo.flatMap { id in messages.first { $0.id == id }?.wireID }
    }

    /// For Siri when /app/ask can't be reached: mark it unsent and keep trying until the server has it
    /// or `timeout` runs out. A background launch has no tick loop to retry once the socket comes up.
    /// Left pending on timeout, so the next connection sends it like any other unsent message.
    func sendAndConfirm(_ id: Message.ID, timeout: Duration = .seconds(10)) async -> Bool {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages[i].pending = true
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end, !Task.isCancelled {   // cancelled, the sleep returns at once: no spinning
            await deliver(id)
            if messages.first(where: { $0.id == id })?.pending == nil { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    /// Siri's intents: `mine` goes in the thread, `send` hands it to the server over HTTP (the
    /// socket may not be up in a background launch), and Otto's reply joins the thread, so
    /// opening the app shows both. The socket's copy is deduped by id. Nil when there's no live
    /// server or it can't be reached; `mine` stays either way.
    func siri(_ mine: Message, send: (LiveBackend) async -> LiveBackend.Answer?) async -> LiveBackend.Answer? {
        // Pending until the server has it: iOS can end a background intent mid-request, and the
        // saved thread must then say unsent (and send it later), not look delivered.
        var mine = mine
        mine.pending = true
        messages.append(mine)
        flush()
        defer { flush() }   // a background launch can be suspended before the debounced save
        sending.insert(mine.id)   // the socket's retry waits for this request
        defer { sending.remove(mine.id) }
        guard let live = backend as? LiveBackend, let a = await send(live) else { return nil }
        if let i = messages.firstIndex(where: { $0.id == mine.id }) { messages[i].pending = nil }
        if let r = a.reply, !messages.contains(where: { $0.wireID == r.id }) {
            messages.append(Message(from: .otto, text: r.text, buttons: r.buttons, serverID: r.id))
        }
        return a
    }

    /// Message ids being sent right now, so a reconnect retry can't double-send one.
    private var sending: Set<UUID> = []

    /// Hands one of yours to the server; it stays pending (and is retried) until the server has
    /// it. A resend of one that did get through is harmless: the server dedupes on its id.
    private func deliver(_ id: UUID) async {
        guard !sending.contains(id), let m = messages.first(where: { $0.id == id }), m.pending == true else { return }
        sending.insert(id)
        defer { sending.remove(id) }
        if m.isVoice { return await deliverVoice(m) }
        // A photo whose JPEG is gone has nothing to send: said, rather than sent as its caption alone.
        if m.photo == true && m.imageData == nil { if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].pending = nil; messages[i].failed = true }; return }
        let ok = if let jpeg = m.imageData, m.snap == true, let live = backend as? LiveBackend { await live.snap(jpeg, note: m.text, id: m.wireID) != nil }
            else if let jpeg = m.imageData { await backend.sendPhoto(jpeg, caption: m.text, id: m.wireID, replyTo: m.replyTo, shared: m.shared == true) }
            else if let data = m.tap { await backend.tap(ActionButton(label: m.text, data: data), id: m.wireID, source: m.tapOf) }
            else if let w = m.wallet { await backend.wallet(w, id: m.wireID) }
            else { await backend.send(m.text, id: m.wireID, replyTo: m.replyTo, shared: m.shared == true) }
        guard ok, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].pending = nil
        messages[i].failed = nil
        ottoTyping = true
        ottoStatus = nil   // a new message starts a new reply; the last one's step is stale
    }

    /// "Not delivered", tapped: try now rather than at the next connection.
    func retry(_ id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }), messages[i].pending == true else { return }
        messages[i].failed = nil
        Task { await deliver(id) }
    }

    /// Yours that the server still doesn't have a minute on: "Not delivered", with a retry. They
    /// stay pending, so the next connection still sends them, and the server's ack clears it.
    private func markUndelivered() {
        let cutoff = Date().addingTimeInterval(-60)
        for i in messages.indices where messages[i].pending == true && messages[i].failed != true
            && messages[i].date < cutoff && !sending.contains(messages[i].id) {
            messages[i].failed = true
        }
    }

    /// Whatever the share extension left (see ShareOutbox), sent as if typed here. Runs at
    /// launch, on coming to the front, and the moment the extension pings a running app.
    func sendShared() {
        let draft = replyingTo
        replyingTo = nil   // a share is its own message, not an answer to the one being replied to
        // Each share keeps the id its outbox file was named with, so one handed over twice (the
        // thread didn't save, the files stayed) goes in once; the files go only once the thread is saved.
        let n = ShareOutbox.drain({ id, text, jpeg, photoLost in
            guard !messages.contains(where: { $0.id == id }) else { return }
            if let jpeg, let image = UIImage(data: jpeg) { sendPhoto(image, caption: text, shared: true, id: id) }
            else if photoLost || jpeg != nil {
                // The photo it carried can't be read: shown as yours, not delivered, never sent as its caption alone.
                var m = Message(id: id, from: .me, text: text.isEmpty ? "Photo" : text, shared: true)
                m.failed = true
                messages.append(m)
            }
            else if !text.isEmpty { send(text, shared: true, id: id) }
        }, saved: { saveNow() })
        replyingTo = draft
        if n > 0 { ShareOutbox.post(ShareOutbox.ack) }
    }

    /// Everything still unsent, oldest first. Runs at launch and on every reconnect. A tap older than
    /// ten minutes waits for "Try again": a "send ✓" firing hours later, on a stale draft, is worse than none.
    private func resendPending() async {
        let stale = Date().addingTimeInterval(-600)
        for m in messages where m.pending == true && !(m.tap != nil && m.date < stale) { await deliver(m.id) }
    }

    func hideApproval(_ id: String) { hiddenApprovals.insert(id) }

    /// `keep`: the decision goes out, but the sheet stays up (a payment's receipt) until `closeApproval`.
    /// True once the Mac has the decision. False leaves the approval up: it isn't queued for later,
    /// since a payment approved now shouldn't go through half an hour on, and the Mac shows it again
    /// on the next connect while it's still live.
    func decide(_ id: String, approve: Bool, keep: Bool = false) async -> ApprovalOutcome {
        if keep { keptApprovals.insert(id) }   // before the send: the Mac's "done" can beat its reply
        let outcome = await backend.decide(approval: id, approve: approve)
        if outcome != .done { keptApprovals.remove(id) }
        if outcome == .gone || (outcome == .done && !keep) { approvals.removeAll { $0.id == id } }
        return outcome
    }

    /// A message that can't be sent after all (Siri's saved place, with the Mac out of reach).
    func giveUp(_ id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].pending = nil
        messages[i].failed = true
    }

    func closeApproval(_ id: String) { keptApprovals.remove(id); approvals.removeAll { $0.id == id } }
    @ObservationIgnored private var keptApprovals: Set<String> = []

    /// Downscaled to 1600px so the upload is quick and the saved thread stays small.
    static func jpeg(_ image: UIImage) -> Data? {
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Scale 1: the default format multiplies by the screen scale, which made "1600px" 4800.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return small.jpegData(compressionQuality: 0.7)
    }

    func sendPhoto(_ image: UIImage, caption: String = "", shared: Bool = false, replyTo: String? = nil, id: UUID = UUID()) {
        guard let jpeg = Self.jpeg(image) else { return }
        // Pending like a text: an upload that fails on a weak network is retried, not lost.
        let m = Message(id: id, from: .me, text: caption, image: jpeg, pending: true, shared: shared ? true : nil, replyTo: replyTo)
        messages.append(m)
        ottoTyping = true
        // One after another, so a burst arrives in order with the caption on the last photo.
        let previous = photoUpload
        photoUpload = Task { await previous?.value; await deliver(m.id) }
    }
    @ObservationIgnored private var photoUpload: Task<Void, Never>?

    /// The bubble shows up at once; the transcript fills it in when the server has it.
    /// Pending until the upload lands, so a dropped one (a weak hotspot) is retried on the
    /// next connection instead of vanishing.
    func sendVoice(_ file: URL, replyTo: String? = nil) {
        let m = Message(from: .me, text: "", isVoice: true, pending: true, replyTo: replyTo)
        // Kept so the note plays back from the thread, and so a retry has the audio.
        try? FileManager.default.removeItem(at: VoiceStore.url(m.id))
        guard (try? FileManager.default.moveItem(at: file, to: VoiceStore.url(m.id))) != nil else { return }
        messages.append(m)
        ottoTyping = true
        Task { await deliver(m.id) }
    }

    private func deliverVoice(_ m: Message) async {
        guard let audio = VoiceStore.data(m.id) else {
            // The audio is gone, so there's nothing to retry: say so rather than look delivered.
            if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].pending = nil; messages[i].failed = true }
            return
        }
        let text = await backend.sendVoice(audio, id: m.wireID, replyTo: m.replyTo)
        guard let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        guard let text else {
            // A receipt/history may already have proved delivery while HTTP was still waiting.
            if messages[i].pending == true { messages[i].failed = true }
            await catchUp(notify: !foreground)
            return
        }
        // A deduped response can have no transcript; keep one recovered from history.
        if !text.isEmpty { messages[i].text = text }
        messages[i].pending = nil
        messages[i].failed = nil
    }

    private func reconcileDesktop() {
        guard let state = backend.desktopSync?.snapshot else { return }
        state.apply(to: &messages)
        Notifier.clear(state.notificationIDs(in: messages))
    }

    func tap(_ button: ActionButton, on id: Message.ID) {
        if button.data?.hasPrefix(PipStore.buttonPrefix) == true {   // a pip's: goes back to the pip
            if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].buttons = [] }
            pips.press(button, in: "app")
            return
        }
        // Buttons are one-shot, same as Telegram: strip them once tapped.
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let source = messages[i].wireID
        messages[i].buttons = []
        messages[i].card?.actions = []
        // Kept and retried like a message: a "send ✓" lost in a frozen socket would otherwise look sent.
        let m = Message(from: .me, text: button.label, pending: true, tap: button.data ?? "", tapOf: source)
        messages.append(m)
        saveNow()
        ottoTyping = true
        Task { await deliver(m.id) }
    }

    /// A tapback, iMessage-style: the same emoji again takes it off.
    func react(_ emoji: String, on id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let same = messages[i].reaction == emoji
        messages[i].reaction = same ? nil : emoji
        // ponytail: removal is local only; the server has no "unreact" to pass on (catchUp leaves it off).
        // The id now, not inside the task: a catch-up insert before it runs would shift the index.
        let wire = messages[i].wireID
        if !same { Task { await backend.react(to: wire, emoji: emoji) } }
    }

    func refreshBrief() async { brief = await backend.brief() }

    /// Nil just reads it. Keeps the last known state when the Mac can't be reached.
    func setSnooze(_ change: SnoozeChange?) async {
        if let s = await backend.snooze(change) { snooze = s }
    }
}

#if PERFDEMO
/// Counts frames that arrived later than one refresh interval, for `-perfDemo`.
@MainActor final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private(set) var count = 0, late = 0
    private(set) var worst: CFTimeInterval = 0, lost: CFTimeInterval = 0

    override init() {
        super.init()
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func reset() { count = 0; late = 0; worst = 0; lost = 0; last = 0 }
    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard last > 0 else { return }
        let gap = l.timestamp - last, budget = l.targetTimestamp - l.timestamp
        count += 1
        if gap > budget * 1.5 { late += 1; lost += gap - budget; worst = max(worst, gap) }
    }
}
#endif
