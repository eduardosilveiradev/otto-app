import SwiftUI

/// The contact card: what Otto knows about today, and the few settings there are.
struct DetailsView: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    // Server URL and token persist (LiveBackend.fromDefaults reads them at launch).
    // Speak-replies, snooze and closed loops live on the Mac.
    @AppStorage("serverURL") private var server = ""
    @AppStorage("serverToken") private var token = ""
    @AppStorage("callNumber") private var callNumber = ""
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
                        OttoAvatar(size: 78, asleep: store.asleep)
                        Text("Otto").font(.title2.weight(.semibold))
                        // isLive isn't observable, so re-read it every second while the sheet is open.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let line = store.backend is MockBackend ? "Sample data"
                                : !store.connected ? "Asleep. Can’t reach your Mac." : nil {
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
                    NavigationLink { TripsScreen() } label: { Label("Trips", systemImage: "airplane") }
                    NavigationLink { PassportScreen() } label: { Label("Passport", systemImage: "globe.europe.africa") }
                    NavigationLink { PackagesScreen() } label: { Label("Packages", systemImage: "shippingbox") }
                    NavigationLink { ActivityScreen() } label: { Label("Activity", systemImage: "waveform.path.ecg") }
                }

                Section {
                    NavigationLink { StatusScreen() } label: { Label("Status", systemImage: "gauge.with.dots.needle.33percent") }
                    NavigationLink { DevicesScreen() } label: { Label("Devices", systemImage: "iphone") }
                    NavigationLink { GlassesScreen() } label: { Label { Text("Glasses") } icon: { Image(systemName: "eyeglasses").imageScale(.small) } }
                }

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
                    NavigationLink("Settings") { SettingsView() }
                }

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
                    labeled("Otto’s phone number") {
                        TextField("Otto’s phone number", text: $callNumber, prompt: Text(verbatim: "+1 555 0100")).keyboardType(.phonePad)
                    }
                } header: { Text("Server") } footer: {
                    Text("Over Tailscale. Quit and reopen the app after changing these.")
                }
                .listRowInsets(.vertical, 10)   // 20 between fields
                .onChange(of: server) { submitted = nil; serverCheck = nil }
                .onChange(of: token) { submitted = nil; serverCheck = nil }
                .task(id: submitted) { if submitted != nil { await checkServer() } }
                }
                // Messages' rows are glass over the blurred thread, not solid grey.
                .listRowBackground(Rectangle().fill(Color(UIColor { $0.userInterfaceStyle == .dark ? .white.withAlphaComponent(0.07) : .white.withAlphaComponent(0.65) })))
            }
            .listSectionSpacing(24)
            .refreshable { await store.refreshBrief(); await store.setSnooze(nil) }
            .task {
                async let s: Void = store.setSnooze(nil)
                speakReplies = await store.backend.speakReplies(set: nil)
                await s
            }
            .navigationDestination(item: $screen) { name in
                switch name {
                case "Loops": LoopsScreen()
                case "Schedules": SchedulesScreen()
                case "Calls": CallsScreen()
                case "Memory": MemoryScreen()
                case "People": PeopleScreen()
                case "Money": MoneyScreen()
                case "Trips": TripsScreen()
                case "Passport": PassportScreen()
                case "Packages": PackagesScreen()
                case "Activity": ActivityScreen()
                case "Status": StatusScreen()
                case "Settings": SettingsView()
                case "Glasses": GlassesScreen()
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
            .task {
                guard checkOnOpen else { return }
                submitted = UUID()
                try? await Task.sleep(for: .seconds(2))   // after the brief has loaded above it
                proxy.scrollTo("server", anchor: .center)
            }
            }
        }
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
        case .failed(let why): status("exclamationmark.triangle.fill", why, icon: .red, text: .red)
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
        var status: Int?, failure: (any Error)?
        do { status = (try await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode } catch { failure = error }
        guard !Task.isCancelled else { return }   // edited or submitted again meanwhile
        serverCheck = switch ServerProblem(status: status, error: failure) {
        case nil: .connected
        case .unreachable?, .timedOut?: .failed("Can’t reach that address. Check it, and that Tailscale is on.")
        case .refused?: .failed("The server didn’t accept that token. Check it, or make a new one on your Mac.")
        case let problem?: .failed(problem.message)
        }
        if case .failed(let why) = serverCheck { AccessibilityNotification.Announcement(why).post() }
        else { AccessibilityNotification.Announcement("Connected").post() }
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
                        .tint(.orange)
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
                                        .font(.footnote).foregroundStyle(late ? .red : .secondary)
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
