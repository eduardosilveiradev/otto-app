import SwiftUI

// Pinned messages (otto-core's pins.ts): a few of Otto's thread kept at hand, the same on the phone and the Mac.
// The newest shows in a strip under the header; with more than one, its count opens them all in a sheet.

extension Pin {
    /// The Mac keeps this many; pinning one more drops the oldest.
    static let most = 20

    /// One line for the strip, the list and VoiceOver: the message's words, or a word for what it holds.
    static func line(_ m: Message) -> String {
        summary(m).split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// A picture of what it holds, when the phone has one: your photo, or one of Otto's already downloaded.
    @MainActor static func thumbnail(_ m: Message) -> UIImage? {
        if let mine = Thumbs.image(for: m) { return mine }
        guard let f = m.files?.first(where: { $0.kind == "image" }) else { return nil }
        if let hit = decoded.object(forKey: f.id as NSString) { return hit }
        guard let img = MediaCache.data[f.id].flatMap(UIImage.init(data:)) else { return nil }
        decoded.setObject(img, forKey: f.id as NSString)
        return img
    }
    /// Decoded once: the strip is drawn on every pass of the header.
    private static let decoded = NSCache<NSString, UIImage>()

    static func symbol(_ m: Message) -> String {
        if m.isVoice || m.audio != nil { return "waveform" }
        if m.isPhoto { return "photo" }
        if let f = m.files?.first {
            if f.name.lowercased().hasSuffix(".pkpass") { return "wallet.pass" }
            return f.kind == "image" ? "photo" : f.kind == "video" ? "video" : "doc"
        }
        if m.card != nil { return "rectangle.grid.1x2" }
        return "pin.fill"
    }
}

/// Pinning or unpinning that didn't take.
struct PinProblem {
    let title: String
    let message: String
}

extension OttoStore {
    func showPins(_ list: [Pin]) {
        // Every connect and every return to the app reads the list again: unchanged, nothing redraws.
        func key(_ l: [Pin]) -> [String] { l.map { "\($0.id)|\($0.pinnedAt.timeIntervalSince1970)|\($0.message.text)" } }
        guard key(list) != key(pins) else { return }
        withAnimation(UIAccessibility.isReduceMotionEnabled ? .easeOut(duration: 0.2) : .snappy) { pins = list }
    }

    /// GET /app/pins: on coming back to the app, in case a frame was missed.
    func rereadPins() async {
        if case .done(let list) = await backend.pins(nil, on: false) { showPins(list) }
    }

    func pin(_ m: Message) { change(m.wireID, on: true, copy: m) }
    func unpin(_ id: String) { change(id, on: false, copy: nil) }

    /// At once, as the menu closes; the Mac's answer (and the frame it sends every app) then has the last word.
    private func change(_ id: String, on: Bool, copy: Message?) {
        let at = pins.firstIndex { $0.id == id }
        let before = at.map { pins[$0] }
        var list = pins
        if on, let copy {
            // Pinned again: the Mac refreshes its copy and keeps its place.
            if let at { list[at] = Pin(id: id, pinnedAt: list[at].pinnedAt, message: copy) }
            else { list = Array((list + [Pin(id: id, pinnedAt: .now, message: copy)]).suffix(Pin.most)) }
        } else {
            list.removeAll { $0.id == id }
        }
        showPins(list)
        guard !(backend is MockBackend) else { return }   // sample data: pinned here only
        Task {
            let outcome = await backend.pins(id, on: on)
            if case .done(let list) = outcome { showPins(list); return }
            // Only this one goes back: a frame from the Mac may have changed the others meanwhile.
            var now = pins
            if on && before == nil { now.removeAll { $0.id == id } }
            if !on, let before, !now.contains(where: { $0.id == id }) { now.insert(before, at: min(at ?? now.count, now.count)) }
            showPins(now)
            if case .unknown = outcome {
                pinProblem = PinProblem(title: String(localized: "Couldn’t Pin Message"),
                                        message: String(localized: "Your Mac no longer has this message, so it can’t be pinned."))
            } else {
                pinProblem = PinProblem(title: on ? String(localized: "Couldn’t Pin Message") : String(localized: "Couldn’t Unpin Message"),
                                        message: String(localized: "Your Mac didn’t answer. Try again once it’s back."))
            }
        }
    }
}

/// Pin or Unpin, in each of a message's menus and its VoiceOver actions.
struct PinChoice {
    let pinned: Bool
    let toggle: () -> Void
    var label: String { pinned ? String(localized: "Unpin") : String(localized: "Pin") }
    var button: some View { Button(label, systemImage: pinned ? "pin.slash" : "pin", action: toggle) }
}

/// A pinned message's picture, or a symbol for what it holds.
struct PinMark: View {
    let message: Message
    let size: CGFloat
    var body: some View {
        Group {
            if let img = Pin.thumbnail(message) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size / 4, style: .continuous))
            } else {
                Image(systemName: Pin.symbol(message))
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: size, height: size)
                    .background(Color(.tertiarySystemFill), in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Under the header, as the call and flight banners are: the newest pin, and how many there are.
struct PinnedStrip: View {
    let pin: Pin
    let count: Int
    /// The thread's own copy, while it has it: newer than the Mac's (an edit), and your photo is only here.
    let local: Message?
    let open: () -> Void
    let list: () -> Void
    let unpin: () -> Void

    var body: some View {
        let m = local ?? pin.message
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 10) {
                    PinMark(message: m, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pinned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(Pin.line(m)).font(.subheadline).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .padding(.leading, 8).padding(.trailing, count > 1 ? 4 : 14).padding(.vertical, 8)
                .contentShape(.rect)
            }
            .accessibilityLabel("Pinned: \(Pin.line(m))")
            .accessibilityHint(local == nil ? "Opens it" : "Shows it in the conversation")
            if count > 1 {
                Divider().frame(height: 20)
                Button(action: list) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet")
                        Text(count, format: .number).monospacedDigit()
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.leading, 12).padding(.trailing, 16)
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("All pinned messages")
                .accessibilityValue("\(count)")
            }
        }
        .tint(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contextMenu {
            Button("Unpin", systemImage: "pin.slash", action: unpin)
            if count > 1 { Button("All Pinned Messages", systemImage: "list.bullet", action: list) }
        }
        .padding(.horizontal, 16)
    }
}

/// What the pins sheet opens on: the list, or one pin the thread no longer has.
enum PinSheet: Identifiable {
    case all
    case one(String)
    var id: String { if case .one(let p) = self { "one-\(p)" } else { "all" } }
}

/// The sheet, and the alert for a pin that didn't take: off the thread's own modifier chain, which is full.
struct PinsPresenter: ViewModifier {
    @Environment(OttoStore.self) private var store
    @Binding var sheet: PinSheet?
    let messages: [Message]
    let jump: (Message.ID) -> Void
    /// A pin picked in the list, gone to once the sheet is down.
    @State private var landing: Message.ID?

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet, onDismiss: {
                if let id = landing { landing = nil; jump(id) }
            }) { s in
                PinsSheet(start: s, messages: messages) { id in landing = id; sheet = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            #if DEBUG
            // `-pinsOpen all|one`: the list, or the newest pin's page, once the thread is up.
            .task {
                guard let open = UserDefaults.standard.string(forKey: "pinsOpen") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                sheet = open == "one" ? .one("") : .all
            }
            #endif
            .alert(store.pinProblem?.title ?? "", isPresented: Binding(get: { store.pinProblem != nil }, set: { if !$0 { store.pinProblem = nil } }),
                   presenting: store.pinProblem) { _ in
                Button("OK", role: .cancel) {}
            } message: { Text($0.message) }
    }
}

/// Every pin, newest first. One still in the thread is gone to there; one it no longer has opens here.
struct PinsSheet: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let messages: [Message]
    let jump: (Message.ID) -> Void
    @State private var path: [String]

    init(start: PinSheet, messages: [Message], jump: @escaping (Message.ID) -> Void) {
        self.messages = messages
        self.jump = jump
        if case .one(let id) = start { _path = State(initialValue: [id]) } else { _path = State(initialValue: []) }
    }

    private func local(_ id: String) -> Message? { messages.first { $0.wireID == id } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.pins.isEmpty {
                    ContentUnavailableView("No Pinned Messages", systemImage: "pin",
                                           description: Text("Touch and hold a message, then tap Pin."))
                } else {
                    List(store.pins.reversed()) { p in
                        let m = local(p.id) ?? p.message
                        Button {
                            if let l = local(p.id) { jump(l.id) } else { path.append(p.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                PinMark(message: m, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Pin.line(m)).lineLimit(3).foregroundStyle(.primary)
                                    Text("\(m.from == .me ? String(localized: "You") : "Otto") · \(m.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .accessibilityHint(local(p.id) == nil ? "Opens it" : "Shows it in the conversation")
                        .swipeActions(edge: .trailing) {
                            Button("Unpin", systemImage: "pin.slash") { store.unpin(p.id) }.tint(.actionInk)
                        }
                        .contextMenu { Button("Unpin", systemImage: "pin.slash") { store.unpin(p.id) } }
                        .accessibilityAction(named: "Unpin") { store.unpin(p.id) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Pinned")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(for: String.self) { id in
                // "" is `-pinsOpen one`: the newest.
                if let p = id.isEmpty ? store.pins.last : store.pins.first(where: { $0.id == id }) {
                    PinDetail(pin: p) { store.unpin(id); path.removeAll { $0 == id } }
                } else {
                    ContentUnavailableView("Unpinned", systemImage: "pin.slash", description: Text("This message isn’t pinned anymore."))
                }
            }
        }
    }
}

/// A pin the thread no longer has, from the Mac's copy: its words, files and card as they read when it was pinned.
/// The card's buttons are left off: they belonged to that moment.
struct PinDetail: View {
    let pin: Pin
    let unpin: () -> Void

    var body: some View {
        let m = pin.message
        let card: Card? = m.card.flatMap { c in
            guard !c.shown.isEmpty else { return nil }
            var c = c
            c.actions = nil
            return c
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(.secondary)
                if !m.text.isEmpty {
                    Text(Pin.linked(m.text)).textSelection(.enabled).tint(.actionInk)
                }
                ForEach(m.files ?? [], id: \.id) { f in
                    // A photo or video here is to look at: the full-screen viewer only knows the thread's.
                    RemoteFileView(file: f).allowsHitTesting(f.kind != "image" && f.kind != "video")
                }
                if let card { CardView(card: card) { _ in } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle(m.from == .me ? String(localized: "You") : "Otto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Unpin", systemImage: "pin.slash", action: unpin) } }
    }
}

#if DEBUG
extension OttoStore {
    /// `-pins one|many|worst`: pins for screenshots, from the thread a seed laid out (`-demoThread`, `-cardThread`…).
    /// `many` is the Mac's 20; `worst` adds a long unbroken newest pin, and a photo, a card and a PDF the thread no longer has.
    /// `-pinsOpen` opens the list, `-pinsOpen one` the newest pin's own page.
    func seedPins() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-pins"), i + 1 < args.count else { return }
        let kind = args[i + 1]
        let shown = messages.filter { $0.call == nil && $0.from != .terminal && !$0.isConversation && $0.pending != true }
        func pin(_ m: Message, _ minutesAgo: Double) -> Pin { Pin(id: m.wireID, pinnedAt: .now.addingTimeInterval(-minutesAgo * 60), message: m) }
        func gone(_ m: Message, _ id: String) -> Message { var m = m; m.serverID = id; m.date = .now.addingTimeInterval(-9 * 86_400); return m }
        switch kind {
        case "one":
            pins = shown.last { $0.from == .otto && !$0.text.isEmpty }.map { [pin($0, 5)] } ?? []
        case "many":
            let fillers = (0..<Pin.most).map { n in
                gone(Message(from: n % 3 == 0 ? .me : .otto, text: "Pinned note \(n + 1): the gate code for the garage is 4471, the bins go out on Tuesday"), "pin-filler-\(n)")
            }
            pins = (fillers + shown).suffix(Pin.most).enumerated().map { n, m in pin(m, Double(Pin.most - n) * 60) }
        default:
            let card = Card.demoThread("mixed").first { $0.card != nil }.map { gone($0, "pin-card") }
            let photo = gone(Message(from: .otto, text: "", files: [RemoteFile(id: "pin-photo", name: "receipt.jpg", kind: "image")]), "pin-photo")
            let pdf = gone(Message(from: .otto, text: "", files: [RemoteFile(id: "pin-pdf", name: "Rental agreement, signed by both parties, final version (2).pdf", kind: "file")]), "pin-pdf")
            let long = gone(Message(from: .otto, text: "Supercalifragilisticexpialidocious_\(String(repeating: "unbroken", count: 12)) and then\nthe rest of a long note across several lines: the landlord’s number, the meter reading from March, and the wifi password for the flat."), "pin-long")
            pins = ([photo, pdf] + (card.map { [$0] } ?? []) + shown.suffix(2) + [long]).enumerated().map { n, m in pin(m, Double(10 - n)) }
        }
    }
}
#endif
