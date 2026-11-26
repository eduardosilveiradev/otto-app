import SwiftUI
import UserNotifications
import VisionKit

/// The contact card: what Otto knows about today, and the few settings there are.
struct DetailsView: View {
    /// The header's face, so the one zooming in is the one that was there.
    var look: FaceLook? = nil
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Server URL and token persist (LiveBackend.fromDefaults reads them at launch).
    // Speak-replies, snooze and closed loops live on the Mac.
    @AppStorage("serverURL") private var server = ""
    @AppStorage("serverToken") private var token = ""
    @AppStorage("callNumber") private var callNumber = ""
    /// What a web call needs (CallManager reads them when one starts). Empty, the phone button dials the number above.
    @AppStorage("vapiPublicKey") private var callKey = ""
    @AppStorage("vapiAssistantId") private var callAssistant = ""
    /// Nil until the Mac has said; the switch shows on and stays put until then.
    @State private var speakReplies: Bool?
    /// Keepalive: instant notifications for some battery. Read by Keepalive.enabled.
    @AppStorage("stayAwake") private var stayAwake = true
    @State private var done: Set<Loop.ID> = []
    /// `-screen Money` opens straight onto a page, for screenshots.
    @State private var screen = UserDefaults.standard.string(forKey: "screen")
    /// Set each time the address or token is submitted; the check under the token answers for it.
    @State private var submitted: UUID?
    @State private var serverCheck: ServerCheck?
    /// Whether this phone may show Otto's banners: read on opening and on coming back from Settings.
    @State private var allowed: Notifier.Allowed?
    @Environment(\.scenePhase) private var phase
    /// The pairing link the fields were just filled from, until its check has come back.
    @State private var linked: PairingLink?
    /// The Mac keeps a list of what Otto may do without asking. False until it has answered with one,
    /// so a server from before approval scopes shows no row that leads nowhere.
    @State private var hasRules = false
    /// This Mac has answered for the rules list before: the row stays with the Mac out of reach, since that is
    /// where a lasting yes is taken back (its page shows the kept list, or says it can't reach the Mac).
    @AppStorage("otto.rulesSeen") private var rulesSeen = false
    @State private var scanning = false
    /// A watch is connected on the Mac: only then is there a Health row (most people running this have none).
    @State private var hasHealth = false
    enum ServerCheck: Equatable { case checking, connected, failed(String) }
    #if DEBUG
    /// `-details -checkServer` opens scrolled to the server fields and submits them, for screenshots.
    private let checkOnOpen = ProcessInfo.processInfo.arguments.contains("-checkServer")
    #else
    private let checkOnOpen = false
    #endif

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Group {
                Section {
                    VStack(spacing: 8) {
                        OttoAvatar(size: 78, asleep: store.asleep, pokeable: true, look: look)   // a tap: a hop and a smile, nothing else
                            .background(CardZoom.Mark())
                        Text("Otto").font(.title2.weight(.semibold))
                        // isLive isn't observable, so re-read it every second while the sheet is open.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let line = store.backend is MockBackend ? "Sample data"
                                : store.asleep ? (store.noNetwork ? "Asleep. This phone is offline." : "Asleep. Can’t reach your Mac.") : nil {
                                Text(line).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if let s = store.snooze, let until = s.until, until > .now { snoozed(s, until: until) }

                if let b = store.brief { today(b) }

                Section {
                    NavigationLink { LoopsScreen() } label: { Label("Loops", systemImage: "checklist") }
                    NavigationLink { SchedulesScreen() } label: { Label("Schedules", systemImage: "calendar.badge.clock") }
                    NavigationLink { CallsScreen() } label: { Label("Calls", systemImage: "phone") }
                    NavigationLink { MemoryScreen() } label: { Label("Memory", systemImage: "brain") }
                    NavigationLink { PeopleScreen() } label: { Label("People", systemImage: "person.2") }
                    NavigationLink { MoneyScreen() } label: { Label("Money", systemImage: "creditcard") }
                    if hasHealth {
                        NavigationLink { HealthScreen() } label: { Label("Health", systemImage: "heart") }
                    }
                    NavigationLink { TripsScreen() } label: { Label("Trips", systemImage: "airplane") }
                    NavigationLink { PassportScreen() } label: { Label("Passport", systemImage: "globe.europe.africa") }
                    NavigationLink { PackagesScreen() } label: { Label("Packages", systemImage: "shippingbox") }
                    NavigationLink { ActivityScreen() } label: { Label("Activity", systemImage: "waveform.path.ecg") }
                }
                .labelStyle(PlainIcon())   // glyphs in the text colour: nothing here is an action's blue

                Section {
                    NavigationLink { StatusScreen() } label: { Label("Status", systemImage: "gauge.with.dots.needle.33percent") }
                    NavigationLink { DevicesScreen() } label: { Label("Devices", systemImage: "iphone") }
                    if hasRules || rulesSeen {
                        NavigationLink { RulesScreen() } label: { Label("Allowed without asking", systemImage: "checkmark.shield") }
                    }
                    NavigationLink { GlassesScreen() } label: { Label { Text("Glasses") } icon: { Image(systemName: "eyeglasses").imageScale(.small) } }
                }
                .labelStyle(PlainIcon())

                Section {
                    if store.snooze?.until.map({ $0 > .now }) != true {
                        Menu("Snooze notifications") {
                            ForEach([1, 2, 4], id: \.self) { h in
                                Button("\(h) hour\(h == 1 ? "" : "s")") { Task { await store.setSnooze(.minutes(h * 60)) } }
                            }
                        }
                    }
                    // Only once the server has said: a guessed "on" that can't be changed is worse than no row.
                    if let speak = speakReplies {
                        Toggle("Speak replies when I speak", isOn: Binding(
                            get: { speak },
                            set: { on in
                                speakReplies = on
                                Task { speakReplies = await store.backend.speakReplies(set: on) ?? !on }
                            }))
                    }
                    Toggle("Stay connected in background", isOn: $stayAwake)
                    // Off or never asked (onboarding's "Not now"): said here, with the way to turn them on. Only
                    // ever on this tap: the system's prompt is never thrown up unasked.
                    if let allowed, allowed != .yes {
                        VStack(alignment: .leading, spacing: 4) {
                            Button(allowed == .no ? "Turn On Notifications in Settings" : "Turn On Notifications") {
                                Task {
                                    if allowed == .no, let url = URL(string: UIApplication.openNotificationSettingsURLString) { await UIApplication.shared.open(url) }
                                    else { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                                    self.allowed = await Notifier.allowed()
                                }
                            }
                            Text("They’re off, so this phone can’t alert you itself: reminders and approvals reach you only through Bark, if your Mac has it set up.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    NavigationLink("Settings") { SettingsView() }
                }
                .task(id: phase) { allowed = await Notifier.allowed() }

                Section {
                    labeled("Server address") {
                        TextField("Server address", text: $server, prompt: Text(verbatim: "https://your-mac.your-tailnet.ts.net"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .onSubmit { submitted = UUID() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        labeled("App token") {
                            // A one-time code field, so iOS offers a code it sees in Messages. The token isn't numeric: default keyboard.
                            SecureField("App token", text: $token, prompt: Text(verbatim: ""))
                                .textContentType(.oneTimeCode)
                                .onSubmit { submitted = UUID() }
                        }
                        if let serverCheck { checkLine(serverCheck) }
                    }
                    .id("server")
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        Button("Scan a pairing code", systemImage: "qrcode.viewfinder") { scanning = true }
                    }
                    labeled("Otto’s phone number") {
                        TextField("Otto’s phone number", text: $callNumber, prompt: Text(verbatim: "+1 555 0100")).keyboardType(.phonePad)
                    }
                } header: { Text("Server") } footer: {
                    Text("Over Tailscale. Paste a pairing link into the address to fill both. Quit and reopen the app after changing these.")
                }

                .listRowInsets(.vertical, 10)   // 20 between fields
                .onChange(of: server) {
                    // A pairing link pasted into the address is the whole pairing: both fields, then the check.
                    if let link = PairingLink(server) { apply(link); return }
                    if linked?.server == server { return }   // just filled from a link: its check is on its way
                    submitted = nil; serverCheck = nil
                }
                .onChange(of: token) { if linked?.token == token { return }; submitted = nil; serverCheck = nil }
                .task(id: submitted) { if submitted != nil { await checkServer() } }

                Section {
                    labeled("Vapi public key") {
                        TextField("Vapi public key", text: $callKey, prompt: Text(verbatim: "from your Vapi dashboard"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    labeled("Vapi assistant ID") {
                        TextField("Vapi assistant ID", text: $callAssistant, prompt: Text(verbatim: "the assistant that answers as Otto"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("Calls in the app") } footer: {
                    Text(callKey.isEmpty || callAssistant.isEmpty ? "With both filled in, the phone button calls Otto inside the app. Without them it dials the number above."
                         : "The phone button calls Otto inside the app.")
                }
                .listRowInsets(.vertical, 10)
                }
                // Messages' rows are glass over the blurred thread, not solid grey.
                .listRowBackground(Rectangle().fill(Color(UIColor { $0.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.07) : .white.withAlphaComponent(0.65) })))
            }
            .listSectionSpacing(24)
            .refreshable { await store.refreshBrief(); await store.setSnooze(nil) }
            .task {
                async let s: Void = store.setSnooze(nil)
                speakReplies = await store.backend.speakReplies(set: nil)
                hasRules = (await store.backend.dash("rules") as RulesScreen.Rules?) != nil
                if hasRules { rulesSeen = true }
                await s
            }
            // Once per opening. No watch, a 404, an error, or show-off mode's veil (hidden: true): no row.
            .task {
                let probe: DashHealth.Probe? = await store.backend.dash("health")
                hasHealth = probe.map { $0.connected && $0.hidden != true } ?? false
            }
            .navigationDestination(item: $screen) { name in
                switch name {
                case "Loops": LoopsScreen()
                case "Schedules": SchedulesScreen()
                case "Calls": CallsScreen()
                case "Memory": MemoryScreen()
                case "People": PeopleScreen()
                case "Money": MoneyScreen()
                case "Health": HealthScreen()
                case "Sleep": Loaded(path: "health") { (h: DashHealth, _) in SleepScreen(h: h) }
                case "Trips": TripsScreen()
                case "Passport": PassportScreen()
                case "Packages": PackagesScreen()
                case "Activity": ActivityScreen()
                case "Status": StatusScreen()
                case "Settings": SettingsView()
                case "Glasses": GlassesScreen()
                case "Rules": RulesScreen()
                default: DevicesScreen()
                }
            }
            // Messages' card: a back chevron in a glass circle, the thread blurred behind the list.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    if let link = PairingLink(code) { apply(link) } else { serverCheck = .failed("That isn’t an Otto pairing code.") }
                } failed: {
                    scanning = false
                    serverCheck = .failed("The scanner isn’t available right now. Paste the link into the address instead.")
                }
                .ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    Button("Cancel", systemImage: "xmark") { scanning = false }
                        .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large).padding()
                }
            }
            // Rows scrolled up blur away under the clock and the back button, as in Settings; no ruled line.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The glass behind has no colour for that edge to fade into, so the rows fade themselves: clear
            // under the clock and the back button, solid 20pt below the bar. At rest only empty space is there.
            .mask {
                GeometryReader { g in
                    VStack(spacing: 0) {
                        Color.clear.frame(height: g.safeAreaInsets.top)
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 20)
                        Color.black
                    }
                    .ignoresSafeArea()
                }
            }
            .scrollContentBackground(.hidden)
            .containerBackground(.clear, for: .navigation)   // the glass behind is CardZoom's
            .task {
                #if DEBUG
                // `-pasteLink <otto://pair…>`: as if a pairing link had just been pasted into the address, for screenshots.
                if let link = UserDefaults.standard.string(forKey: "pasteLink") {
                    try? await Task.sleep(for: .seconds(1)); server = link
                    try? await Task.sleep(for: .seconds(1)); proxy.scrollTo("server", anchor: .center); return
                }
                #endif
                #if DEBUG
                // `-notificationsOff`: the row that says so sits beside the settings, down the card.
                if CommandLine.arguments.contains("-notificationsOff") { try? await Task.sleep(for: .seconds(2)); proxy.scrollTo("server", anchor: .bottom); return }
                #endif
                guard checkOnOpen else { return }
                submitted = UUID()
                try? await Task.sleep(for: .seconds(2))   // after the brief has loaded above it
                proxy.scrollTo("server", anchor: .center)
            }
            }
        }
    }

    /// From the card's own scanner, or pasted into its address field: the owner's act, so it fills the fields,
    /// where every value it brought can be read, and runs the check.
    private func apply(_ link: PairingLink) {
        linked = link
        server = link.server; token = link.token
        submitted = UUID()   // the call keys it brought wait for this check (checkServer)
    }

    /// A label over its field. The field carries the same name for VoiceOver, so the label is hidden from it.
    private func labeled(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            field()
        }
    }

    @ViewBuilder private func checkLine(_ check: ServerCheck) -> some View {
        switch check {
        case .checking:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…") }
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        case .connected: status("checkmark.circle.fill", "Connected", icon: .green, text: .secondary)
        case .failed(let why): status("exclamationmark.triangle.fill", why, icon: .redInk, text: .redInk)
        }
    }

    /// Not a Label: in a list row a Label's icon snaps to the row's icon column, far from its text.
    private func status(_ symbol: String, _ text: String, icon: Color, text tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(icon)
            Text(text).foregroundStyle(tint)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    /// Asks the server for this app's settings with the address and token as typed: the same
    /// request onboarding makes before it saves them.
    private func checkServer() async {
        let s = server.trimmingCharacters(in: .whitespaces), t = token.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true, url.host != nil else {
            serverCheck = .failed("Enter the whole address, starting with https://"); return
        }
        guard !t.isEmpty else { serverCheck = .failed("Enter the app token from your Mac."); return }
        serverCheck = .checking
        var req = URLRequest(url: url.appending(path: "app/settings"), timeoutInterval: 10)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        var status: Int?, failure: (any Error)?, otto = false
        do {
            let (body, answer) = try await URLSession.shared.data(for: req)
            status = (answer as? HTTPURLResponse)?.statusCode; otto = ServerProblem.isOtto(body)
        } catch { failure = error }
        guard !Task.isCancelled else { return }   // edited or submitted again meanwhile
        serverCheck = switch ServerProblem(status: status, error: failure) {
        case nil where !otto: .failed(ServerProblem.notOtto.message)
        case nil: .connected
        case .unreachable?, .timedOut?: .failed("Can’t reach that address. Check it, and that Tailscale is on.")
        case .refused?: .failed("The server didn’t accept that token. Check it, or make a new one on your Mac.")
        case let problem?: .failed(problem.message)
        }
        if case .failed(let why) = serverCheck { AccessibilityNotification.Announcement(why).post() }
        else {
            AccessibilityNotification.Announcement("Connected").post()
            // What a link said about calls is kept only now: that Mac has taken the link's token. Both or neither.
            if let link = linked, link.server == s, link.token == t, let key = link.callKey, let assistant = link.callAssistant { callKey = key; callAssistant = assistant }
            linked = nil
        }
    }

    /// How long Otto is holding things back, how far through the hold, and what's waiting.
    @ViewBuilder private func snoozed(_ s: Snooze, until: Date) -> some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let start = s.since ?? tl.date
                let span = until.timeIntervalSince(start)
                VStack(alignment: .leading, spacing: 12) {
                    // No clock of its own: the status bar has one.
                    Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.title3.weight(.semibold))
                    ProgressView(value: span > 0 ? min(1, max(0, tl.date.timeIntervalSince(start) / span)) : 1)
                        .tint(.primary)
                    HStack(spacing: 10) {
                        Button { Task { await store.setSnooze(.clear) } } label: {
                            Text("Hand them over now").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { Task { await store.setSnooze(.minutes(60)) } } label: {
                            Text("Another hour").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered).tint(.secondary).foregroundStyle(.primary)
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 6)
            }
        }
        if !s.held.isEmpty {
            Section("Held for later · \(s.held.count)") {
                ForEach(s.held, id: \.self) { h in
                    LabeledContent {
                        Text(h.at, format: .dateTime.hour().minute())
                    } label: {
                        Text(h.text).lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder private func today(_ b: Brief) -> some View {
        Section {
            if b.events.isEmpty { Text("Nothing on the calendar").foregroundStyle(.secondary) }
            ForEach(b.events) { e in
                LabeledContent(e.title, value: e.start.formatted(date: .omitted, time: .shortened))
            }
        } header: { Text("Today") } footer: {
            Text("as of \(b.asOf.formatted(date: .omitted, time: .shortened))")
        }

        if !b.inbox.isEmpty || b.bulk > 0 {
            Section {
                ForEach(b.inbox) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.subject).lineLimit(2)
                        Text(m.from).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Inbox") } footer: {
                if b.bulk > 0 { Text("and \(b.bulk) not worth naming") }
            }
        }

        if !b.loops.isEmpty {
            Section("Open loops") {
                ForEach(b.loops) { l in
                    let closed = done.contains(l.id)
                    Button {
                        // Shown at once, put back if the Mac doesn't take it.
                        done.formSymmetricDifference([l.id])
                        Task { if !(await store.backend.setLoop(l.id, done: !closed)) { done.formSymmetricDifference([l.id]) } }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: closed ? "checkmark.circle.fill" : "circle")   // Reminders' mark, bare
                                .font(.title3.weight(.light)).foregroundStyle(.secondary).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.title).strikethrough(closed).lineLimit(2)
                                    .foregroundStyle(closed ? .secondary : .primary)
                                if let due = l.due, !closed {
                                    let late = due < Calendar.current.startOfDay(for: .now)
                                    Text("\(late ? "was due" : "due") \(due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
                                        .font(.footnote).foregroundStyle(late ? Color.redInk : .secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(closed ? "Closed" : "Open")
                }
            }
        }

        if !b.triggers.isEmpty {
            Section("Up next") {
                ForEach(b.triggers.sorted { $0.next < $1.next }.prefix(5)) { t in
                    LabeledContent {
                        Text(t.next.formatted(.relative(presentation: .named)))
                    } label: {
                        Text(t.title).lineLimit(2)
                    }
                }
            }
        }
    }
}

/// Opens the contact card from the header's face, Messages-style: the face moves and grows into the card's own as the
/// card zooms open around it, and shrinks back into the header on close (a swipe down too, which can be let go of to
/// stay). UIKit's zoom grows the whole card out of its source's rect, so the source is a stand-in the card's shape,
/// scaled and placed so the card's face starts exactly on the header's (SwiftUI's zoom can't be given one, and UIKit's
/// alignment rect didn't line them up). The header's face fades as the card's comes in over it, and fades back in under
/// the closing card for the card's to land on: where they hand over, the two are the same look in the same place,
/// breathing on the same clock (FaceUIView.phase). Reduce Motion: a cross-fade.
struct CardZoom: UIViewRepresentable {
    let open: Bool
    let look: FaceLook
    let store: OttoStore
    /// Whether the header shows its face: not while the card is up.
    let face: (Bool) -> Void
    /// The card has gone, or couldn't come up.
    let closed: () -> Void

    func makeUIView(context: Context) -> Seat { let s = Seat(); s.isUserInteractionEnabled = false; return s }   // the tap is the header button's
    func updateUIView(_ seat: Seat, context: Context) {
        seat.face = face
        seat.closed = closed
        seat.card?.rootView = card
        seat.want(open ? card : nil)
    }
    private var card: AnyView {
        AnyView(DetailsView(look: look).environment(store).background {
            // Liquid Glass over the thread, as Messages does, with a wash in both modes so the thread's bubbles don't
            // show through as smudges.
            Color.clear.glassEffect(.regular, in: .rect)
                .overlay(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : UIColor.systemGroupedBackground.withAlphaComponent(0.55) }))
                .ignoresSafeArea()
        })
    }

    /// Behind the card's face: where the header's face lines up.
    struct Mark: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView { let v = UIView(); v.isUserInteractionEnabled = false; CardZoom.mark = v; return v }
        func updateUIView(_ v: UIView, context: Context) {}
    }
    @MainActor fileprivate static weak var mark: UIView?

    /// Behind the header's face: the zoom's source, and what presents the card.
    final class Seat: UIView {
        var face: (Bool) -> Void = { _ in }
        var closed: () -> Void = {}
        fileprivate(set) var card: Host?
        private var wanted: AnyView?

        func want(_ view: AnyView?) { wanted = view; sync() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            DispatchQueue.main.async { self.sync() }   // `-details`: the thread has to be up before anything goes over it
        }

        private func sync() {
            if let wanted, card == nil, window != nil, let from = owner {
                // Something else is up already (a sheet): no card, and the header gets its face back.
                if from.presentedViewController == nil { present(wanted, from: from) } else { DispatchQueue.main.async(execute: closed) }
            }
            else if wanted == nil, let card, card.presentingViewController != nil, !card.isBeingDismissed {
                // Mid-zoom in: it turns back once it lands.
                if let t = card.transitionCoordinator { t.animate(alongsideTransition: nil) { [weak self] _ in self?.sync() } }
                else { card.dismiss(animated: true) }
            }
        }

        private var owner: UIViewController? {
            var r: UIResponder? = self
            while let n = r?.next { if let vc = n as? UIViewController { return vc }; r = n }
            return nil
        }

        private func present(_ view: AnyView, from: UIViewController) {
            let host = Host(rootView: view)
            host.view.backgroundColor = .clear
            host.face = { [weak self] in self?.face($0) }
            host.gone = { [weak self] in self?.card = nil; self?.closed() }
            if UIAccessibility.isReduceMotionEnabled {
                host.modalTransitionStyle = .crossDissolve
                DispatchQueue.main.async { self.face(false) }   // not inside the view update that asked for the card
            } else {
                host.preferredTransition = .zoom { [weak self] ctx in
                    guard let self else { return nil }
                    // Asked for as the zoom starts, both ways. On the way in, the header's face goes only now, so there's no gap.
                    if !ctx.zoomedViewController.isBeingDismissed { self.face(false) }
                    return self.source(for: ctx.zoomedViewController.view)
                }
            }
            host.modalPresentationStyle = .overFullScreen   // after the zoom, which sets its own: the thread stays under the glass
            card = host
            from.present(host, animated: true)
        }

        /// The card's shape at the header face's size, placed so the card's face lies on it. This face itself when the
        /// card's isn't where it opened (scrolled off, or under a pushed page): the card shrinks into it whole.
        private func source(for card: UIView) -> UIView {
            card.layoutIfNeeded()   // on the way in it hasn't been yet
            guard let mark = CardZoom.mark, mark.window != nil, !mark.bounds.isEmpty else { return self }
            let face = mark.convert(mark.bounds, to: card)
            guard card.bounds.contains(face) else { return self }
            let k = bounds.width / face.width
            stand.frame = CGRect(x: -face.minX * k, y: -face.minY * k, width: card.bounds.width * k, height: card.bounds.height * k)
            return stand
        }
        private lazy var stand: UIView = { let v = UIView(); v.isUserInteractionEnabled = false; addSubview(v); return v }()
    }

    /// The card. The header's face comes back under it as it closes: from the start for Back, and for a swipe down only
    /// once it's let go to close (while the finger holds the card, its face is the only one).
    final class Host: UIHostingController<AnyView> {
        var face: (Bool) -> Void = { _ in }
        var gone: () -> Void = {}
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard isBeingDismissed else { return }
            if let t = transitionCoordinator, t.isInteractive {
                t.notifyWhenInteractionChanges { [weak self] c in if !c.isCancelled { self?.face(true) } }
            } else {
                face(true)
            }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            face(false)
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if isBeingDismissed { gone() }
        }
    }
}
