import SwiftUI

@main
struct OttoApp: App {
    @State private var store = OttoStore.shared
    @Environment(\.scenePhase) private var phase

    init() { Notifier.shared.register() }   // the background task must be registered before launch ends

    var body: some Scene {
        WindowGroup {
            ChatScreen(store: store)
            .ignoresSafeArea(.keyboard)
            .environment(store)
            .task { Notifier.shared.requestPermission(); await store.start() }
        }
        .onChange(of: phase) { _, p in
            store.foreground = p == .active
            if p == .active { store.sendShared() }
            if p == .background { store.flush(); Notifier.scheduleRefresh() }
            Grace.update(background: p == .background)
            Keepalive.update(background: p == .background)
        }
    }
}

@MainActor @Observable
final class OttoStore {
    /// One store for the app, so a background wake-up and a notification reply reach it too.
    /// Real server when Settings has a URL and token; mock data otherwise.
    static let shared = OttoStore(backend: LiveBackend.fromDefaults() ?? MockBackend())

    let backend: OttoBackend
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
            if !ottoTyping { ottoStatus = nil }
            if ottoTyping && !oldValue { armTypingTimeout() }
        }
    }
    /// The live line inside the dots bubble: the tool Otto is running right now.
    var ottoStatus: String?
    /// Approval screens waiting on you, newest last; `Later` hides one until the next launch.
    var approvals: [ApprovalRequest] = []
    var hiddenApprovals: Set<String> = []
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
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appending(path: "chat-\(backend.name.lowercased().replacing(" ", with: "-")).json")
        messages = Self.dedupe((try? JSONDecoder().decode([Message].self, from: Data(contentsOf: file))) ?? [])
    }

    /// Threads saved before history carried ids picked up a second copy of some of your
    /// messages (the server's, stamped a moment later). Drops a text-only copy of the
    /// message just before it.
    private static func dedupe(_ ms: [Message]) -> [Message] {
        var out: [Message] = []
        for m in ms {
            if m.from == .me, m.image == nil, !m.text.isEmpty,
               let prev = out.last(where: { $0.from == .me }), prev.text == m.text,
               m.date.timeIntervalSince(prev.date) < 15 { continue }
            out.append(m)
        }
        return out
    }

    /// What the server has that this phone doesn't. Matched by id; the time rule is for
    /// history written before messages carried one.
    private func unseen(_ history: [Message], after last: Date) -> [Message] {
        let known = Set(messages.map(\.wireID))
        return history.filter { !known.contains($0.wireID) && $0.date > last.addingTimeInterval(1) }
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
        let snapshot = messages, file = file
        saving = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        }
    }
    @ObservationIgnored private var saving: Task<Void, Never>?

    /// Writes now, for when the app is about to be suspended and a pending save could be lost.
    func flush() {
        guard let s = saving, !s.isCancelled else { return }
        s.cancel()
        saving = nil
        try? JSONEncoder().encode(messages).write(to: file, options: .atomic)
    }

    /// isLive isn't observable, so re-read it every second.
    private func tick() async {
        var seen = backend.connections
        while !Task.isCancelled {
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
            }
            if live != connected { connected = live }
            if !live != asleep { asleep = !live }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func start() async {
        Task { await tick() }
        #if DEBUG
        // `-seedThread`: a thread with long bubbles (and a link), for checking layout without a server.
        if ProcessInfo.processInfo.arguments.contains("-seedThread") {
            let long = String(repeating: "this is a long message that should wrap onto several lines. ", count: 6)
            messages = (0..<8).map { Message(from: $0 % 2 == 0 ? .me : .otto, text: $0 == 7 ? "LAST https://www.ovs.it and https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=1234567890&scope=openid " + long : long) }
            messages.insert(Message(from: .terminal, text: "check why the dashboard build fails…"), at: 6)
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
        // `-scriptDemo`: a scripted session for the launch film; see scriptDemo().
        if ProcessInfo.processInfo.arguments.contains("-scriptDemo") { Task { await scriptDemo() } }
        // `-thinking`: Otto stuck mid-reply, for the typing avatar.
        if ProcessInfo.processInfo.arguments.contains("-thinking") { ottoTyping = true; ottoStatus = UserDefaults.standard.string(forKey: "thinkingStatus") ?? "Reading ChatView.swift" }
        #endif
        // Anything the server has that's newer than what's saved here, e.g. replies
        // that landed while the app was closed.
        // The mock's canned thread is only a seed for an empty chat.
        let last = messages.last?.date ?? .distantPast
        let fresh = backend is MockBackend && !messages.isEmpty ? []
            : unseen(await backend.history(), after: last)
        if !fresh.isEmpty { messages += fresh }
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
                armTypingTimeout()
            }
        }
        Task {
            // The server's word on the dots. Once it has spoken, the guesses below (a reply
            // or a tapback ends them) stop: Otto often answers and then keeps working.
            for await on in backend.typing {
                serverTyping = true
                ottoTyping = on
                if on { armTypingTimeout() }
            }
        }
        Task {
            for await u in backend.approvalUpdates {
                switch u {
                case .show(let a): if !approvals.contains(where: { $0.id == a.id }) { approvals.append(a) }
                case .done(let id): approvals.removeAll { $0.id == id }
                }
            }
        }
        Task {
            for await ids in backend.reads {
                for id in ids { if let i = messages.firstIndex(where: { $0.wireID == id }) { messages[i].read = true } }
            }
        }
        Task {
            for await (id, emoji) in backend.reactions {
                // A tapback can be Otto's whole answer, so it ends the typing dots too.
                if !serverTyping { ottoTyping = false }
                if let i = messages.firstIndex(where: { $0.wireID == id }) { messages[i].reaction = emoji }
            }
        }
        for await m in backend.incoming {
            if !serverTyping && m.from == .otto { ottoTyping = false }
            // A reply held for a closed app is in /app/history too: a fresh launch reads
            // history first, then the socket flushes the held copy.
            guard !messages.contains(where: { $0.wireID == m.wireID }) else { continue }
            messages.append(m)
            if !foreground && m.from == .otto { Notifier.shared.post(m) }
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
    func backgroundSync() async { await catchUp(notify: true) }

    /// Otto's replies (and terminal lines) from the server's history that this phone doesn't
    /// have yet. Not yours: they're already here, and the server's copy of them is
    /// stamped a moment later, so merging those would show every message twice.
    private func catchUp(notify: Bool) async {
        guard !(backend is MockBackend) else { return }
        let last = messages.last(where: { $0.from == .otto })?.date ?? .distantPast
        let fresh = unseen(await backend.history().filter { $0.from != .me }, after: last)
        guard !fresh.isEmpty else { return }
        if !serverTyping && fresh.contains(where: { $0.from == .otto }) { ottoTyping = false }
        messages += fresh
        if notify { for m in fresh where m.from == .otto { Notifier.shared.post(m) } }
    }

    func send(_ text: String, shared: Bool = false) {
        var m = Message(from: .me, text: text, pending: true)
        if shared { m.shared = true }
        m.replyTo = replyingTo.flatMap { id in messages.first { $0.id == id }?.wireID }
        replyingTo = nil
        messages.append(m)
        Task { await deliver(m.id) }
    }

    /// For Siri: send, then keep trying until the server has it or `timeout` runs out. A
    /// background launch has no tick loop to retry once the socket comes up. Left pending
    /// on timeout, so the next connection sends it like any other unsent message.
    func sendAndConfirm(_ text: String, timeout: Duration = .seconds(10)) async -> Bool {
        let m = Message(from: .me, text: text, pending: true)
        messages.append(m)
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            await deliver(m.id)
            if messages.first(where: { $0.id == m.id })?.pending == nil { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    /// Message ids being sent right now, so a reconnect retry can't double-send one.
    private var sending: Set<UUID> = []

    private func deliver(_ id: UUID) async {
        guard !sending.contains(id), let m = messages.first(where: { $0.id == id }), m.pending == true else { return }
        sending.insert(id)
        defer { sending.remove(id) }
        if m.isVoice { return await deliverVoice(m) }
        // ponytail: sent-then-killed before this save resends once; dedupe server-side if it shows up.
        if await backend.send(m.text, id: m.wireID, replyTo: m.replyTo, shared: m.shared == true), let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].pending = nil
            ottoTyping = true
            ottoStatus = nil   // a new message starts a new reply; the last one's step is stale
        }
    }

    /// Whatever the share extension left (see ShareOutbox), sent as if typed here. Runs at
    /// launch, on coming to the front, and the moment the extension pings a running app.
    func sendShared() {
        let draft = replyingTo
        replyingTo = nil   // a share is its own message, not an answer to the one being replied to
        let n = ShareOutbox.drain { text, jpeg in
            if let jpeg, let image = UIImage(data: jpeg) { sendPhoto(image, caption: text, shared: true) }
            else if !text.isEmpty { send(text, shared: true) }
        }
        replyingTo = draft
        if n > 0 { ShareOutbox.post(ShareOutbox.ack) }
    }

    /// Everything still unsent, oldest first. Runs at launch and on every reconnect.
    private func resendPending() async {
        for m in messages where m.pending == true { await deliver(m.id) }
    }

    func hideApproval(_ id: String) { hiddenApprovals.insert(id) }

    func decide(_ id: String, approve: Bool) async {
        await backend.decide(approval: id, approve: approve)
        approvals.removeAll { $0.id == id }
    }

    /// Downscaled to 1600px so the upload is quick and the saved thread stays small.
    func sendPhoto(_ image: UIImage, caption: String = "", shared: Bool = false) {
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        // Scale 1: the default format multiplies by the screen scale, which made "1600px" 4800.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.7) else { return }
        let m = Message(from: .me, text: caption, image: jpeg)
        messages.append(m)
        ottoTyping = true
        // One after another, so a burst arrives in order with the caption on the last photo.
        let previous = photoUpload
        photoUpload = Task { await previous?.value; await backend.sendPhoto(jpeg, caption: caption, id: m.wireID, shared: shared) }
    }
    @ObservationIgnored private var photoUpload: Task<Void, Never>?

    /// The bubble shows up at once; the transcript fills it in when the server has it.
    /// Pending until the upload lands, so a dropped one (a weak hotspot) is retried on the
    /// next connection instead of vanishing.
    func sendVoice(_ file: URL) {
        let m = Message(from: .me, text: "", isVoice: true, pending: true)
        // Kept so the note plays back from the thread, and so a retry has the audio.
        try? FileManager.default.removeItem(at: VoiceStore.url(m.id))
        guard (try? FileManager.default.moveItem(at: file, to: VoiceStore.url(m.id))) != nil else { return }
        messages.append(m)
        ottoTyping = true
        Task { await deliver(m.id) }
    }

    // ponytail: a note the server took but whose answer was lost is sent twice; dedupe by id server-side if it shows up.
    private func deliverVoice(_ m: Message) async {
        guard let audio = try? Data(contentsOf: VoiceStore.url(m.id)) else {
            if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].pending = nil }   // the audio is gone; nothing to retry
            return
        }
        guard let text = await backend.sendVoice(audio, id: m.wireID),
              let i = messages.firstIndex(where: { $0.id == m.id }) else { return }
        messages[i] = Message(id: m.id, from: .me, text: text, date: m.date, isVoice: true)
    }

    func tap(_ button: ActionButton, on id: Message.ID) {
        // Buttons are one-shot, same as Telegram: strip them once tapped.
        if let i = messages.firstIndex(where: { $0.id == id }) { messages[i].buttons = [] }
        messages.append(Message(from: .me, text: button.label))
        ottoTyping = true
        Task { await backend.tap(button) }
    }

    /// A tapback, iMessage-style: the same emoji again takes it off.
    func react(_ emoji: String, on id: Message.ID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let same = messages[i].reaction == emoji
        messages[i].reaction = same ? nil : emoji
        // ponytail: removal is local only; the server has no "unreact" to pass on.
        if !same { Task { await backend.react(to: messages[i].wireID, emoji: emoji) } }
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
