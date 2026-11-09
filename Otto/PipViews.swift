import SwiftUI

// The screens from design/multi-otto: the conversations list, the thread pieces, and the sheets.

/// The grey the sheets sit on: white in light mode, raised grey in dark.
private let sheetColour = UIColor.secondarySystemGroupedBackground

// MARK: - Root

/// Conversations, with one thread pushed over it.
struct PipRoot: View {
    let store: OttoStore

    private enum Kind { case handoff, pip }
    /// One `sheet` in the store, shown by whichever presentation suits it.
    private func pipBinding(_ kind: Kind) -> Binding<PipSheet?> {
        let pips = store.pips
        return Binding(get: {
            switch (kind, pips.sheet) {
            case (.handoff, .handoff?), (.pip, .pip?): pips.sheet
            default: nil
            }
        }, set: { pips.sheet = $0 })
    }

    var body: some View {
        @Bindable var pips = store.pips
        NavigationStack(path: $pips.path) {
            ConversationsView(store: store)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { id in
                    ChatScreen(store: store, thread: id == "app" ? store : pips.thread(id), onBack: { pips.path = [] })
                        .id(id)
                        .background(EdgeSwipeBack())
                        .ignoresSafeArea(.keyboard)
                        .ignoresSafeArea(.container, edges: .top)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .sheet(item: pipBinding(.handoff)) { if case .handoff(let id) = $0 { HandoffSheet(store: store, id: id) } }
        // Edge to edge with its own close button, and no grabber: the mockup's a full page.
        .fullScreenCover(item: pipBinding(.pip)) { if case .pip(let id) = $0 { PipDetailSheet(store: store, id: id) } }
    }
}

/// The hidden bar takes the edge swipe with it; this puts it back. Edge only: a swipe across a
/// row means "reply" in Otto's thread, so the full-width back gesture stays off.
private struct EdgeSwipeBack: UIViewControllerRepresentable {
    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let nav = navigationController else { return }
            nav.interactivePopGestureRecognizer?.delegate = nil
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactiveContentPopGestureRecognizer?.isEnabled = false
        }
    }
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ c: Controller, context: Context) {}
}

// MARK: - Conversations

struct ConversationsView: View {
    let store: OttoStore
    @State private var query = ""
    @State private var results: [ConversationSearchResult]?
    @FocusState private var searching: Bool

    private var pips: PipStore { store.pips }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let results {
                    if results.isEmpty {
                        Text("No results").foregroundStyle(.secondary).padding(.top, 40)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                        ConversationCell(row: r.conversation, match: r.matches.last, divided: i > 0, store: store)
                    }
                } else {
                    ForEach(Array(pips.list.enumerated()), id: \.element.id) { i, row in
                        ConversationCell(row: row, match: nil, divided: i > 0, store: store)
                    }
                }
            }
        }
        .contentMargins(.bottom, 100, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if searchText.isEmpty && pips.list.isEmpty {
                ContentUnavailableView {
                    Text("No other conversations yet")
                } description: {
                    Text("Tap Otto to open your thread. When a job needs its own pip or a group, Otto starts one and it shows up here.")
                }
            }
        }
        .background(Color(.systemBackground))
        .safeAreaBar(edge: .top, spacing: 0) { top }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .bottom) { dock }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: searchText) {
            guard !searchText.isEmpty else { results = nil; return }
            try? await Task.sleep(for: .milliseconds(250))   // not on every keystroke
            guard !Task.isCancelled else { return }
            let found = await pips.search(searchText)
            if !Task.isCancelled { results = found }
        }
    }

    /// Otto at the top, in the bar the app has today.
    private var top: some View {
        Button { pips.open("app") } label: {
            HeaderTitle(name: "Otto") {
                FaceView(look: pips.row("app")?.otto?.look ?? .otto, size: 68, live: true)
                    .frame(width: 68, height: 68)
            }
        }
        .tint(.primary)
        .padding(.top, 55)
        .padding(.bottom, 6)
        .accessibilityLabel("Otto")
    }

    private var dock: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                .frame(height: 104)
                .allowsHitTesting(false)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = ""; searching = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.horizontal, searching ? 15 : 28)
            .padding(.bottom, searching ? 8 : 28)
            .animation(.snappy, value: searching)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

/// The face over the glass name capsule: every top bar in the app.
struct HeaderTitle<Face: View>: View {
    let name: String
    @ViewBuilder let face: () -> Face

    var body: some View {
        VStack(spacing: -6) {
            face()
            HStack(spacing: 4) {
                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(maxWidth: 240)
        }
    }
}

private struct ConversationCell: View {
    let row: ConversationRow
    /// A search hit: the matching message in place of the preview.
    let match: ConversationMessage?
    let divided: Bool
    let store: OttoStore

    private var pips: PipStore { store.pips }

    var body: some View {
        Button { pips.open(row.id, at: match) } label: {
            HStack(spacing: 12) {
                picture
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(row.lastMessage.flatMap { LiveBackend.date($0.ts) }.map(PipClock.listTime) ?? "")
                            .font(.system(size: 15)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(height: 22)
                    preview.font(.system(size: 15)).lineLimit(1).frame(height: 20)
                }
            }
            .padding(.leading, 20).padding(.trailing, 16)
            .frame(height: 72)
            .contentShape(.rect)
        }
        .buttonStyle(CellPress())
        .overlay(alignment: .leading) {
            if row.unread > 0 { Circle().fill(Color(red: 1, green: 0.478, blue: 0.102)).frame(width: 10, height: 10).padding(.leading, 6) }
        }
        .overlay(alignment: .top) {
            if divided { Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 90) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.unread > 0 ? "Unread" : "")
    }

    @ViewBuilder private var picture: some View {
        if row.isGroup {
            GroupFace(id: row.id, members: row.pips.map(\.look), otto: row.otto?.look, size: 58)
        } else if let pip = row.pips.first {
            FaceView(look: pip.look, size: 58).frame(width: 58, height: 58)
        }
    }

    /// In order: a search hit, what it's doing right now, when a sleeper wakes, the last message.
    @ViewBuilder private var preview: some View {
        if let match {
            Text(match.text).foregroundStyle(.secondary)
        } else if let doing = row.activity.first(where: { $0.activity?.isEmpty == false })?.activity {
            HStack(spacing: 6) {
                TypingDots(dot: 5, gap: 3).frame(width: 21, height: 5)
                Text(doing).foregroundStyle(.secondary)
            }
        } else if row.kind == "pip", row.pips.first?.state == .asleep, let wake = row.nextWakeAt {
            Text(PipClock.wake(wake)).foregroundStyle(.secondary)
        } else if let m = row.lastMessage {
            Text(line(m)).foregroundStyle(row.needsYou ? .primary : .secondary)
        }
    }

    private func line(_ m: ConversationPreview) -> String {
        guard row.isGroup else { return m.text }
        if m.sender == "user" { return "You: \(m.text)" }
        return row.memberStates.first { $0.id == m.sender }.map { "\($0.name): \(m.text)" } ?? m.text
    }
}

/// A row dims as it's held, like a list row.
private struct CellPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color(.systemGray5) : .clear)
    }
}

// MARK: - Thread pieces

/// A handoff, a model switch, or "Otto made Fares". The look of TerminalLine, with the time set the same way.
struct PipLine: View {
    let message: Message
    let afterLine: Bool
    var highlighted = false
    @Environment(OttoStore.self) private var store

    private var pips: PipStore { store.pips }
    private var handoff: PipHandoff? { message.handoffID.flatMap { pips.handoffs[$0] } }
    private var tappable: Bool { message.handoffID != nil || message.pipRef != nil }

    private var icon: String {
        if message.pipRef != nil { return "plus" }
        if message.handoffID != nil {
            switch handoff?.status {
            case "answered": return "checkmark"
            case "failed": return "exclamationmark.triangle"
            default: return "arrow.right"
            }
        }
        // No field says what a plain line is, and these are the only two the server writes.
        return message.text.localizedCaseInsensitiveContains("started") ? "checkmark" : "arrow.left.arrow.right"
    }

    private var label: some View {
        let t = message.date.formatted(date: .omitted, time: .shortened)
        return (Text(Image(systemName: icon)).font(.system(size: 9, weight: .semibold)) + Text(" " + t).fontWeight(.semibold) + Text(" " + message.text))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.top, afterLine ? 0 : 14).padding(.bottom, 8)
            .contentShape(.rect)
    }

    var body: some View {
        Group {
            if tappable {
                Button(action: open) { label }.buttonStyle(.plain)
            } else {
                label
            }
        }
        .background {
            Capsule().fill(Color(.systemFill)).opacity(highlighted ? 1 : 0)
                .padding(.top, afterLine ? 0 : 14).padding(.bottom, 8).padding(.horizontal, 16)
        }
        .task(id: message.handoffID) {
            if let id = message.handoffID, pips.handoffs[id] == nil { await pips.loadHandoff(id) }
        }
    }

    private func open() {
        if let id = message.handoffID { pips.sheet = .handoff(id) } else if let id = message.pipRef { pips.sheet = .pip(id) }
    }
}

/// Otto's link to a group it made: the size of a link preview.
struct GroupLinkBubble: View {
    let group: GroupLink
    let open: () -> Void

    /// "Otto, Fares and Stays", as the mockup writes it. The server's own line has no "and".
    private var names: String {
        let list = group.memberList
        guard !list.contains(" and "), let last = list.range(of: ", ", options: .backwards) else { return list }
        return list.replacingCharacters(in: last, with: " and ")
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                GroupFace(id: group.id, members: group.members.filter { !$0.isOtto }.map(\.look), otto: group.members.first(where: \.isOtto)?.look,
                          size: 44, ring: UIColor(Color.incomingBubble))
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(names).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 10).padding(.trailing, 14).padding(.vertical, 8)
            .background(BubbleShape(mine: false, tail: true).fill(.incomingBubble))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Group \(group.name), \(names)")
    }
}

/// A member working on something, in the thread: face, dots, and the line it reported.
struct ActivityLine: View {
    let member: PipMember
    let withFace: Bool
    let press: (ActionButton) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if withFace {
                FaceView(look: member.look, size: member.isOtto ? 44 : 34)
                    .frame(width: 40, height: member.isOtto ? 44 : 34)
                    .padding(.bottom, -2)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TypingDots().frame(width: 29, height: 7)
                    Text(member.activity ?? "")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(BubbleShape(mine: false, tail: true).fill(.incomingBubble))
                let buttons = Message.actionButtons(member.buttons)
                if !buttons.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(buttons) { b in Button(b.label) { press(b) }.font(.system(size: 15)).tint(.blue) }
                    }
                    .padding(.leading, 12)
                }
            }
            Spacer(minLength: 41)
        }
        .padding(.top, 10)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: member.activity)
        .accessibilityElement(children: .combine)
    }
}

/// `@Fa` in a group's composer offers Fares, Stays and so on.
struct MentionBar: View {
    let members: [PipMember]
    let pick: (PipMember) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(members) { m in
                    Button { pick(m) } label: {
                        HStack(spacing: 4) {
                            FaceView(look: m.look.with(.rest), size: 24).frame(width: 24, height: 24)
                            Text(m.name).font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.leading, 6).padding(.trailing, 12).frame(height: 36)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .tint(.primary)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Handoff sheet

struct HandoffSheet: View {
    let store: OttoStore
    let id: String
    @Environment(\.dismiss) private var dismiss

    private var pips: PipStore { store.pips }
    private var h: PipHandoff? { pips.handoffs[id] }

    var body: some View {
        Group {
            if let h { content(h) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task { await pips.loadHandoff(id) }
        .presentationDetents([.fraction(0.5), .large])
        .presentationCornerRadius(38)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(sheetColour))
    }

    private func member(_ who: String) -> PipMember {
        pips.member(who) ?? PipMember(id: who, name: who, solid: .gem, colour: "#6B97EC", state: .rest)
    }

    private func content(_ h: PipHandoff) -> some View {
        let from = member(h.from), to = member(h.to), failed = h.status == "failed"
        let fromLook = from.look.with(failed ? .failed : .rest)
        let toLook = to.look.with(failed ? .asleep : .rest)
        return VStack(spacing: 0) {
            Text("\(from.name) to \(to.name)")
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 26).padding(.horizontal, 56)
            ScrollView {
                VStack(spacing: 0) {
                    HandoffPath(from: fromLook, to: toLook, failed: failed).padding(.top, 20).padding(.bottom, 18)
                    VStack(spacing: 10) {
                        said(h.ask, by: fromLook, ring: from)
                        if let reply = h.reply, !failed { said(reply, by: toLook, ring: to) }
                        stamp(h)
                    }
                    .padding(.horizontal, 16)
                    Text(result(h, from: from, to: to))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16).padding(.horizontal, 16)
                }
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            actions(h, to: to)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .topTrailing) { CloseButton { dismiss() } }
    }

    private func said(_ text: String, by look: FaceLook, ring: PipMember) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            FaceView(look: look, size: 34, ring: sheetColour).frame(width: 34, height: 34)
            Text(text)
                .font(.system(size: 15))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.incomingBubble, in: .rect(cornerRadius: 17, style: .continuous))
            Spacer(minLength: 10)   // the mockup's 86% wide bubble
        }
    }

    private func stamp(_ h: PipHandoff) -> some View {
        Group {
            if let d = LiveBackend.date(h.askedAt) {
                let day = Calendar.current.isDateInToday(d) ? "Today" : Calendar.current.isDateInYesterday(d) ? "Yesterday" : d.formatted(.dateTime.weekday(.wide))
                (Text(day).fontWeight(.semibold) + Text(" " + d.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private func result(_ h: PipHandoff, from: PipMember, to: PipMember) -> String {
        if h.status == "failed" { return h.error ?? "Nothing was sent." }
        guard let told = h.toldOttoAt, h.status == "answered" else { return "Waiting on \(to.name)." }
        let line = "\(to.name) told Otto at \(PipClock.time(told))"
        return h.toldUserAt != nil ? "\(line), and Otto told you." : "\(line)."
    }

    @ViewBuilder private func actions(_ h: PipHandoff, to: PipMember) -> some View {
        VStack(spacing: 8) {
            if h.status == "failed" {
                PillButton(title: "Retry", primary: true) { pips.act("retry", on: h.id) }
                PillButton(title: "Ask Otto to handle it") { pips.act("ask_otto", on: h.id) }
            } else {
                let target = to.isOtto ? "app" : to.id
                if pips.row(target) != nil {
                    PillButton(title: "Open \(to.name)") { pips.open(target) }
                }
            }
        }
    }
}

/// The path between two faces. It lives only in this sheet, never in a thread.
private struct HandoffPath: View {
    let from: FaceLook
    let to: FaceLook
    let failed: Bool

    private struct Arc: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.minY + 30))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 30), control: CGPoint(x: r.midX, y: r.minY - 14))
            return p
        }
    }

    private var line: LinearGradient { LinearGradient(colors: [Color(from.tint), Color(to.tint)], startPoint: .leading, endPoint: .trailing) }
    private let style = StrokeStyle(lineWidth: 3, lineCap: .round)

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                FaceView(look: from, size: 72, live: true, ring: sheetColour).frame(width: 72, height: 72)
                Spacer(minLength: 0)
                FaceView(look: to, size: 72, live: true, ring: sheetColour).frame(width: 72, height: 72)
            }
            Group {
                if failed {
                    // A break under the tag: the handoff never got across.
                    ZStack {
                        Arc().trim(from: 0, to: 0.4).stroke(line, style: style)
                        Arc().trim(from: 0.56, to: 1).stroke(line, style: style)
                    }
                } else {
                    Arc().stroke(line, style: style)
                }
            }
            .frame(width: 176, height: 44)
            .padding(.top, 4)
            Image(systemName: failed ? "xmark" : "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(failed ? Color(red: 0.898, green: 0.282, blue: 0.302) : Color(red: 0.188, green: 0.631, blue: 0.306), in: .circle)
                .padding(.top, 2)
        }
        .frame(width: 300, height: 72)
        .accessibilityHidden(true)
    }
}

// MARK: - Pip details

struct PipDetailSheet: View {
    let store: OttoStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false

    private var pips: PipStore { store.pips }
    private var p: PipDetail? { pips.details[id] }

    var body: some View {
        Group {
            if let p { content(p) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .tint(.primary)
            .accessibilityLabel("Close")
            .padding(.trailing, 16).padding(.top, -2)
        }
        .overlay(alignment: .topLeading) {
            if p != nil {
                Button("Edit") { editing = true }
                    .font(.system(size: 17, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44).padding(.horizontal, 8)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .tint(.primary)
                    .padding(.leading, 16).padding(.top, -2)
            }
        }
        .sheet(isPresented: $editing) { if let p { PipEditSheet(store: store, pip: p) } }
        .task {
            #if DEBUG
            if PipFixture.screen.hasPrefix("edit-") { editing = true }
            #endif
            await pips.loadPip(id)
        }
    }

    private func content(_ p: PipDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    FaceView(look: p.look, size: 88, live: true, ring: UIColor.systemGroupedBackground).frame(width: 88, height: 88)
                    Text(p.name).font(.system(size: 22, weight: .semibold)).padding(.top, 4)
                    Text(p.job).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 20)

                if !p.description.isEmpty {
                    card {
                        Text(p.description).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                if !p.schedules.isEmpty {
                    section("Schedules") {
                        ForEach(Array(p.schedules.enumerated()), id: \.element.id) { i, s in
                            line(divided: i > 0) {
                                Text(s.name)
                                Spacer(minLength: 8)
                                Text(s.label).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                if !p.canReach.isEmpty {
                    section("Can reach") {
                        ForEach(Array(p.canReach.enumerated()), id: \.element.id) { i, r in
                            let (symbol, colour) = Self.reach(r.name)
                            line(divided: i > 0) {
                                tile(symbol, colour)
                                Text(r.name)
                                Spacer(minLength: 8)
                                if r.sharedWithOtto { Text("Shared with Otto").foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }
                section("Runs on", bottom: 16) {
                    line(divided: false) {
                        tile("arrow.left.arrow.right", Color(UIColor(rgb: 0x46526B)))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(Self.model(p.runsOn))
                            if let note = Self.note(p.runsOn) { Text(note).font(.system(size: 13)).foregroundStyle(.secondary) }
                        }
                    }
                }
                PillButton(title: p.paused ? "Resume pip" : "Pause pip", systemImage: p.paused ? "play" : "pause") {
                    pips.setPaused(!p.paused, pip: p.id)
                }
                .padding(.horizontal, 16)
                .sensoryFeedback(.impact(weight: .light), trigger: p.paused)
            }
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0) { c() }
            .background(Color(sheetColour), in: .rect(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
    }

    private func section<C: View>(_ title: String, bottom: CGFloat = 24, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 32)
            VStack(spacing: 0) { c() }
                .background(Color(sheetColour), in: .rect(cornerRadius: 26, style: .continuous))
                .padding(.horizontal, 16)
        }
        .padding(.bottom, bottom)
    }

    private func line<C: View>(divided: Bool, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 12) { c() }
            .font(.system(size: 17))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .overlay(alignment: .top) { if divided { Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 16) } }
    }

    private func tile(_ symbol: String, _ colour: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(colour, in: .rect(cornerRadius: 8, style: .continuous))
    }

    /// The server names what a pip may touch; this picks its tile.
    private static func reach(_ name: String) -> (String, Color) {
        let n = name.lowercased()
        if n.contains("calendar") { return ("calendar", Color(UIColor(rgb: 0xE5484D))) }
        if n.contains("place") || n.contains("route") { return ("point.topleft.down.to.point.bottomright.curvepath", Color(UIColor(rgb: 0x3B6FD4))) }
        if n.contains("web") { return ("globe", Color(UIColor(rgb: 0x2A9AA8))) }
        if n.contains("memory") { return ("brain", Color(UIColor(rgb: 0x9A5BC8))) }
        if n.contains("mail") || n.contains("inbox") { return ("envelope", Color(UIColor(rgb: 0x3B6FD4))) }
        return ("square.grid.2x2", Color(UIColor(rgb: 0x46526B)))
    }

    /// Never claims a model that isn't running: nil means nothing is.
    private static func model(_ r: PipDetail.RunsOn) -> String {
        guard let m = r.model?.lowercased() else { return String(localized: "Not running") }
        if m.contains("gpt") { return "GPT" }
        if m.contains("claude") || m.contains("opus") || m.contains("sonnet") || m.contains("haiku") || m.contains("fable") { return "Claude" }
        return r.model ?? ""
    }

    private static func note(_ r: PipDetail.RunsOn) -> String? {
        var parts = [r.reason.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        if let d = LiveBackend.date(r.claudeReturnsAt) { parts.append("Back on \(d.formatted(.dateTime.weekday(.wide))).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// A pip's name, job and schedules. Nothing leaves the phone until Save.
private struct PipEditSheet: View {
    let store: OttoStore
    let pip: PipDetail
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var job: String
    @State private var schedules: [PipSchedule]
    @State private var path: [String] = []
    @State private var saving = false
    @State private var failed = false

    init(store: OttoStore, pip: PipDetail) {
        self.store = store
        self.pip = pip
        _name = State(initialValue: pip.name)
        _job = State(initialValue: pip.job)
        _schedules = State(initialValue: pip.schedules)
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func incomplete(_ s: PipSchedule) -> Bool { blank(s.name) || blank(s.ask) }
    private var changed: Bool { name != pip.name || job != pip.job || schedules != pip.schedules }
    private var ready: Bool { changed && !Self.blank(name) && !Self.blank(job) && !schedules.contains(where: Self.incomplete) }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Name") {
                    TextField("Name", text: $name).textInputAutocapitalization(.words)
                }
                Section("Job") {
                    TextField("What this pip is for", text: $job, axis: .vertical)
                }
                Section("Schedules") {
                    ForEach(schedules) { s in
                        NavigationLink(value: s.id) {
                            HStack {
                                Text(s.name.isEmpty ? "New schedule" : s.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Self.incomplete(s) ? "Incomplete" : s.label).lineLimit(1)
                                    .foregroundStyle(Self.incomplete(s) ? Color(.systemRed) : .secondary)
                            }
                        }
                    }
                    .onDelete { schedules.remove(atOffsets: $0) }
                    if schedules.count < 10 {
                        Button("Add schedule", systemImage: "plus") {
                            let when = ScheduleWhen()
                            let s = PipSchedule(id: UUID().uuidString, name: "", label: when.label, schedule: when.cron, tz: TimeZone.current.identifier, ask: "")
                            schedules.append(s)
                            path = [s.id]
                        }
                    }
                }
            }
            .navigationTitle("Edit \(pip.name)")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let i = schedules.firstIndex(where: { $0.id == id }) { ScheduleEditor(schedule: $schedules[i]) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save", action: save).disabled(!ready) }
                }
            }
        }
        .tint(.primary)
        .interactiveDismissDisabled(changed)
        .onChange(of: name) { if name.count > 60 { name = String(name.prefix(60)) } }
        .onChange(of: job) { if job.count > 200 { job = String(job.prefix(200)) } }
        // Backed out of a new schedule without filling anything in: it was never there.
        .onChange(of: path) { if path.isEmpty { schedules.removeAll { Self.blank($0.name) && Self.blank($0.ask) } } }
        .alert("Couldn’t save", isPresented: $failed) { Button("OK") {} } message: {
            Text("Your changes are still here. Check the connection and try again.")
        }
        .task {
            #if DEBUG
            if PipFixture.screen == "edit-schedule", let s = schedules.first { path = [s.id] }
            #endif
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), j = job.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            let ok = await store.pips.update(pip: pip.id, name: n == pip.name ? nil : n, job: j == pip.job ? nil : j,
                                             schedules: schedules == pip.schedules ? nil : schedules)
            saving = false
            if ok { dismiss() } else { failed = true }
        }
    }
}

private struct ScheduleEditor: View {
    @Binding var schedule: PipSchedule
    @State private var when: ScheduleWhen
    /// A cron line too fancy for days and a time: left alone until the reader changes one.
    private let understood: Bool

    private let cal = Calendar.current
    private var week: [Int] { (0..<7).map { ($0 + cal.firstWeekday - 1) % 7 } }

    init(schedule: Binding<PipSchedule>) {
        _schedule = schedule
        let parsed = ScheduleWhen(cron: schedule.wrappedValue.schedule)
        _when = State(initialValue: parsed ?? ScheduleWhen())
        understood = parsed != nil
    }

    private var time: Binding<Date> {
        Binding {
            cal.date(bySettingHour: when.hour, minute: when.minute, second: 0, of: .now) ?? .now
        } set: {
            let c = cal.dateComponents([.hour, .minute], from: $0)
            when.hour = c.hour ?? when.hour
            when.minute = c.minute ?? when.minute
        }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Morning route check", text: $schedule.name).textInputAutocapitalization(.sentences)
            }
            Section("What to do") {
                TextField("What the pip should do each time", text: $schedule.ask, axis: .vertical)
            }
            Section {
                HStack(spacing: 0) { ForEach(week, id: \.self, content: day) }
                DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
            } header: {
                Text("When")
            } footer: {
                if !understood { Text("Now: \(schedule.label). Picking a day or time replaces it.") }
            }
        }
        .navigationTitle(schedule.name.isEmpty ? "New schedule" : schedule.name)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: when.days)
        .onChange(of: when) { schedule.schedule = when.cron; schedule.label = when.label }
    }

    private func day(_ d: Int) -> some View {
        let on = when.days.contains(d)
        return Button {
            // A schedule that never runs is a deleted one, and that's the row's swipe.
            if !on { when.days.insert(d) } else if when.days.count > 1 { when.days.remove(d) }
        } label: {
            Text(cal.veryShortStandaloneWeekdaySymbols[d]).font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Color(.systemBackground) : .primary)
                .frame(width: 36, height: 36)
                .background(on ? Color.primary : Color(.secondarySystemFill), in: .circle)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cal.standaloneWeekdaySymbols[d])
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Shared

private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(.secondaryLabel))
                .frame(width: 36, height: 36)
                .background(Color(.systemFill), in: .circle)
                .padding(4).contentShape(.circle)
        }
        .accessibilityLabel("Close")
        .padding(.top, 8).padding(.trailing, 12)
    }
}

private struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 50)
            .foregroundStyle(primary ? Color(.systemBackground) : .primary)
            .background(primary ? Color.primary : Color(.secondarySystemFill), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PillPress())
    }
}

private struct PillPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var still
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !still ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
