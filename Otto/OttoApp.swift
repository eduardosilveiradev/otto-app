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
            if p == .background { Notifier.scheduleRefresh() }
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

    private func armTypingTimeout() {
        typingTimeout?.cancel()
        typingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            if !Task.isCancelled { self?.ottoTyping = false }
        }
    }
    @ObservationIgnored private var typingTimeout: Task<Void, Never>?
    /// Off for the first load so the saved thread appears at once instead of popping in.
    var animated = false
    /// Otto sleeps while the server is unreachable or inside quiet hours.
    var asleep = false
    var connected = false
    /// The message a swipe picked to answer; the composer shows it until you send or cancel.
    var replyingTo: Message.ID?

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

    private func save() {
        try? JSONEncoder().encode(messages).write(to: file, options: .atomic)
    }

    /// Quiet hours as minutes after midnight (Settings writes these). Defaults match
    /// the server's 23:30–08:00; they don't sync from it.
    static var quietStart: Int { UserDefaults.standard.object(forKey: "quietStart") as? Int ?? 23 * 60 + 30 }
    static var quietEnd: Int { UserDefaults.standard.object(forKey: "quietEnd") as? Int ?? 8 * 60 }

    static func inQuietHours(_ now: Date = .now) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        let m = c.hour! * 60 + c.minute!
        let (s, e) = (quietStart, quietEnd)
        return s <= e ? (m >= s && m < e) : (m >= s || m < e)   // a window may wrap midnight
    }

    /// isLive isn't observable and quiet hours move with the clock, so re-read both every second.
    private func tick() async {
        var seen = backend.connections
        while !Task.isCancelled {
            let live = backend is MockBackend || backend.isLive
            // A reconnect is when replies sent into a socket iOS had frozen go missing; catch up.
            // Counted, not sampled: the drop usually lasts under a second and a 1s tick misses it.
            if backend.connections != seen {
                seen = backend.connections
                if animated { Task { await catchUp(notify: !foreground) } }
                Task { await resendPending() }
            }
            if live != connected { connected = live }
            let sleep = !live || Self.inQuietHours()
            if sleep != asleep { asleep = sleep }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func start() async {
        Task { await tick() }
        #if DEBUG
        // `-seedThread`: a thread with long bubbles, for checking layout without a server.
        if ProcessInfo.processInfo.arguments.contains("-seedThread") {
            let long = String(repeating: "this is a long message that should wrap onto several lines. ", count: 6)
            messages = (0..<8).map { Message(from: $0 % 2 == 0 ? .me : .otto, text: $0 == 7 ? "LAST " + long : long) }
        }
        // `-thinking`: Otto stuck mid-reply, for the typing avatar.
        if ProcessInfo.processInfo.arguments.contains("-thinking") { ottoTyping = true; ottoStatus = "Reading ChatView.swift" }
        #endif
        // Anything the server has that's newer than what's saved here, e.g. replies
        // that landed while the app was closed.
        // The mock's canned thread is only a seed for an empty chat.
        let last = messages.last?.date ?? .distantPast
        let fresh = backend is MockBackend && !messages.isEmpty ? []
            : unseen(await backend.history(), after: last)
        if !fresh.isEmpty { messages += fresh }
        animated = true
        Task { await resendPending() }
        brief = await backend.brief()
        Task {
            // Each step is proof Otto is still at it, so it also restarts the timeout.
            for await text in backend.statuses {
                ottoTyping = true
                ottoStatus = text
                armTypingTimeout()
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
                ottoTyping = false
                if let i = messages.firstIndex(where: { $0.wireID == id }) { messages[i].reaction = emoji }
            }
        }
        for await m in backend.incoming {
            ottoTyping = false
            messages.append(m)
            if !foreground && m.from == .otto { Notifier.shared.post(m) }
        }
    }

    /// A background refresh: pull anything newer than what's saved and notify for Otto's.
    func backgroundSync() async { await catchUp(notify: true) }

    /// Otto's replies from the server's history that this phone doesn't have yet.
    /// Only Otto's side: yours are already here, and the server's copy of them is
    /// stamped a moment later, so merging those would show every message twice.
    private func catchUp(notify: Bool) async {
        guard !(backend is MockBackend) else { return }
        let last = messages.last(where: { $0.from == .otto })?.date ?? .distantPast
        let fresh = unseen(await backend.history().filter { $0.from == .otto }, after: last)
        guard !fresh.isEmpty else { return }
        ottoTyping = false
        messages += fresh
        if notify { for m in fresh { Notifier.shared.post(m) } }
    }

    func send(_ text: String) {
        var m = Message(from: .me, text: text, pending: true)
        m.replyTo = replyingTo.flatMap { id in messages.first { $0.id == id }?.wireID }
        replyingTo = nil
        messages.append(m)
        Task { await deliver(m.id) }
    }

    /// Message ids being sent right now, so a reconnect retry can't double-send one.
    private var sending: Set<UUID> = []

    private func deliver(_ id: UUID) async {
        guard !sending.contains(id), let m = messages.first(where: { $0.id == id }), m.pending == true else { return }
        sending.insert(id)
        defer { sending.remove(id) }
        // ponytail: sent-then-killed before this save resends once; dedupe server-side if it shows up.
        if await backend.send(m.text, id: m.wireID, replyTo: m.replyTo), let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].pending = nil
            ottoTyping = true
            ottoStatus = nil   // a new message starts a new reply; the last one's step is stale
        }
    }

    /// Everything still unsent, oldest first. Runs at launch and on every reconnect.
    private func resendPending() async {
        for m in messages where m.pending == true { await deliver(m.id) }
    }

    /// Downscaled to 1600px so the upload is quick and the saved thread stays small.
    func sendPhoto(_ image: UIImage, caption: String = "") {
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.7) else { return }
        let m = Message(from: .me, text: caption, image: jpeg)
        messages.append(m)
        ottoTyping = true
        Task { await backend.sendPhoto(jpeg, caption: caption, id: m.wireID) }
    }

    /// The bubble shows up at once; the transcript fills it in when the server has it.
    func sendVoice(_ file: URL) {
        guard let audio = try? Data(contentsOf: file) else { return }
        try? FileManager.default.removeItem(at: file)
        let m = Message(from: .me, text: "", isVoice: true)
        messages.append(m)
        ottoTyping = true
        Task {
            let text = await backend.sendVoice(audio, id: m.wireID)
            if let i = messages.firstIndex(where: { $0.id == m.id }) {
                messages[i] = Message(id: m.id, from: .me, text: text, date: m.date, isVoice: true)
            }
        }
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
}
