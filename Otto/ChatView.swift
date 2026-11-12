import SwiftUI
import PhotosUI
import AVFoundation
import QuickLook
import PassKit
import LinkPresentation
import ThinkingOrbsKit
import VoiceGlowKit

/// What ChatView, Composer and Row need from a conversation (OttoStore).
@MainActor protocol ChatThread: AnyObject {
    /// Who's on the other end, for the composer's placeholder and its reply bar.
    var name: String { get }
    /// Otto's own thread: calls, the gate card, approvals, details, photos and voice notes.
    var isOtto: Bool { get }
    var messages: [Message] { get }
    /// The thinking bubble, and the step it shows.
    var typing: Bool { get }
    var typingStatus: String? { get }
    /// Otto's to-do list for the reply, shown in the bubble under the step.
    var typingTodos: [TodoItem] { get }
    var connected: Bool { get }
    /// Off while the first history lands, so it appears at once instead of popping in.
    var animated: Bool { get }
    /// The message a swipe picked to answer; the composer shows it until you send or cancel.
    var replyingTo: Message.ID? { get set }
    func send(_ text: String)
    func react(_ emoji: String, on id: Message.ID)
    func tap(_ button: ActionButton, on id: Message.ID)
    /// One of yours marked "Not delivered", sent again now.
    func retry(_ id: Message.ID)
    /// The server's id for this conversation; Otto's own is "app".
    var conversationID: String { get }
}

extension OttoStore: ChatThread {
    var name: String { "Otto" }
    var isOtto: Bool { true }
    var typing: Bool { ottoTyping }
    var typingStatus: String? { ottoStatus }
    var typingTodos: [TodoItem] { ottoTodos }
    var conversationID: String { "app" }
    func send(_ text: String) { send(text, shared: false) }
}

/// The whole app is one Messages-style conversation. Tapping Otto's name opens details.
struct ChatView: View {
    @Environment(OttoStore.self) private var store
    @State private var showDetails = ProcessInfo.processInfo.arguments.contains("-details")
    @Namespace private var card
    @State private var showCall = false
    /// `-call` (with `-vapiPublicKey`, `-vapiAssistantId` and, in DEBUG, `-vapiHost`): open straight into a web call.
    @State private var webCall = ProcessInfo.processInfo.arguments.contains("-call")
    /// Calls Otto is placing for you; a live one shows as a banner under the header.
    @State private var calls = CallWatch()
    @State private var gate = GateWatch()
    @State private var showGate = false
    @State private var openCall: DashCall?
    /// Otto's phone line (the Vapi assistant). Set in details; dialled with the phone app.
    @AppStorage("callNumber") private var callNumber = ""
    /// When the "hold for walkie-talkie" hint last showed; it comes back every two months.
    @AppStorage("walkieHintAt") private var walkieHintAt = 0.0
    @State private var walkieHint = false
    @Environment(\.openURL) private var openURL
    /// Shared with the composer, which lives in its own hosting controller (see KeyboardDock).
    let ui: ComposerUI
    let thread: any ChatThread
    /// Back to the conversations; nil when Otto's is the only thread there is.
    var onBack: (() -> Void)? = nil
    private var focused: Bool { ui.focused }
    private var pipsOn: Bool { store.pips.active }
    private var row: ConversationRow? { store.pips.row(thread.conversationID) }
    private var isGroup: Bool { row?.isGroup == true }
    private var callContext: String? { thread.isOtto ? nil : thread.name }
    @State private var scroll = ScrollPosition(edge: .bottom)
    /// The thread's bottom margin; follows ui.bottomInset, but lags it while the keyboard closes.
    @State private var margin: CGFloat = 0
    /// Scroll offset from the top of the content. Held in a box: it changes every scroll
    /// frame, and as plain state each change re-ran the body of the whole thread.
    @State private var offset = Offset()
    final class Offset { var y: CGFloat = 0 }
    /// The row count as of the last update (see `burst`), and an older page going in above what's on screen.
    /// Boxed like the offset: neither should re-run the body.
    @State private var counted = Counted()
    /// `landing`: a search result is opening, so the composer and keyboard coming back don't scroll the thread.
    final class Counted { var rows = 0; var paging = false; var landing = false }
    /// Far enough up the thread that the newest messages are out of sight.
    @State private var scrolledUp = false
    @State private var visibleNewest: Message.ID?
    private var newestOtto: Message? { thread.messages.last(where: { $0.from == .otto }) }
    private var seenDate: Date? {
        thread.isOtto && store.foreground && visibleNewest == newestOtto?.id ? newestOtto?.date : nil
    }
    /// How many of the newest messages are laid out. The thread isn't lazy (see below), so a
    /// long one laid out whole made every change cost a pass over all of it; reaching the
    /// top lays out another page.
    @State private var shown = Self.page
    private static let page = 60

    private var lastMine: Message.ID? { thread.messages.last(where: { $0.from == .me })?.id }
    /// The message a tapped quote jumped to, lit up for a moment.
    @State private var flashed: Message.ID?
    /// A row is being swiped to reply: the thread holds still under it, like Messages.
    @State private var swiping = false
    /// At the very bottom (within 4pt), and whether the reader was when the swipe began.
    @State private var atBottom = true
    @State private var pinnedAtSwipe = false
    /// The quote jump in flight; a second tap replaces it, so an old one can't end the new flash early.
    @State private var jumping: Task<Void, Never>?

    /// Search: pulled down past the top of the thread (or on the header), as in Messages and Mail.
    /// Open while `ui.searching`, which the composer reads too.
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The server's newest 500 that are older than anything in this thread: fetched once a search,
    /// kept until it closes. Nil until they land. `/app/history` has no query, so this is as far back as search reaches.
    @State private var older: [Message]?
    @State private var olderFailed = false
    @State private var fetching: Task<Void, Never>?
    private var searchWords: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showingResults: Bool { ui.searching && !searchWords.isEmpty }
    private var hits: [Message] {
        let words = searchWords
        return ((older ?? []) + thread.messages).filter { $0.patch == nil && ThreadSearch.matches($0.text, words) }
    }

    private func openSearch() {
        guard !ui.searching else { return }
        withAnimation(still ? .easeOut(duration: 0.2) : .snappy) { ui.searching = true }
        Task { searchFocused = true }   // once the field is there to take it
    }
    private func closeSearch(animated: Bool = true) {
        fetching?.cancel()
        fetching = nil; older = nil; olderFailed = false; query = ""
        let motion: Animation? = still ? .easeOut(duration: 0.2) : .snappy
        withAnimation(animated ? motion : nil) { ui.searching = false }
    }
    private func fetchOlder() {
        olderFailed = false
        fetching = Task {
            let rows = await store.backend.history(background: false, limit: 500, since: nil)
            guard !Task.isCancelled else { return }
            guard let rows else { olderFailed = true; return }
            let oldest = thread.messages.first?.date ?? .distantFuture
            older = rows.filter { $0.patch == nil && $0.date < oldest }
        }
    }
    /// A tapped result, in the thread. One from the server's history goes in first, with everything
    /// after it so the thread stays whole, and the ten before it, for context and so it can sit mid-screen.
    private func show(_ m: Message) {
        if thread.isOtto, let older, let i = older.firstIndex(where: { $0.id == m.id }) {
            store.messages.insert(contentsOf: older[max(0, i - 10)...], at: 0)
        }
        // Nothing else may be moving the thread when the jump starts, or it wins: the bar goes in one
        // step, and the composer and keyboard coming back only set the margin (no scroll on the keyboard's slow curve).
        counted.landing = true
        closeSearch(animated: false)
        Task {
            // ponytail: a fixed wait for their margin changes to land (a frame or three); a slower device may want more.
            try? await Task.sleep(for: .milliseconds(250))
            counted.landing = false
            jump(to: m.id)
        }
    }

    /// A tapped quote: scroll its original into the middle (laying out older pages if it's up
    /// there) and light it up, so the eye lands on it.
    private func jump(to id: Message.ID) {
        let messages = thread.messages
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        // A page above it, so the scroll there never comes near the top: the next page going in
        // there scrolled in one step, which stopped the jump short of it.
        let grew = messages.count - i + Self.page > shown
        if grew { shown = messages.count - i + Self.page }
        jumping?.cancel()
        jumping = Task {
            do {
                // Rows just paged in aren't built yet; give them a frame before scrolling to one.
                // ponytail: two frames at 60Hz, verified 70 rows up; a slow device may want more.
                if grew { try await Task.sleep(for: .milliseconds(32)) }
                move { $0.scrollTo(id: id, anchor: .center) }
                // On the bubble once it has stopped moving, not while it flies past.
                if !still { try await Task.sleep(for: .seconds(0.3)) }
                withAnimation(.easeOut(duration: 0.2)) { flashed = id }
                try await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeInOut(duration: 0.4)) { flashed = nil }
            } catch {}   // replaced by a newer jump, which owns the flash now
        }
    }
    @Environment(\.accessibilityReduceMotion) private var still

    /// Every scroll the thread makes goes through here, so none of them can jump or ignore the system's setting:
    /// - in one step under Reduce Motion, or while a burst of rows lands at once (a catch-up);
    /// - `keyboard` keeps the keyboard's curve whatever the setting: the keyboard slides either way, and the thread rides it;
    /// - a `follow` (the thread keeping up with something, not you asking) leaves a reader up the thread where they are.
    private func move(_ animation: Animation? = .snappy, follow: Bool = false, keyboard: Bool = false,
                      then done: @escaping () -> Void = {}, _ to: (inout ScrollPosition) -> Void) {
        if follow && scrolledUp { return }
        withAnimation(keyboard || !(still || burst) ? animation : nil, completionCriteria: .logicallyComplete) {
            to(&scroll)
        } completion: { done() }
    }
    /// More than one row since the last update: a catch-up landing, not someone typing.
    private var burst: Bool { thread.messages.count - counted.rows > 1 }

    /// The space above a bubble. A group's always clears the name above it.
    private func gap(group: Bool, runStarts: Bool, stamped: Bool, sameAuthor: Bool) -> CGFloat {
        if group { return runStarts ? 10 : 4 }
        return stamped ? 0 : sameAuthor ? 4 : 10
    }

    /// "Read" once the server says Otto has taken the message in; until then it may be sitting
    /// in the queue behind a long turn, which is "Delivered". Not guessed from a later message of
    /// Otto's: that can be a proactive one, or an answer to something else.
    /// None in a group, and none once a handoff after your message has finished: the work has answered it.
    private func receipt(for i: Int, in messages: [Message]) -> Bool? {
        let finished = messages[(i + 1)...].contains { m in
            m.handoffID.flatMap { store.pips.handoffs[$0]?.status }.map { $0 == "answered" || $0 == "failed" } ?? false
        }
        return isGroup || finished ? nil : messages[i].read == true
    }

    /// A tapped search result, once the thread has loaded: scroll to it and light it up.
    private func jumpToMatch() async {
        guard let w = store.pips.match else { return }
        store.pips.match = nil
        let hit = Message(w)
        // Old-transport rows in Otto's thread carry other ids, so those match on their words and time.
        func found() -> Message.ID? {
            thread.messages.first { $0.wireID == hit.wireID }?.id
                ?? thread.messages.filter { $0.text == hit.text }
                    .min { abs($0.date.timeIntervalSince(hit.date)) < abs($1.date.timeIntervalSince(hit.date)) }?.id
        }
        // ponytail: older than the 200 a thread loads, it lands alone in date order; history has no `before` to page with.
        if found() == nil { (thread as? PipThread)?.upsert(w) }
        guard let id = found() else { return }
        try? await Task.sleep(for: .seconds(0.45))   // the push finishing, and the rows that just loaded
        jump(to: id)
    }

    var body: some View {
        let messages = thread.messages
        threadList
        // Hidden, not removed, under the results: closing the search comes back to the same place.
        .opacity(showingResults ? 0 : 1)
        .allowsHitTesting(!showingResults)
        .accessibilityHidden(showingResults)
        // An empty thread has no width of its own; without this the line wrapped a letter at a time.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if showingResults {
                SearchResults(hits: hits, query: searchWords, loading: thread.isOtto && older == nil && !olderFailed, failed: olderFailed,
                              bottomInset: ui.bottomInset,
                              who: { m in m.from == .me || m.from == .terminal ? "You" : row?.memberStates.first { $0.id == m.author }?.name ?? thread.name },
                              retry: fetchOlder, open: show, close: { closeSearch() })
            } else if thread.isOtto && messages.isEmpty && !store.ottoTyping {
                EmptyChat(asleep: store.asleep, connected: store.connected)
            }
        }
        .onChange(of: searchWords) {
            if !searchWords.isEmpty, thread.isOtto, fetching == nil { fetchOlder() }
        }
        .background(Color(.systemBackground))
        .safeAreaBar(edge: .top, spacing: 0) {
            ottoTop
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .task { await calls.run(store.backend) }
        .task(id: seenDate) {
            guard let date = seenDate, let live = store.backend as? LiveBackend else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await live.seen(date)
        }
        .modifier(ThreadSeen(pips: store.pips, thread: thread) { await jumpToMatch() })
        .task { if thread.isOtto { await gate.run(store.backend) } }
        .sheet(isPresented: $showGate) { GateSheet(watch: gate) }
        // `-openGate`: open the boarding pass as soon as there is one, for screenshots.
        .onChange(of: gate.card?.key, initial: true) {
            if ProcessInfo.processInfo.arguments.contains("-openGate"), gate.card != nil { showGate = true }
        }
        // `-openCall`: open the live call as soon as there is one, for screenshots.
        .onChange(of: calls.live?.id) {
            if ProcessInfo.processInfo.arguments.contains("-openCall"), let live = calls.live { openCall = live }
        }
        .sheet(item: $openCall) { CallSheet(call: $0) }
        .sheet(item: Binding(get: { thread.isOtto ? store.otpDrawer : nil }, set: { store.otpDrawer = $0 })) {
            if let otp = $0.otp { OTPDrawer(otp: otp) }
        }
        // Closed only by its own buttons (Later hides it), so the setter has nothing to do.
        .sheet(item: Binding(get: { thread.isOtto ? store.shownApproval : nil }, set: { _ in })) {
            ApprovalSheet(request: $0)
        }
        // The header's fade, mirrored behind the composer: bubbles dissolve over the 16pt above it
        // and are gone by the top of the field, instead of reading through the glass.
        .overlay(alignment: .bottom) {
            LinearGradient(stops: [.init(color: Color(.systemBackground).opacity(0), location: 0),
                                   .init(color: Color(.systemBackground), location: 16 / (ui.bottomInset + 16))],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: ui.bottomInset + 16)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        // Back to the newest message, once you've scrolled well away from it.
        .overlay(alignment: .bottomTrailing) {
            if scrolledUp && !showingResults {
                Button { move { $0.scrollTo(edge: .bottom) } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                .accessibilityLabel("Scroll to bottom")
                .padding(.trailing, 16)
                .padding(.bottom, ui.bottomInset + 12)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: scrolledUp)
        // What Otto is doing, in one quiet line above the composer, as on the Mac: only while the
        // thinking bubble is scrolled out of view and the connection is fine, so the step is never on screen twice.
        .overlay(alignment: .bottomLeading) {
            if scrolledUp && !showingResults && thread.typing && thread.connected, let step = thread.typingStatus, !step.isEmpty {
                HStack(spacing: 6) {
                    OttoAvatar(size: 13, thinking: true)
                    Text(step).lineLimit(1).truncationMode(.tail)
                        .contentTransition(.interpolate)
                        .animation(.snappy, value: step)
                }
                .font(size: 12, design: .monospaced, relativeTo: .caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore).accessibilityLabel("Otto: \(step)")
                .padding(.leading, 20).padding(.trailing, 72)
                .padding(.bottom, ui.bottomInset + 6)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // Messages opens the contact card by zooming it out of the header, glass over the blurred
        // thread, edge to edge (measured off a screen recording), and closes it back into the header.
        .fullScreenCover(isPresented: $showDetails) {
            DetailsView()
                .navigationTransition(.zoom(sourceID: "card", in: card))
                .presentationBackground {
                    // Liquid Glass over the thread, as Messages does, with a wash in both modes so the
                    // thread's bubbles and the header's face don't show through as smudges.
                    Color.clear.glassEffect(.regular, in: .rect)
                        .overlay(Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.45) : UIColor.systemGroupedBackground.withAlphaComponent(0.55) }))
                        .ignoresSafeArea()
                }
        }
        .fullScreenCover(isPresented: $webCall) { CallView(context: callContext) }
        .fullScreenCover(isPresented: Binding(get: { WalkieLauncher.shared.open }, set: { WalkieLauncher.shared.open = $0 })) { WalkieView() }
        .fullScreenCover(isPresented: Binding(get: { MediaViewer.shared.start != nil }, set: { if !$0 { MediaViewer.shared.start = nil } })) {
            MediaViewerView(store: store).presentationBackground(.clear)
        }
        .alert("Calling Otto", isPresented: $showCall) {
            Button("OK", role: .cancel) {}
        } message: { Text("Add Otto’s phone number in details (tap Otto’s name).") }
    }

    @ViewBuilder private var threadList: some View {
        let messages = thread.messages
        let byWire = Dictionary(messages.map { ($0.wireID, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
                // Not lazy: rows materialised lazily went blank while UIKit animated the
                // thread's frame with the keyboard. A chat is short enough to lay out whole.
                VStack(spacing: 0) {
                    ForEach(Array(messages.enumerated()).suffix(shown), id: \.element.id) { i, m in
                        let prev = i > 0 ? messages[i - 1] : nil
                        let next = i + 1 < messages.count ? messages[i + 1] : nil
                        let newBlock = prev.map { m.date.timeIntervalSince($0.date) > 3600 } ?? true
                        if newBlock { Stamp(date: m.date, yesterday: pipsOn) }
                        if m.isPipLine {
                            PipLine(message: m, afterLine: !newBlock && prev?.isPipLine == true, highlighted: flashed == m.id).id(m.id).transition(.opacity)
                        } else if m.from == .terminal {
                            TerminalLine(message: m, afterStamp: newBlock).id(m.id).transition(.opacity)
                        } else {
                            let quote = m.replyTo.flatMap { byWire[$0] }
                            let runEnds = next?.author != m.author || next.map { $0.date.timeIntervalSince(m.date) > 3600 } ?? true
                            let runStarts = newBlock || prev?.author != m.author
                            GroupChrome(on: isGroup && m.from != .me, author: m.author, member: row?.memberStates.first { $0.id == m.author }, showName: runStarts, showFace: runEnds) {
                            Row(thread: thread, message: m,
                                quote: quote,
                                tail: runEnds,
                                receipt: m.id == lastMine && m.pending != true && m.failed != true ? receipt(for: i, in: messages) : nil,
                                fresh: m.from == .me && m.pending == true && Date.now.timeIntervalSince(m.date) < 1,
                                lift: ui.height + 12,   // the bubble starts on the field (tuned against recordings)
                                highlighted: flashed == m.id, still: still,
                                onQuote: { if let quote { jump(to: quote.id) } },
                                onSwiping: { on in
                                    if on { pinnedAtSwipe = atBottom }
                                    swiping = on
                                    // Something may have grown while the anchor was off: back down, but only
                                    // for a reader who was at the bottom; anyone reading higher stays put.
                                    if !on, pinnedAtSwipe, !atBottom { move { $0.scrollTo(edge: .bottom) } }
                                },
                                onTap: { thread.tap($0, on: m.id) },
                                plainReceipt: pipsOn,
                                inset: isGroup && m.from != .me ? 41 : 89)
                            }
                                .padding(.top, gap(group: isGroup && m.from != .me, runStarts: runStarts, stamped: newBlock || prev?.from == .terminal, sameAuthor: prev?.author == m.author))
                                .id(m.id)
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    guard m.id == newestOtto?.id else { return }
                                    visibleNewest = visible ? m.id : nil
                                }
                                // Yours lifts out of the text field, as wide as the field and blurred,
                                // and narrows into its bubble (Messages, measured off a screen recording);
                                // Otto's grows out of its tail corner.
                                .transition(.asymmetric(
                                    // Yours morphs out of the field inside the row (see Row.fresh), so the row itself just appears.
                                    insertion: m.from == .me
                                        ? .identity
                                        // Otto's takes the typing bubble's place: it cross-fades out of the dots, a
                                        // little blurred, without moving (measured off a recording of Messages).
                                        : .opacity.combined(with: .modifier(active: Blurred(radius: 4), identity: Blurred(radius: 0))),
                                    removal: .opacity))
                        }
                    }
                    if thread.typing {
                        Typing(status: thread.typingStatus, todos: thread.typingTodos, connected: thread.connected).padding(.top, 10).id("typing")
                            .transition(still ? .opacity : .asymmetric(insertion: .scale(scale: 0.5, anchor: .bottomLeading).combined(with: .opacity),
                                                                       removal: .opacity))
                    }
                    if !thread.isOtto {
                        ForEach(row?.activity ?? []) { a in
                            ActivityLine(member: a, withFace: isGroup) { store.pips.press($0, in: thread.conversationID) }
                                .id("activity-\(a.id)")
                                .transition(still ? .opacity : .scale(scale: 0.5, anchor: .bottomLeading).combined(with: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 16)
                // Past the composer's 16pt fade, so the newest line ("Will send when back online", "Read") sits clear of it.
                .padding(.bottom, 18)
        }
        // On the scroll view, not the stack: the bottom anchor's offset change then rides the same
        // animation as the rows. On the stack, the rows animated while the offset jumped, and every
        // new bubble, the dots coming or going, or a tapback shoved the thread down a frame before
        // it slid back (measured frame by frame with -shiftLab). A burst (a catch-up) lands in one step
        // rather than sliding the whole thread by all of it.
        .animation(thread.animated && !burst ? .spring(response: 0.42, dampingFraction: 0.82) : nil, value: messages.count)
        // After this update's other handlers have run, so they all still see a burst as one.
        .onChange(of: messages.count, initial: true) { _, n in Task { counted.rows = n } }
        // Under Reduce Motion these heights change in one step; the rows' own fades still play.
        .animation(still ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: thread.typing)
        .animation(still ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: row?.activity.map(\.id))
        // The thinking bubble's to-do list and a tapback's room above a bubble change heights too.
        .animation(still ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: thread.typingTodos)
        // A new step's line can wrap to two, or back to one: the bubble's height follows smoothly.
        .animation(still ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: thread.typingStatus)
        .animation(still ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: messages.map(\.reaction))
        // Pinned to the bottom as content grows (new bubbles, typing dots, the keyboard),
        // so nothing has to scroll after the fact and fight the insert animation.
        .scrollPosition($scroll)
        .scrollDisabled(swiping)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Off mid-swipe: the anchor's offset fix for a row that grew (Otto's tapback landing) cancelled
        // the finger's drag (found by recording one landing mid-swipe). The release puts it right (below).
        .defaultScrollAnchor(swiping ? nil : .bottom, for: .sizeChanges)
        // The composer rides the keyboard's layout guide, so it follows a drag-to-dismiss.
        .scrollDismissesKeyboard(.interactively)
        // Tapping anywhere in the thread puts the keyboard away; buttons still win their own taps.
        .contentShape(.rect)
        .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        // Your own send always comes back down, like Messages, even from far up the thread. One of
        // yours from another device (a catch-up) doesn't pull a reader away from older messages.
        .onChange(of: lastMine) {
            let sent = thread.messages.last(where: { $0.from == .me })?.pending == true
            move(follow: !sent) { $0.scrollTo(edge: .bottom) }
        }
        // The thinking bubble can be tall (steps, a to-do list). When it goes, the thread is
        // shorter by that much; a reader at the bottom stays at the bottom instead of being left
        // looking at older messages.
        .onChange(of: thread.typing) { _, on in
            if !on { move(.spring(response: 0.42, dampingFraction: 0.82), follow: true) { $0.scrollTo(edge: .bottom) } }
        }
        // What the composer and keyboard cover. A SwiftUI margin rather than a UIKit safe-area
        // inset: SwiftUI applied the inset in one jump and then scrolled after it on its own
        // curve, so the thread lurched. Now the margin and the scroll move together, on the
        // keyboard's curve.
        .contentMargins(.bottom, margin, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { offset.y = $1 }
        // Pulled down past the top and let go: the search field, as in Messages and Mail.
        .onScrollPhaseChange { old, _ in if old == .interacting, offset.y < -50 { openSearch() } }
        .onScrollGeometryChange(for: Bool.self, of: { g in
            g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY < 4
        }) { _, at in atBottom = at }
        .onScrollGeometryChange(for: Bool.self, of: { g in
            g.contentSize.height + g.contentInsets.bottom - g.visibleRect.maxY > 400
        }) { _, up in
            scrolledUp = up
            if !up { shown = Self.page }   // back at the newest: drop the pages read on the way up
        }
        // Near the top: the next page of older messages, going in above what's on screen.
        .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y + $0.contentInsets.top < 600 }) { _, near in
            guard near, shown < thread.messages.count else { return }
            counted.paging = true
            shown += Self.page
        }
        // Once it's laid out, down by exactly its height in one step, so the bubbles being read don't move.
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { old, new in
            guard counted.paging else { return }
            counted.paging = false
            move(nil) { $0.scrollTo(y: offset.y + new - old) }
        }
        .onChange(of: ui.bottomInset) { old, new in
            // A drag-to-dismiss, frame by frame: follow it, and never scroll under the finger. Or a search result opening.
            guard ui.insetAnimated, !counted.landing else { margin = new; return }
            if new > old {
                // A reader at the bottom stays there; one up the thread keeps the same bubbles in view, now above the keyboard.
                move(ComposerUI.keyboard, keyboard: true) {
                    margin = new
                    if atBottom { $0.scrollTo(edge: .bottom) } else { $0.scrollTo(y: offset.y + new - old) }
                }
            } else {
                // Shrinking the margin first clamps the offset in one frame (the snap). Slide the
                // thread down by the same amount on the keyboard's curve, then let the margin go.
                move(ComposerUI.keyboard, keyboard: true, then: { margin = ui.bottomInset }) {
                    $0.scrollTo(y: max(0, offset.y - (old - new)))
                }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: lastMine)
        #if DEBUG
        // `-search <words>`: the thread searched for them, keyboard down (up with `-searchFocus`), for screenshots.
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: "-search"), i + 1 < args.count else { return }
            if args.contains("-searchFocus") { openSearch() } else { ui.searching = true }
            query = args[i + 1]
            // With `-searchJump`, then to the oldest match once the older history is in, as a tap would.
            guard args.contains("-searchJump") else { return }
            try? await Task.sleep(for: .seconds(3))
            if let first = hits.first { show(first) }
        }
        #endif
        #if PERFDEMO
        // `-scrollDemo`: up to the top a few times, then home, printing the window each time.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-scrollDemo") else { return }
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<4 {
                move(.default) { $0.scrollTo(edge: .top) }
                try? await Task.sleep(for: .seconds(1.5))
                print("SCROLL top shown=\(shown) offset=\(Int(offset.y))")
            }
            move(.default) { $0.scrollTo(edge: .bottom) }
            try? await Task.sleep(for: .seconds(1.5))
            print("SCROLL bottom shown=\(shown) scrolledUp=\(scrolledUp)")
        }
        #endif
        #if DEBUG
        // `-scrollLab` (with `-refThread -longRef -noNotificationPrompt`): every way the thread scrolls, one
        // at a time, to record with Reduce Motion off and on. Each step prints "LAB <s> > <what>" just before
        // it runs and "LAB <s> <what> <offset before> -> <offset after>" once it has settled.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-scrollLab") else { return }
            // Numbered, so a jump can't hide behind -longRef's repeats.
            store.messages = store.messages.enumerated().map { i, m in var m = m; m.text = "\(i + 1) · \(m.text)"; return m }
            let t0 = Date.now
            func say(_ s: String) { print(String(format: "LAB %5.2f ", Date.now.timeIntervalSince(t0)) + s); fflush(stdout) }
            func step(_ what: String, _ f: () -> Void) async {
                try? await Task.sleep(for: .seconds(1.5))
                say("> \(what)")
                try? await Task.sleep(for: .seconds(0.8))   // a screenshot of before
                let before = Int(offset.y)
                f()
                try? await Task.sleep(for: .seconds(1.2))
                say("\(what) \(before) -> \(Int(offset.y))")
            }
            try? await Task.sleep(for: .seconds(1))
            say("reduceMotion=\(still)")
            await step("scroll up") { move(nil) { $0.scrollTo(y: offset.y - 1200) } }
            await step("receive while up") { store.messages.append(Message(from: .otto, text: "this one lands while you’re reading up there")) }
            await step("dots on while up") { store.ottoTyping = true }
            await step("dots off while up") { store.ottoTyping = false }
            await step("keyboard up while up") { store.demoFocus = true }
            await step("keyboard down while up") { store.demoFocus = false }
            await step("near the top") { move(nil) { $0.scrollTo(y: 700) } }
            await step("older page") { move(nil) { $0.scrollTo(y: 590) } }
            await step("to the bottom") { move { $0.scrollTo(edge: .bottom) } }
            await step("keyboard up") { store.demoFocus = true }
            await step("send") { store.send("on my way") }
            await step("receive") { store.messages.append(Message(from: .otto, text: "see you there")) }
            await step("burst of 8") { store.messages += (1...8).map { Message(from: $0 % 3 == 0 ? .me : .otto, text: "caught up \($0)", read: true) } }
            await step("keyboard down") { store.demoFocus = false }
            say("end")
        }
        #endif
    }

    static func sideStoreInstall(_ ipa: String) -> URL? {
        var c = URLComponents()
        c.scheme = "sidestore"; c.host = "install"
        c.queryItems = [URLQueryItem(name: "url", value: ipa)]
        return c.url
    }

    /// Otto's header, and under it a live call or the flight-day card.
    private var ottoTop: some View {
        VStack(spacing: 8) {
            header
            if ui.searching {
                SearchBar(query: $query, focused: $searchFocused, close: { closeSearch() })
                    .transition(still ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if thread.isOtto, let live = calls.live {
                CallBanner(call: live) { openCall = live }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if thread.isOtto, let card = gate.visible() {
                GateBanner(card: card) { showGate = true }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: calls.live?.id)
        .animation(.snappy, value: gate.card?.key)
        // The thread fades out under the bar, as in Messages: the soft scroll edge alone blurs only up by the
        // status bar, so bubbles read sharp behind the face and the banners. Solid under the bar, then a 40pt
        // fade below it, longer than a line of text so the line there fades instead of looking sliced.
        // A pull down on the bar's empty space opens search too: the top of a long thread is a long way up.
        // Behind the buttons, so they keep their own touches.
        .background {
            ZStack {
                VStack(spacing: 0) {
                    Color(.systemBackground)
                    LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 40)
                }
                .padding(.bottom, -40)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                Color.clear.contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 50 { openSearch() } })
            }
        }
    }

    /// With only Otto, today's picture. With pips, everyone is a solid, Otto included.
    @ViewBuilder private var title: some View {
        if let row, row.isGroup {
            Button { store.pips.sheet = .group(row.id) } label: {
                HeaderTitle(name: row.name) { GroupFace(id: row.id, members: row.pips.map(\.look), otto: row.otto?.look, size: 68) }
            }
            .padding(.top, -7)
        } else if let row, row.kind == "pip", let pip = row.pips.first {
            Button { store.pips.sheet = .pip(pip.id) } label: {
                HeaderTitle(name: row.name) { FaceView(look: pip.look, size: 68, live: true).frame(width: 68, height: 68) }
            }
            .padding(.top, -7)
        } else if pipsOn {
            Button { showDetails = true } label: {
                HeaderTitle(name: "Otto") { FaceView(look: ottoLook, size: 68, live: true).frame(width: 68, height: 68) }
            }
            .padding(.top, -7)
            .matchedTransitionSource(id: "card", in: card)
        } else {
            Button { showDetails = true } label: {
                VStack(spacing: -6) {
                    OttoAvatar(size: 60, thinking: store.ottoTyping, asleep: store.asleep)
                    HStack(spacing: 4) {
                        Text("Otto").font(size: 15, weight: .semibold, relativeTo: .subheadline)
                        Image(systemName: "chevron.right").font(size: 11, weight: .semibold, relativeTo: .caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .matchedTransitionSource(id: "card", in: card)
        }
    }

    private var ottoLook: FaceLook {
        let base = row?.otto?.look ?? .otto
        if store.asleep { return base.with(.asleep) }
        return store.ottoTyping ? base.with(.working) : base
    }

    private var header: some View {
        ZStack {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .tint(.primary)
                    .accessibilityLabel("Conversations")
                }
                if let u = store.update, let link = Self.sideStoreInstall(u.ipa) {
                    // SideStore downloads, re-signs and installs; it asks before replacing the app.
                    // A glass circle like the bar's others, so it never crowds the face.
                    Button { openURL(link) } label: {
                        Image(systemName: "arrow.down").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                    }
                    .tint(.white)
                    .accessibilityLabel("Update Otto")
                }
                Spacer()
                Button {
                    // Web call (free, over the internet) when Vapi is set up; the phone line otherwise.
                    let digits = callNumber.filter { $0.isNumber || $0 == "+" }
                    if CallManager.configured { webCall = true }
                    else if let url = URL(string: "tel:\(digits)"), !digits.isEmpty { openURL(url) }
                    else { showCall = true }
                } label: {
                    Image(systemName: "phone").font(.system(size: 18))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                // Long press: the walkie-talkie, for talking to Otto on the move.
                .contextMenu {
                    Button("Walkie-talkie", systemImage: "waveform") { walkieHint = false; WalkieLauncher.shared.open = true }
                }
                .popover(isPresented: $walkieHint, arrowEdge: .top) {
                    Label("Hold for walkie-talkie", systemImage: "waveform")
                        .font(size: 14, weight: .medium, relativeTo: .subheadline)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .presentationCompactAdaptation(.popover)
                }
                .task {
                    var due = Date.now.timeIntervalSince1970 - walkieHintAt > 60 * 86_400
                    #if DEBUG
                    if CommandLine.arguments.contains("-walkieHint") { due = true }
                    #endif
                    guard due else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    walkieHintAt = Date.now.timeIntervalSince1970
                    walkieHint = true
                    try? await Task.sleep(for: .seconds(6))
                    walkieHint = false
                }
            }
            title.tint(.primary)
                // The pull-downs' way in for VoiceOver and Full Keyboard Access.
                .accessibilityAction(named: "Search messages", openSearch)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        // Bar text grows only so far, as in Messages' own bar: past this, a name would run into the buttons.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

}


/// The text box, mic and + menu. Hosted on its own and pinned to the keyboard by KeyboardDock.
/// Photos (camera, library, or pasted into the box) wait in the box as attachments
/// until you send, like Messages.
struct Composer: View {
    @Environment(OttoStore.self) private var store
    /// Reduce Motion: the buttons cross-fade instead of scaling in.
    @Environment(\.accessibilityReduceMotion) private var still
    let ui: ComposerUI
    let thread: any ChatThread
    @State private var draft = ""
    @State private var focused = false
    @State private var attachments: [Attachment] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var recorder = VoiceRecorder()
    /// The field's blue flash as a message leaves it (Messages fills the field, then lets go).
    @State private var flash = false

    struct Attachment: Identifiable { let id = UUID(); let image: UIImage }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    /// Who a group's composer can @mention.
    private var members: [PipMember] {
        guard let row = store.pips.row(thread.conversationID), row.isGroup else { return [] }
        return row.memberStates
    }
    /// The `@Fa` being typed at the end of the draft.
    private var mentioning: Substring? {
        guard let word = draft.split(separator: " ", omittingEmptySubsequences: false).last, word.first == "@" else { return nil }
        return word.dropFirst()
    }
    private var mentionMatches: [PipMember] {
        guard let q = mentioning else { return [] }
        return members.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
    }
    private func mention(_ m: PipMember) {
        guard let q = mentioning else { return }
        draft = draft.dropLast(q.count + 1) + "@\(m.name) "
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
        VStack(alignment: .leading, spacing: 8) {
        if !mentionMatches.isEmpty {
            MentionBar(members: mentionMatches, pick: mention).transition(.opacity)
        }
        HStack(alignment: .bottom, spacing: 12) {
            if thread.isOtto {
            Menu {
                Button("Camera", systemImage: "camera") { showCamera = true }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button("Photos", systemImage: "photo.on.rectangle") { showLibrary = true }
            } label: {
                Image(systemName: "plus").font(.system(size: 19, weight: .medium))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .tint(.secondary)
            .accessibilityLabel("Add photo")
            }

            VStack(alignment: .leading, spacing: 0) {
                if let m = replying, recorder.started == nil { replyBar(m) }
                if !attachments.isEmpty && recorder.started == nil { strip }
                HStack(alignment: .bottom, spacing: 0) {
                    if let started = recorder.started {
                        Button { withAnimation(.snappy) { recorder.cancel() } } label: {
                            Image(systemName: "xmark").frame(width: 36, height: 36)
                        }
                        .tint(.secondary)
                        .accessibilityLabel("Cancel recording")
                        TimelineView(.periodic(from: started, by: 1)) { tl in
                            let s = Int(tl.date.timeIntervalSince(started))
                            HStack(spacing: 8) {
                                ThinkingOrb(state: .listening, size: .px20)
                                Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .transition(.opacity)
                        Button { withAnimation(.snappy) { if let url = recorder.stop() { store.sendVoice(url, replyTo: store.takeReply()) } } } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.red)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel("Send voice message")
                    } else {
                        ComposerTextView(text: $draft, focused: $focused, placeholder: "Message", mentions: members.map(\.name)) { images in
                            // Group and pip threads have no photos on the server.
                            guard thread.isOtto else { return }
                            withAnimation(.snappy) { attachments += images.map { Attachment(image: $0) } }
                        }
                        .transition(.opacity)
                        if !canSend {
                            if thread.isOtto {
                            Button { Task { await recorder.start() } } label: {
                                Image(systemName: "waveform").frame(width: 36, height: 36)
                            }
                            .tint(.secondary)
                            .accessibilityLabel("Record voice message")
                            .transition(still ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                            }
                        } else {
                            // Messages' send: a 37×27 pill, 6.5pt in from the field's corner (measured off a screenshot).
                            Button(action: send) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 37, height: 27)
                                    .background(Color(red: 0.525, green: 0.553, blue: 0.592), in: .capsule)
                            }
                            .padding(.trailing, 6.5).padding(.bottom, 4.5)   // centred in a one-line field (measured), like Messages
                            .accessibilityLabel("Send")
                            .transition(still ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: canSend)
            .animation(.snappy(duration: 0.22), value: recorder.started != nil)
            .frame(minHeight: 40)
            .background(Color.outgoingBubble.opacity(flash ? 0.9 : 0), in: .rect(cornerRadius: 20, style: .continuous))
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        }
        }
        .animation(.snappy(duration: 0.22), value: mentionMatches.map(\.id))
        }
        // Messages pulls the bar in toward the edges while the keyboard is up.
        .padding(.horizontal, focused ? 15 : 27)
        // Measured off Messages: 16pt from the field to the keyboard, 28pt to the screen edge without it.
        // The dock stops at the home indicator (34pt), so without the keyboard the bar sinks 10pt past it.
        .padding(.bottom, focused ? 12 : 0)
        .offset(y: focused ? 0 : 10)
        .animation(.snappy, value: focused)
        .padding(.top, 6)   // this 6 and the offset's 10: the empty strip KeyboardDock.loadView passes to the thread (keyboard down)
        .padding(.bottom, 4)
        // Folded away, not removed, while the thread is searched: a draft stays as it was. Not clipped:
        // the offset above sinks the bar 10pt past its frame with the keyboard down, and opacity hides it here.
        .frame(height: ui.searching ? 0 : nil, alignment: .top)
        .opacity(ui.searching ? 0 : 1)
        .allowsHitTesting(!ui.searching)
        .accessibilityHidden(ui.searching)
        .onChange(of: ui.searching) { ui.relayout() }
        .onChange(of: focused) { ui.focused = focused }
        .onChange(of: draft) { ui.relayout() }
        #if DEBUG
        .onChange(of: store.demoDraft) { if let d = store.demoDraft { draft = d } }
        .onChange(of: store.demoFocus) { focused = store.demoFocus }
        #endif
        .onChange(of: attachments.count) { ui.relayout() }
        .onChange(of: recorder.started != nil) { ui.recording = recorder.started != nil; ui.relayout() }
        .onAppear { [recorder] in ui.level = { recorder.level() } }
        .onChange(of: thread.replyingTo) { if thread.replyingTo != nil { focused = true }; ui.relayout() }
        #if DEBUG
        // Layout checks without a keyboard or a server: `-growDraft` types, `-seedDraft`
        // fills the box, `-seedAttachments` adds two photos, `-keyboardDemo` loops focus,
        // `-recordDemo` starts a voice note.
        .task {
            let args = ProcessInfo.processInfo.arguments
            // The seeds land once the thread has settled at the bottom, as typing would, so the
            // composer growing keeps the newest bubble in view the way it does for real.
            if args.contains("-seedAttachments") || args.contains("-seedDraft") { try? await Task.sleep(for: .seconds(1)) }
            if args.contains("-seedAttachments") {
                attachments = [UIColor.systemOrange, .systemTeal].map { c in
                    Attachment(image: UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { ctx in c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) })
                }
            }
            if args.contains("-growDraft") {
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(120)); draft += "typing more words " }
            }
            if args.contains("-recordDemo") { await recorder.start() }
            // `-kbdDemo <text>`: the Otto keyboard's screenshots. Focuses the box with <text> in it;
            // a leading "#kbd …" line drives the keyboard's DEBUG preview (OttoKeyboard/Preview.swift).
            if let i = args.firstIndex(of: "-kbdDemo"), i + 1 < args.count { draft = args[i + 1]; focused = true }
            if args.contains("-seedDraft") {
                draft = String(repeating: "a long draft that should make the box grow. ", count: 5)
            }
            guard args.contains("-keyboardDemo") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2)); focused = true
                try? await Task.sleep(for: .seconds(2)); focused = false
            }
        }
        #endif
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.started != nil)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in withAnimation(.snappy) { attachments.append(Attachment(image: img)) } }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $picked, maxSelectionCount: 10, matching: .images)
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        withAnimation(.snappy) { attachments.append(Attachment(image: img)) }
                    }
                }
            }
        }
    }

    private var replying: Message? { thread.replyingTo.flatMap { id in thread.messages.first { $0.id == id } } }

    /// What a swipe picked to answer, with an ✕ to drop it.
    private func replyBar(_ m: Message) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(m.from == .me ? "Replying to yourself" : "Replying to \(thread.name)").font(size: 12, weight: .semibold, relativeTo: .caption)
                Text(Row.summary(m))
                    .font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { withAnimation(.snappy) { thread.replyingTo = nil } } label: {
                Image(systemName: "xmark.circle.fill").font(size: 18, relativeTo: .body).foregroundStyle(.secondary)
                    // A 44pt-wide target without growing the bar; not so tall it takes taps meant for the field below.
                    .padding(.horizontal, 13).padding(.vertical, 6).contentShape(.rect).padding(.horizontal, -13).padding(.vertical, -6)
            }
            .accessibilityLabel("Cancel reply")
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 14).padding(.top, 10)
        .transition(.opacity)
    }

    /// Thumbnails waiting to go, each with an ✕ to take it back out.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Image(uiImage: a.image).resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { withAnimation(.snappy) { attachments.removeAll { $0.id == a.id } } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.6))
                                    .font(.system(size: 20))
                            }
                            .padding(3)
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    /// Photos go first, each its own bubble; the text rides on the last one as its caption.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = attachments
        guard !text.isEmpty || !photos.isEmpty else { return }
        // A reply goes with the first photo; the text rides on the last as its caption.
        let reply = photos.isEmpty ? nil : store.takeReply()
        for (i, a) in photos.enumerated() {
            store.sendPhoto(a.image, caption: i == photos.count - 1 ? text : "", replyTo: i == 0 ? reply : nil)
        }
        if photos.isEmpty { thread.send(text) }
        withAnimation(.snappy) { attachments = [] }
        draft = ""
        flash = true
        withAnimation(.easeOut(duration: 0.2)) { flash = false }
    }
}

/// UITextView rather than TextField, for one thing: pasting an image. It lands in the
/// composer as an attachment instead of being refused.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    /// Names to set in bold after an @; empty everywhere but a group.
    var mentions: [String] = []
    let onImages: ([UIImage]) -> Void
    private static let maxLines: CGFloat = 6

    func makeUIView(context: Context) -> PastingTextView {
        let v = PastingTextView()
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.isScrollEnabled = false
        v.textContainerInset = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 4)
        v.textContainer.lineFragmentPadding = 0
        v.delegate = context.coordinator
        v.placeholder.text = placeholder
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: PastingTextView, context: Context) {
        v.onImages = onImages
        if v.text != text { v.text = text; Self.boldMentions(v, mentions) }
        v.placeholder.isHidden = !text.isEmpty
        if focused && !v.isFirstResponder { DispatchQueue.main.async { v.becomeFirstResponder() } }
        if !focused && v.isFirstResponder { DispatchQueue.main.async { v.resignFirstResponder() } }
    }

    /// Grows line by line up to six, then scrolls inside.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = (v.font?.lineHeight ?? 22) * Self.maxLines + v.textContainerInset.top + v.textContainerInset.bottom
        v.isScrollEnabled = fit > cap
        return CGSize(width: width, height: min(fit, cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Attributes only, so the caret stays put; nothing mid-composition, where they'd break the input method.
    static func boldMentions(_ v: UITextView, _ names: [String]) {
        guard !names.isEmpty, v.markedTextRange == nil,
              let re = try? NSRegularExpression(pattern: "(?<![\\w@])@(" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")\\b", options: .caseInsensitive) else { return }
        let body = UIFont.preferredFont(forTextStyle: .body)
        let whole = NSRange(location: 0, length: v.textStorage.length)
        v.textStorage.beginEditing()
        v.textStorage.addAttribute(.font, value: body, range: whole)
        for m in re.matches(in: v.text, range: whole) {
            v.textStorage.addAttribute(.font, value: UIFont.systemFont(ofSize: body.pointSize, weight: .semibold), range: m.range)
        }
        v.textStorage.endEditing()
        v.typingAttributes[.font] = body
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(_ p: ComposerTextView) { parent = p }
        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            ComposerTextView.boldMentions(v, parent.mentions)
            (v as? PastingTextView)?.placeholder.isHidden = !v.text.isEmpty
            if v.isScrollEnabled { v.scrollRangeToVisible(v.selectedRange) }   // past six lines, follow the caret
        }
        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }
    }
}

final class PastingTextView: UITextView {
    var onImages: ([UIImage]) -> Void = { _ in }
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.textColor = .placeholderText
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                                   width: bounds.width - textContainerInset.left - textContainerInset.right,
                                   height: placeholder.intrinsicContentSize.height)
    }

    // Paste is offered when the clipboard holds an image, which a plain text view refuses.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) && UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if board.hasImages, let images = board.images, !images.isEmpty {
            onImages(images)
            return
        }
        super.paste(sender)
    }
}

// MARK: - Pieces (Unchanged)

struct Stamp: View {
    let date: Date
    /// The pips mockup says "Yesterday"; the one-thread app keeps its weekday.
    var yesterday = false
    var body: some View {
        let day = Calendar.current.isDateInToday(date) ? "Today" : yesterday && Calendar.current.isDateInYesterday(date) ? "Yesterday" : date.formatted(.dateTime.weekday(.wide))
        (Text(day).fontWeight(.semibold) + Text(" " + date.formatted(date: .omitted, time: .shortened)))
            .font(size: 11, relativeTo: .caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14).padding(.bottom, 8)
    }
}

/// A prompt typed into Otto's terminal, set like a Stamp: the time and its first words.
private struct TerminalLine: View {
    let message: Message
    /// Right under a Stamp, which already has the spacing above.
    let afterStamp: Bool
    @Environment(\.dynamicTypeSize) private var type
    var body: some View {
        (Text(Image(systemName: "terminal")) + Text(" " + message.date.formatted(date: .omitted, time: .shortened)).fontWeight(.semibold)
            + Text(" \u{201C}\(message.text)\u{201D}"))
            .font(size: 11, relativeTo: .caption2)
            .foregroundStyle(.secondary)
            // One line, until the text is so large that one line would hold only the time.
            .lineLimit(type.isAccessibilitySize ? 3 : 1).truncationMode(.tail)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, afterStamp ? 0 : 14).padding(.bottom, 8)
            .accessibilityLabel("You, in the terminal at \(message.date.formatted(date: .omitted, time: .shortened)): \(message.text)")
    }
}

private struct Row: View {
    let thread: any ChatThread
    let message: Message
    /// The message this one answers, shown small above the bubble.
    let quote: Message?
    let tail: Bool
    /// Under your newest message: true is "Read", false "Delivered", nil nothing.
    let receipt: Bool?
    /// Just sent from the composer: the bubble starts as the text field and morphs into place.
    var fresh = false
    /// From the bubble's bottom down to the text field's bottom, before the receipt line.
    var lift: CGFloat = 0
    /// Just jumped to from a quote.
    var highlighted = false
    /// Reduce Motion: the highlight brightens without growing.
    var still = false
    var onQuote: () -> Void = {}
    var onSwiping: (Bool) -> Void = { _ in }
    let onTap: (ActionButton) -> Void
    @Environment(OttoStore.self) private var store
    /// The mockup's plain "Read", once there are pips; today's "Read 8:06" with only Otto.
    var plainReceipt = false
    /// The empty space beside the bubble. A group's bubble starts further in, past the face.
    var inset: CGFloat = 89
    @GestureState private var dragging = false
    @State private var morph: Double = 1
    @State private var swipe: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    /// The message itself, so a swipe on the empty side of the row does nothing.
    @State private var bubbleWidth: CGFloat = 0
    /// Decided on a drag's first move: sideways is a reply swipe, anything else belongs to the scroll.
    @State private var sideways: Bool?
    @State private var reacted = 0
    /// A flick that replied without reaching the mark, so the arming tick never came.
    @State private var flicked = 0
    @State private var selecting = false
    @State private var link: URL?
    @State private var sharing: URL?
    @State private var whyShown = false
    @State private var preview: LPLinkMetadata?
    @Environment(\.openURL) private var openURL
    private var mine: Bool { message.from == .me }
    private var text: AttributedString { Self.linked(message.text) }

    /// The text with its URLs marked as links (underlined, so they read on either bubble colour).
    /// A long one shows as its start and "…"; the link itself stays whole.
    static func linked(_ s: String) -> AttributedString {
        if let hit = linkedCache[s] { return hit }
        let a = detectLinks(s)
        linkedCache[s] = a
        return a
    }
    /// Every row asks on every pass of the thread; detection costs a millisecond or so a bubble.
    @MainActor private static var linkedCache: [String: AttributedString] = [:]
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func detectLinks(_ s: String) -> AttributedString {
        guard let d = detector else { return AttributedString(s) }
        var a = AttributedString()
        var rest = s.startIndex
        for m in d.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let url = m.url, let r = Range(m.range, in: s) else { continue }
            a += AttributedString(s[rest..<r.lowerBound])
            var shown = String(s[r])
            if shown.count > 40 {
                for p in ["https://", "http://", "www."] where shown.hasPrefix(p) { shown.removeFirst(p.count) }
                if shown.count > 40 { shown = shown.prefix(36) + "…" }
            }
            var piece = AttributedString(shown)
            piece.link = url
            piece.underlineStyle = .single
            a += piece
            rest = r.upperBound
        }
        a += AttributedString(s[rest...])
        return a
    }
    /// What goes in the bubble: a draft card, a voice note, or the text.
    @ViewBuilder private var content: some View {
        if let d = Self.draft(message) {
            VStack(alignment: .leading, spacing: 8) {
                Text(d.head).font(size: 15, weight: .semibold, relativeTo: .subheadline)
                Text(Self.linked(d.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(.systemBackground).opacity(0.55), in: .rect(cornerRadius: 12, style: .continuous))
            }
            .padding(.vertical, 3)
        } else if message.isVoice || message.audio != nil {
            VStack(alignment: .leading, spacing: 6) {
                VoiceRow(message: message, mine: mine)
                // What Otto said, so it reads as the message: full-strength text, only smaller.
                if !mine, !message.text.isEmpty { Text(Self.linked(message.text)).font(size: 13, relativeTo: .footnote) }
            }
        } else {
            Text(text)
        }
    }

    /// The tap "Less of this" sends: self-contained, like any button data, so it still reads days later.
    static func lessOfThis(_ m: Message) -> String {
        "less of this: \(m.src ?? "unknown") — re: \"\(m.text.prefix(40))\""
    }
    /// The first link worth a card: not for photos, voice notes, audio or drafts.
    static func previewURL(_ m: Message) -> URL? {
        if m.isPhoto || m.isVoice || m.audio != nil || draft(m) != nil { return nil }
        return linked(m.text).runs.lazy.compactMap(\.link).first
    }
    /// A message that is nothing but the link: the bubble gives way to the card once metadata lands (Messages behaviour).
    static func isOnlyLink(_ m: Message, _ url: URL) -> Bool {
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == url.absoluteString || URL(string: t)?.absoluteString == url.absoluteString
    }
    /// A photo or file with no words is only itself: no empty bubble under it. A voice note is its bubble.
    /// A group link is only itself even with words: the server's "I started…" says what the card says.
    private var textShown: Bool {
        let attached = message.isPhoto || !(message.files ?? []).isEmpty || !(message.card?.shown.isEmpty ?? true)
        return (!attached || !message.text.isEmpty || message.isVoice || message.audio != nil) && !hidesText && message.groupLink == nil
    }
    private var hidesText: Bool { preview != nil && Self.previewURL(message).map { Self.isOnlyLink(message, $0) } == true }

    /// Otto's "draft:" messages: the first line is the heading, the rest the words that would go out.
    static func draft(_ m: Message) -> (head: String, body: String)? {
        guard m.from == .otto, let nl = m.text.firstIndex(of: "\n") else { return nil }
        let head = m.text[..<nl].trimmingCharacters(in: .whitespaces)
        guard head.lowercased().hasPrefix("draft"), head.hasSuffix(":") else { return nil }
        var body = m.text[m.text.index(after: nl)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > 1, body.first == "\"", body.last == "\"" { body = String(body.dropFirst().dropLast()) }
        return (head, body)
    }

    static let tapbacks = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
    /// What VoiceOver calls each one (Messages' names).
    static let tapbackNames = ["❤️": "Heart", "👍": "Thumbs Up", "👎": "Thumbs Down", "😂": "Ha Ha", "‼️": "Emphasize", "❓": "Question"]
    /// How far a swipe has to pull before letting go means "reply".
    private static let replyAt: CGFloat = 60

    /// The tapback row at the top of a bubble's menu; the one already on it shows selected, and
    /// picking it again takes it off.
    /// Only on Otto's: one tapback a message, and the one on yours is Otto's, not yours to change.
    @ViewBuilder static func palette(_ m: Message, react: @escaping (String) -> Void) -> some View {
        // Palette: one row of emoji, like Messages. A plain ControlGroup caps at three
        // across and stacks the rest down the menu.
        if m.from == .otto && !m.isConversation { ControlGroup {
            ForEach(tapbacks, id: \.self) { e in
                Toggle(isOn: Binding(get: { m.reaction == e }, set: { _ in react(e) })) { Text(e) }
                    .accessibilityLabel(tapbackNames[e] ?? e)
            }
        }
        .controlGroupStyle(.palette)
        // Palette buttons keep the menu open by default; a tapback should close it like Messages.
        .menuActionDismissBehavior(.enabled) }
    }

    /// What a message is, for a quote, the reply bar and VoiceOver: its words, or a word for what it holds.
    static func summary(_ m: Message) -> String {
        if !m.text.isEmpty { return draft(m)?.body ?? m.text }
        if m.isVoice || m.audio != nil { return "Voice message" }
        if m.isPhoto { return "Photo" }
        if let c = m.card { return c.title ?? "Card" }
        switch m.files?.first?.kind {
        case "image": return "Photo"
        case "video": return "Video"
        default: return m.files?.first?.name ?? "Attachment"
        }
    }

    /// Yours, from the menu, a double-tap or VoiceOver. One tap of haptic here, and none when
    /// Otto's lands, the way Messages only buzzes for what you did.
    private func settle() {
        if sideways == true { onSwiping(false) }
        sideways = nil
        guard swipe != 0 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { swipe = 0 }
    }
    /// Otto's transport has tapbacks and quoted replies; the conversation API has neither.
    private var canAnswer: Bool { thread.isOtto && !message.isConversation }
    private func react(_ e: String) {
        guard !mine, canAnswer else { return }
        thread.react(e, on: message.id); reacted += 1
    }
    private func reply() { guard canAnswer else { return }; withAnimation(.snappy) { thread.replyingTo = message.id } }
    /// A button under the bubble or on its card: copy, open, or go back to Otto as a tap.
    private func press(_ b: ActionButton) {
        if let c = b.copy { UIPasteboard.general.string = c; UINotificationFeedbackGenerator().notificationOccurred(.success) }
        else if let u = b.url.flatMap(URL.init(string:)) { openURL(u) } else { onTap(b) }
    }
    /// A draft copies as the words that would go out, without its "draft:" line.
    private func copyText() { UIPasteboard.general.string = Self.draft(message)?.body ?? message.text }
    private var firstLink: URL? { Self.linked(message.text).runs.lazy.compactMap(\.link).first }
    /// Who put the tapback there: on yours it's Otto's, on Otto's it's yours.
    private var reactor: String { mine ? thread.name : "you" }
    /// What VoiceOver reads for the bubble: who, then what.
    private var spoken: String {
        let who = mine ? "You" : thread.name
        if message.isVoice || message.audio != nil { return "\(who): voice message. \(message.text)" }
        if let d = Self.draft(message) { return "\(who): \(d.head) \(d.body)" }
        return "\(who): \(message.text)"
    }
    /// The menu's other choices, for VoiceOver, which can't long-press: links are inside the
    /// combined element, so they're here too.
    private var spokenExtras: [(String, () -> Void)] {
        var a: [(String, () -> Void)] = [("Select Text", { selecting = true })]
        if !mine, message.why != nil { a.append(("Why this?", { whyShown = true })) }
        if let url = firstLink { a.append(("Open Link", { openURL(url) })) }
        return a
    }
    /// A long message lifts as its first lines: the whole of it filled the screen and ran under the menu.
    // ponytail: a length/line-count guess, not a measurement; at the largest text sizes a shorter bubble can still fill the screen.
    private var longPreview: Bool {
        Self.draft(message) == nil && (message.text.count > 500 || message.text.filter { $0 == "\n" }.count > 12)
    }

    @ViewBuilder private var bubbleMenu: some View {
        Self.palette(message, react: react)
        if canAnswer { Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply) }
        Button("Copy", systemImage: "doc.on.doc", action: copyText)
        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = true }
        if !mine, message.why != nil {
            Divider()
            Button("Why this?", systemImage: "questionmark.circle") { whyShown = true }
        }
        // The same choices a tapped link gets, for the first link in the message.
        if let url = firstLink {
            Divider()
            Button("Open Link", systemImage: "safari") { openURL(url) }
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
            Button("Share Link…", systemImage: "square.and.arrow.up") { sharing = url }
        }
    }

    /// The menu's lifted copy of a long bubble: its first fourteen lines, the bubble's width and colours.
    private var shortBubble: some View {
        Text(text).lineLimit(14)
            .font(.body.leading(.tight))
            // Fewer lines at large text sizes: never more than about 40% of the screen.
            .frame(maxHeight: UIScreen.main.bounds.height * 0.4, alignment: .top)
            .foregroundStyle(mine ? .white : .primary)
            .padding(.horizontal, 14).padding(.vertical, 9.5)
            .frame(width: UIScreen.main.bounds.width - 121, alignment: .leading)
            .background(mine ? Color.outgoingBubble : Color.incomingBubble)
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if let quote {
                // The answered message, small and faded, on its own sender's side (Messages). Tap to go to it.
                Button(action: onQuote) {
                    // Narrower and fainter than a bubble, so it reads as a quote and not a second copy.
                    Label(Self.summary(quote), systemImage: "arrowshape.turn.up.left.fill")
                        .labelStyle(QuoteLabel())
                        .font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: 240, alignment: .leading)
                        .background(quote.from == .me ? AnyShapeStyle(Color.outgoingBubble.opacity(0.35)) : AnyShapeStyle(Color.incomingBubble.opacity(0.6)),
                                    in: .rect(cornerRadius: 14, style: .continuous))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: quote.from == .me ? .trailing : .leading)
                // Out past the row's inset when it's the other side's, so it lines up with their bubbles.
                .padding(mine ? .leading : .trailing, quote.from == message.from ? 0 : -89)
                .accessibilityLabel("In reply to \(quote.from == .me ? "you" : thread.name): \(Self.summary(quote))")
                .accessibilityHint("Shows the original message")
            }
            if let img = Thumbs.image(for: message) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 253, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .onTapGesture { MediaViewer.shared.start = message.id.uuidString }
                    .accessibilityLabel(mine ? "You: photo" : "\(thread.name): photo")
                    .accessibilityAddTraits([.isImage, .isButton])
                    .modifier(Reactable(message: message, badge: !textShown, reactor: reactor, react: react, reply: reply, copy: { UIPasteboard.general.image = img }))
            }
            ForEach(Array((message.files ?? []).enumerated()), id: \.element.id) { i, f in
                Group { if StudySet.isStudy(f) { StudyBubble(file: f) } else { RemoteFileView(file: f) } }
                    .modifier(Reactable(message: message, badge: !textShown && Thumbs.image(for: message) == nil && i == 0, reactor: reactor, react: react, reply: reply,
                                        copy: f.kind == "image" ? { if let d = MediaCache.data[f.id], let img = UIImage(data: d) { UIPasteboard.general.image = img } } : nil))
            }
            if textShown {
            VStack(alignment: .leading, spacing: 8) {
                // One element for VoiceOver, with the menu as its actions; the chips below keep their own buttons.
                content
                    .modifier(SpokenActions(message: message, label: spoken, reactor: reactor, react: react, reply: reply,
                                            copy: copyText, extra: spokenExtras))
                ForEach(message.scheduled ?? []) { ScheduleChip(trigger: $0) }
                ForEach(message.recorded ?? []) { RecordedChip(card: $0, message: message.id) }
                OTPChip(message: message)
            }
                .font(.body.leading(.tight))
                .tint(mine ? .white : .blue)
                // A tapped link asks what to do with it rather than leaving the app.
                .environment(\.openURL, OpenURLAction { url in link = url; return .handled })
                .confirmationDialog(link?.absoluteString ?? "", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }), titleVisibility: .visible) {
                    if let url = link {
                        Button("Open") { openURL(url) }
                        Button("Copy") { UIPasteboard.general.url = url }
                        Button("Share…") { sharing = url }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9.5)
                .foregroundStyle(mine ? .white : .primary)
                .background(BubbleShape(mine: mine, tail: tail).fill(mine ? .outgoingBubble : .incomingBubble))
                // Before the menu, so the bubble lifts with its tapback (and its tail), as it looks in the thread.
                .overlay(alignment: mine ? .topLeading : .topTrailing) {
                    if let r = message.reaction { Tapback(emoji: r, mine: mine) }
                }
                .padding(.top, message.reaction == nil ? 0 : 14)
                .contentShape(.contextMenuPreview, BubblePreview(mine: mine, tail: tail, badge: message.reaction != nil))
                // The field's width and place at 0, the bubble at 1: on the bubble itself, so the
                // stretch is field width over bubble width (the row is as wide as the screen).
                .modifier(SendMorph(progress: morph, lift: lift))
                .onAppear {
                    guard fresh else { return }
                    morph = 0
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { morph = 1 }
                }
                // Double-tap: ❤️ straight away, no menu. Again takes it off. Otto's only (see palette).
                // Not attached on yours, so a tap on a link there doesn't wait to see if it's a double.
                .gesture(TapGesture(count: 2).onEnded { react("❤️") }, including: mine ? .subviews : .all)
                .bubbleMenu(long: longPreview) { bubbleMenu } preview: { shortBubble }
                .sheet(isPresented: $selecting) {
                    SelectableText(text: message.text)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .alert("Why this?", isPresented: $whyShown, presenting: message.why) { _ in
                    Button("Less of this", role: .destructive) { onTap(ActionButton(label: "Less of this", data: Self.lessOfThis(message))) }
                    Button("OK", role: .cancel) {}
                } message: { Text($0) }
            }
            if let g = message.groupLink { GroupLinkBubble(group: g) { store.pips.open(g.id) } }
            if !mine, let card = message.card, !card.shown.isEmpty {
                CardView(card: card, press: press)
            }
            if let md = preview {
                // No frame here: a maxWidth frame is 280 wide and centres a narrower card in it.
                // LinkPreview already caps itself at 280 and hugs its content.
                LinkPreview(metadata: md)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    // Before the menu, so a bare link's card lifts with its tapback.
                    .overlay(alignment: mine ? .topLeading : .topTrailing) {
                        if !textShown, let r = message.reaction { Tapback(emoji: r, mine: mine) }
                    }
                    .padding(.top, !textShown && message.reaction != nil ? 14 : 0)
                    .contentShape(.contextMenuPreview, BubblePreview(mine: mine, badge: !textShown && message.reaction != nil, corner: 18))
                    .contextMenu {
                        // Part of the same message, so the same tapbacks and Reply as its bubble.
                        Self.palette(message, react: react)
                        Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
                        if let url = Self.previewURL(message) {
                            Button("Open Link", systemImage: "safari") { openURL(url) }
                            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
                            Button("Share Link…", systemImage: "square.and.arrow.up") { sharing = url }
                        }
                    }
                    // A bare link is only this card: it carries the message's actions for VoiceOver too.
                    .modifier(SpokenActions(message: message, label: nil, reactor: reactor, react: react, reply: reply,
                                            copy: nil, extra: Self.previewURL(message).map { url in
                                                [("Copy Link", { UIPasteboard.general.url = url }), ("Share Link", { sharing = url })]
                                            } ?? [], enabled: !textShown))
            }
            // What you said, under your voice note; Otto's sits inside its bubble.
            if mine, message.isVoice, !message.text.isEmpty {
                Text(message.text).font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing).padding(.trailing, 4)
            }

            // Otto's buttons read as suggested replies: plain blue text, no chrome.
            if !message.buttons.isEmpty {
                HStack(spacing: 16) {
                    ForEach(message.buttons) { b in
                        Button { press(b) } label: { Text(b.label).hitSlop() }.font(size: 15, relativeTo: .subheadline).tint(.blue)
                    }
                }
                .padding(.leading, 12)
            }

            if message.pending == true && !thread.connected {
                // Offline: it waits in the outbox and goes out on the next connection, as on the Mac.
                Text("Will send when back online").font(size: 11, relativeTo: .caption2).foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            } else if message.failed == true && message.pending == true {
                // Still retried on its own at the next connection; the tap just doesn't wait for one.
                Button { thread.retry(message.id) } label: {
                    (Text("Not delivered · ").foregroundStyle(.red) + Text("Try again").foregroundStyle(.blue)).hitSlop()
                }
                .font(size: 11, relativeTo: .caption2).buttonStyle(.plain)
                .multilineTextAlignment(.trailing)
                .padding(.trailing, 4)
            } else if message.failed == true {
                // Nothing left to send (a voice note whose audio is gone).
                Text("Not delivered").font(size: 11, relativeTo: .caption2).foregroundStyle(.red)
                    .padding(.trailing, 4)
            } else if message.pending == true {
                Text("Sending…").font(size: 11, relativeTo: .caption2).foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            } else if let receipt, plainReceipt {
                Text(receipt ? "Read" : "Delivered").font(size: 11, relativeTo: .caption2).foregroundStyle(.secondary)
                    .padding(.trailing, 2).padding(.top, -2)
            } else if let receipt {
                Group {
                    if receipt { Text("Read ").fontWeight(.semibold) + Text(message.date.formatted(date: .omitted, time: .shortened)) }
                    else { Text("Delivered").fontWeight(.semibold) }
                }
                .font(size: 12, relativeTo: .caption).foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .contentTransition(.opacity)
                .animation(.snappy, value: receipt)
            }
        }
        // On the row, not the bubble: a bare link's bubble gives way to its card, and the card shares too.
        .sheet(item: $sharing) { ShareSheet(items: [$0]).presentationDetents([.medium, .large]) }
        .task(id: message.text) {
            guard let u = Self.previewURL(message) else { preview = nil; return }   // an edit that dropped the link drops its card
            preview = LinkMeta.cached(u)
            if preview == nil { preview = await LinkMeta.load(u) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bubbleWidth = $0 }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, inset)
        .scaleEffect(highlighted && !still ? 1.03 : 1, anchor: mine ? .trailing : .leading)
        .brightness(highlighted ? 0.12 : 0)
        // Swipe right to reply, as in Messages: the row follows the finger, an arrow
        // fills in behind it, and letting go past the mark picks it.
        .offset(x: swipe)
        .background(alignment: .leading) {
            let armed = swipe >= Self.replyAt
            Image(systemName: "arrowshape.turn.up.left.circle.fill")
                .font(.system(size: 24)).foregroundStyle(.secondary)
                .opacity(min(1, Double(swipe / Self.replyAt)))
                .scaleEffect(armed ? 1.1 : 0.75)
                // Pops when the pull crosses the mark, with the haptic, rather than snapping.
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: armed)
                .offset(x: swipe - 32)
                .accessibilityHidden(true)
        }
        // The whole row takes the swipe, not just the bubble: yours start 105pt in from the edge.
        // Behind the row rather than its contentShape, which would cut off the replies' hitSlop below it.
        .background { Color.clear.contentShape(.rect) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
        .background { if !mine { LeftRowMarker() } }
        .simultaneousGesture(
            canAnswer ? DragGesture(minimumDistance: 20)
                .updating($dragging) { _, d, _ in d = true }
                .onChanged { g in
                    let t = g.translation
                    // Locked on the first move, so a drag that drifts diagonally keeps doing one thing.
                    if sideways == nil {
                        // The left fifth of a left-aligned row is the back swipe's (see LeftRowMarker).
                        // And only on the message: the empty side of the row is the thread's, not a reply.
                        let x0 = g.startLocation.x
                        let onBubble = !mine || x0 >= rowWidth - bubbleWidth - 8   // Otto's side keeps the whole row: a short bubble sits inside the back swipe's fifth
                        sideways = t.width > 0 && t.width > abs(t.height) * 1.5 && onBubble && (mine || x0 >= rowWidth / 5)
                        if sideways == true { onSwiping(true) }
                    }
                    guard sideways == true else { return }
                    // Follows the finger to the mark, then resists and eases to a stop 40pt on (Messages' rubber band).
                    let x = max(0, t.width)
                    swipe = x <= Self.replyAt ? x : Self.replyAt + 40 * (1 - exp(-(x - Self.replyAt) / 80))
                }
                .onEnded { g in
                    // Past the mark, or a quick flick that would have carried past it.
                    if sideways == true, swipe >= Self.replyAt || g.predictedEndTranslation.width > Self.replyAt * 1.5 {
                        if swipe < Self.replyAt { flicked += 1 }
                        reply()
                    }
                    settle()
                } : nil
        )
        // A drag the system took away (the menu opening, a call) never ends: put the row back anyway.
        .onChange(of: dragging) { _, on in if !on { settle() } }
        // Gone mid-swipe (paged out, replaced): don't leave the thread unable to scroll.
        .onDisappear { if sideways == true { onSwiping(false) } }
        .sensoryFeedback(.impact(weight: .light), trigger: flicked)
        .sensoryFeedback(.impact(weight: .light), trigger: swipe >= Self.replyAt) { _, new in new }
        .sensoryFeedback(.impact(weight: .light), trigger: reacted)
    }
}

/// Clears a conversation's unread dot on every device, and fetches a pip thread's history.
private struct ThreadSeen: ViewModifier {
    let pips: PipStore
    let thread: any ChatThread
    let loaded: @MainActor () async -> Void
    func body(content: Content) -> some View {
        content
            .task {
                guard pips.active else { return }
                pips.visible = thread.conversationID
                pips.markRead(thread.conversationID)
                await (thread as? PipThread)?.load()
                await loaded()
            }
            .onDisappear { if pips.visible == thread.conversationID { pips.visible = nil } }
    }
}

/// A group's bubble: the sender's name above it and a small face beside its run's last one.
private struct GroupChrome<Content: View>: View {
    let on: Bool
    let author: String
    let member: PipMember?
    let showName: Bool
    let showFace: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if on {
            let otto = author == "otto"
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if showFace, let member {
                        FaceView(look: member.look.with(.rest), size: 34).frame(width: 34, height: 34)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(width: 40)
                .padding(.bottom, -2)
                VStack(alignment: .leading, spacing: 3) {
                    if showName, let member {
                        Text(member.name).font(size: 11, relativeTo: .caption2).foregroundStyle(.secondary).padding(.leading, 14)
                    }
                    content()
                }
            }
        } else {
            content()
        }
    }
}

/// A quote's small reply arrow, set on its first line.
private struct QuoteLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon.font(size: 9, weight: .semibold, relativeTo: .footnote)
            configuration.title
        }
    }
}

/// A photo, video or file Otto sent. Photos and videos show inline and open in the media viewer, a Wallet pass opens
/// Add to Wallet, anything else opens in Quick Look.
/// A photo or video holds its place in a still box while its bytes download.
private struct RemoteFileView: View {
    @Environment(OttoStore.self) private var store
    let file: RemoteFile
    @State private var data: Data?
    @State private var thumb: UIImage?
    /// The server says it's gone (a 404).
    @State private var missing = false
    /// Anything else that kept it from loading: tap to retry, and it retries once the connection is back.
    @State private var failed = false
    @State private var tries = 0
    @State private var opening = false
    @State private var preview: URL?
    @State private var pass: PKPass?

    private var visual: Bool { file.kind == "image" || file.kind == "video" }
    private var isPass: Bool { file.name.lowercased().hasSuffix(".pkpass") }

    var body: some View {
        Group {
            if file.kind == "image", let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .onTapGesture { MediaViewer.shared.start = file.id }
                    .accessibilityLabel("Otto: photo").accessibilityAddTraits([.isImage, .isButton])
            } else if file.kind == "video", let thumb {
                Image(uiImage: thumb).resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .overlay {
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 56, height: 56).glassEffect(.regular, in: .circle)
                    }
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .contentShape(.rect)
                    .onTapGesture { MediaViewer.shared.start = file.id }
                    .accessibilityLabel("Video, \(file.name)").accessibilityAddTraits(.isButton)
            } else if visual && !missing {
                // Still downloading, or couldn't be: a box the size of what's coming, in the photo's colour when it's known.
                Group {
                    if failed {
                        Button { tries += 1 } label: {
                            Text.couldntLoad.font(size: 13, relativeTo: .footnote).multilineTextAlignment(.center).padding(12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.incomingBubble)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(file.kind == "video" ? "Couldn't load video. Retry" : "Couldn't load photo. Retry")
                    } else {
                        MediaPlaceholder(fill: MediaCache.tint(file.id) ?? .incomingBubble)
                            .accessibilityElement().accessibilityLabel(file.kind == "video" ? "Loading video" : "Loading photo")
                    }
                }
                .frame(width: file.kind == "video" ? 180 : 220, height: file.kind == "video" ? 320 : 220)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
            } else {
                Button(action: open) {
                    HStack(spacing: 8) {
                        if opening { ProgressView().controlSize(.small) }
                        else { Image(systemName: missing ? "exclamationmark.triangle" : failed ? "arrow.clockwise" : isPass ? "wallet.pass" : "doc") }
                        if failed { Text.couldntLoad.lineLimit(1) }
                        else { Text(missing ? "\(file.name) — no longer available" : isPass ? "Add to Apple Wallet" : file.name).lineLimit(1) }
                    }
                    .font(size: 15, relativeTo: .subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.incomingBubble, in: .rect(cornerRadius: 18, style: .continuous))
                }
                .tint(.primary)
                .disabled(missing || opening)
            }
        }
        .task(id: "\(file.id) \(tries)") {
            failed = false   // a file that isn't fetched until tapped just loses its error once the connection is back
            do {
                if file.kind == "video" {
                    if thumb == nil { thumb = try await MediaCache.thumbnail(file, from: store.backend); missing = thumb == nil }
                    return
                }
                if let hit = MediaCache.data[file.id] { data = hit; return }
                guard file.kind == "image" else { return }
                try await load()
            } catch { failed = !Task.isCancelled }
        }
        .onChange(of: store.connected) { if store.connected && failed { tries += 1 } }
        .quickLookPreview($preview)
        .sheet(item: $pass) { AddPassSheet(pass: $0).ignoresSafeArea() }
    }

    private func load() async throws {
        // The thread lays out whole, so every row asks at once; MediaCache fetches each file once.
        data = try await MediaCache.load(file, from: store.backend)
        missing = data == nil
    }

    private func open() {
        Task {
            opening = true; defer { opening = false }
            if data == nil {
                do { try await load(); failed = false } catch { failed = true; return }
            }
            guard let data else { return }
            if isPass, PKAddPassesViewController.canAddPasses(), let p = try? PKPass(data: data) { pass = p; return }
            let url = URL.temporaryDirectory.appending(path: file.name)
            try? data.write(to: url)
            preview = url
        }
    }
}

/// Your voice notes, kept on the phone so they play back. Otto's live on the server.
/// Your voice notes, kept in Application Support: iOS empties Caches when space runs low, and an
/// unsent note's audio is the only copy. Notes saved by older builds are still read from Caches.
/// Photos you sent, one JPEG per message in Application Support, out of the thread file.
enum ImageStore {
    static func url(_ id: UUID) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(id.uuidString).jpg")
    }
    static func data(_ id: UUID) -> Data? { try? Data(contentsOf: url(id)) }
    /// True once it's on disk (already, or now).
    static func save(_ data: Data, for id: UUID) -> Bool {
        let u = url(id)
        return FileManager.default.fileExists(atPath: u.path) || (try? data.write(to: u, options: .atomic)) != nil
    }
}

enum VoiceStore {
    static func url(_ id: UUID) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "voice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(id.uuidString).m4a")
    }
    static func data(_ id: UUID) -> Data? {
        (try? Data(contentsOf: url(id))) ?? (try? Data(contentsOf: .cachesDirectory.appending(path: "voice-\(id.uuidString).m4a")))
    }
}

/// A voice note: play, a waveform that fills as it plays, the length.
private struct VoiceRow: View {
    @Environment(OttoStore.self) private var store
    let message: Message
    let mine: Bool
    @State private var duration: TimeInterval?
    /// Peak per slice, 0…1, read from the audio itself. Flat until it's decoded.
    @State private var levels: [CGFloat]?
    private var player: AudioPlayer { .shared }
    private var key: String { message.audio?.id ?? message.id.uuidString }
    /// Every row asks on appear for its length; fetch each of Otto's files once.
    @MainActor private static var cache: [String: Data] = [:]

    var body: some View {
        let playing = player.playing == key
        let ink: Color = mine ? .white : .primary
        // Otto's text is in, its voice isn't yet: an empty bar that breathes until the clip lands.
        let waiting = !mine && message.audio == nil
        HStack(spacing: 8) {
            Button { Task { await player.toggle(key, load: load) } } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(mine ? .outgoingBubble : .incomingBubble)
                    .frame(width: 26, height: 26)
                    .background(ink, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(waiting ? 0.4 : 1)
                    // A 44pt target around the 26pt disc; the bubble's padding has the room.
                    .padding(9).contentShape(.rect).padding(-9)
            }
            .accessibilityLabel(playing ? "Pause voice message" : "Play voice message")
            .buttonStyle(.plain)
            .disabled(waiting)
            TimelineView(.animation(paused: !playing && !waiting)) { tl in
                let done = playing ? player.progress : 0
                let bars = levels ?? Array(repeating: 0, count: Self.slices)
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(bars.indices, id: \.self) { i in
                        Capsule().fill(ink.opacity(waiting ? 0.2 + 0.25 * (1 + sin(t * 4 - Double(i) * 0.45)) / 2
                                                   : Double(i) / Double(bars.count) < done ? 1 : 0.55))
                            .frame(width: 2.5, height: 3 + bars[i] * 17)
                    }
                }
                .frame(height: 20)
            }
            if let duration {
                Text(Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().font(size: 14, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(ink)
            }
        }
        .padding(.vertical, 2)
        .task(id: key) {
            guard duration == nil, let d = await load() else { return }
            duration = (try? AVAudioPlayer(data: d))?.duration
            let ext = message.audio.map { ($0.name as NSString).pathExtension } ?? "m4a"
            levels = await Task.detached { Self.levels(d, ext: ext.isEmpty ? "m4a" : ext) }.value
        }
    }

    private func load() async -> Data? {
        if let local = VoiceStore.data(message.id) { return local }
        guard let a = message.audio else { return nil }
        if let hit = Self.cache[a.id] { return hit }
        let d = try? await store.backend.file(a.id)
        Self.cache[a.id] = d
        return d
    }

    static let slices = 22

    /// The loudest sample in each slice of the note, scaled so the loudest slice is 1.
    /// Nil when the audio can't be decoded, which leaves the bars flat.
    nonisolated static func levels(_ data: Data, ext: String) -> [CGFloat]? {
        // AVAudioFile only reads from disk, and goes by the extension.
        let url = URL.temporaryDirectory.appending(path: "wave-\(UUID().uuidString).\(ext)")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData?[0] else { return nil }
        let n = Int(buf.frameLength), step = n / slices
        guard step > 0 else { return nil }
        let peaks = (0..<slices).map { i in
            var m: Float = 0
            for j in stride(from: i * step, to: (i + 1) * step, by: 8) { m = max(m, abs(ch[j])) }
            return CGFloat(m)
        }
        guard let top = peaks.max(), top > 0 else { return nil }
        return peaks.map { $0 / top }
    }
}

@MainActor @Observable final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    /// The RemoteFile id playing now.
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ id: String, load: () async -> Data?) async {
        if playing == id { stop(); return }
        stop()
        guard let data = await load(), let p = try? AVAudioPlayer(data: data) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.delegate = self
        p.play()
        player = p
        playing = id
    }

    func stop() { player?.stop(); player = nil; playing = nil }

    /// 0…1 through what's playing. Not observed: read it from a TimelineView.
    var progress: Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in if player === p { stop() } }
    }
}

/// A sent bubble on its way out of the composer: at 0 it covers the text field (its width,
/// 40pt tall, about 50pt lower) with the words blurred; at 1 it is the bubble. Measured off
/// Messages on iOS 26: the field fills blue, narrows toward the send button, lifts and
/// settles with a slight overshoot in about 0.45s.
struct SendMorph: ViewModifier, Animatable {
    var progress: Double
    /// From the row's bottom down to the text field's.
    var lift: CGFloat
    var animatableData: Double { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let q = 1 - min(max(progress, 0), 1.2)
        let lift = lift
        content.visualEffect { c, g in
            let field = CGSize(width: max(g.size.width, UIScreen.main.bounds.width - 82), height: 40)
            return c
                .scaleEffect(x: 1 + (field.width / max(g.size.width, 1) - 1) * q,
                             y: 1 + (field.height / max(g.size.height, 1) - 1) * q,
                             anchor: .bottomTrailing)
                .offset(y: lift * q)
                .blur(radius: 5 * max(q, 0))
        }
    }
}

struct Blurred: ViewModifier { let radius: CGFloat; func body(content: Content) -> some View { content.blur(radius: radius) } }

/// Rounded bubble; the last one in a run gets a tail curling out of its bottom corner.
struct BubbleShape: Shape {
    let mine: Bool
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        let p = Path(roundedRect: rect, cornerRadius: 19, style: .continuous)   // measured: Messages' corner is a touch rounder than 18
        guard tail else { return p }
        // Drawn for the left side, mirrored for yours. Union, not addPath: opposite
        var t = Path()
        let x = rect.minX
        t.move(to: CGPoint(x: x + 1, y: rect.maxY - 18))
        t.addCurve(to: CGPoint(x: x - 5, y: rect.maxY),
                    control1: CGPoint(x: x + 1, y: rect.maxY - 6), control2: CGPoint(x: x - 2, y: rect.maxY - 2))
        t.addCurve(to: CGPoint(x: x + 14, y: rect.maxY - 3),
                    control1: CGPoint(x: x + 1, y: rect.maxY + 1), control2: CGPoint(x: x + 9, y: rect.maxY - 1))
        t.addLine(to: CGPoint(x: x + 14, y: rect.maxY - 18))
        t.closeSubpath()
        if mine {
            t = t.applying(CGAffineTransform(translationX: rect.maxX + rect.minX, y: 0).scaledBy(x: -1, y: 1))
        }
        return p.union(t)
    }
}

/// What a bubble lifts as in its menu: the bubble, its tail, and the tapback on its corner
/// (the 14pt above it is the badge's room; see Tapback for where it sits).
struct BubblePreview: Shape {
    let mine: Bool
    var tail = false
    let badge: Bool
    /// A photo or card: a plain rounded rect of this radius instead of a bubble.
    var corner: CGFloat? = nil
    func path(in rect: CGRect) -> Path {
        let bubble = rect.inset(by: UIEdgeInsets(top: badge ? 14 : 0, left: 0, bottom: 0, right: 0))
        let p = corner.map { Path(roundedRect: bubble, cornerRadius: $0, style: .continuous) }
            ?? BubbleShape(mine: mine, tail: tail).path(in: bubble)
        guard badge else { return p }
        let c = CGPoint(x: mine ? bubble.minX + 2 : bubble.maxX - 2, y: bubble.minY - 1)
        return p.union(Path(ellipseIn: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32)))
    }
}

/// Long press on a photo or file: the same tapback palette a text bubble has. `badge` puts the
/// reaction on this one when there's no text bubble to carry it.
private struct Reactable: ViewModifier {
    let message: Message
    let badge: Bool
    let reactor: String
    let react: (String) -> Void
    let reply: () -> Void
    /// A photo copies as the picture; other files have nothing to copy.
    var copy: (() -> Void)? = nil
    func body(content: Content) -> some View {
        let shown = badge && message.reaction != nil
        content
            // Before the menu, so it lifts with its tapback, like a text bubble.
            .overlay(alignment: message.from == .me ? .topLeading : .topTrailing) {
                if badge, let r = message.reaction { Tapback(emoji: r, mine: message.from == .me) }
            }
            .padding(.top, shown ? 14 : 0)
            .contentShape(.contextMenuPreview, BubblePreview(mine: message.from == .me, badge: shown, corner: 18))
            .contextMenu {
                Row.palette(message, react: react)
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
                if let copy { Button("Copy", systemImage: "doc.on.doc", action: copy) }
            }
            // The message's own actions once (where the tapback sits); a photo's Copy on every photo.
            .modifier(SpokenActions(message: message, label: nil, reactor: reactor, react: react, reply: reply, copy: copy, extra: [], enabled: badge))
    }
}

/// A bubble's menu, for VoiceOver: Reply, the tapbacks (Otto's messages), Copy and the rest as
/// actions, and the tapback, with whose it is, as its value.
private struct SpokenActions: ViewModifier {
    let message: Message
    /// Makes the bubble one element read as this; nil leaves its elements as they are.
    let label: String?
    let reactor: String
    let react: (String) -> Void
    let reply: () -> Void
    let copy: (() -> Void)?
    let extra: [(String, () -> Void)]
    /// Off where another part of the same message already carries them, so they're said once.
    var enabled = true
    func body(content: Content) -> some View {
        if !enabled {
            // Only what's this part's own: a photo's Copy.
            if let copy { content.accessibilityAction(named: "Copy", copy) } else { content }
        } else {
            labelled(content)
                .accessibilityValue(message.reaction.map { "\(Row.tapbackNames[$0] ?? $0) from \(reactor)" } ?? "")
                .accessibilityAction(named: "Reply", reply)
                .accessibilityActions {
                    if message.from == .otto && !message.isConversation {
                        ForEach(Row.tapbacks, id: \.self) { e in
                            let name = Row.tapbackNames[e] ?? e
                            Button(message.reaction == e ? "Remove \(name)" : name) { react(e) }
                        }
                    }
                    if let copy { Button("Copy", action: copy) }
                    ForEach(extra.indices, id: \.self) { i in Button(extra[i].0, action: extra[i].1) }
                }
        }
    }
    @ViewBuilder private func labelled(_ content: Content) -> some View {
        if let label { content.accessibilityElement(children: .combine).accessibilityLabel(label) } else { content }
    }
}

/// The tapback on a bubble's corner: Otto's on yours in grey, yours on Otto's in your bubble's colour.
private struct Tapback: View {
    let emoji: String
    /// On your bubble, so it's Otto's.
    let mine: Bool
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        Text(emoji).font(.system(size: 16))
            .frame(width: 32, height: 32)
            .background(mine ? Color(.systemGray5) : Color.outgoingBubble, in: .circle)
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2.5))
            .offset(x: mine ? -14 : 14, y: -17)
            // Pops onto the corner with a little overshoot, and a new pick pops in over the old.
            .id(emoji)
            .transition(still ? .opacity
                        : .scale(scale: 0.3, anchor: mine ? .bottomTrailing : .bottomLeading).combined(with: .opacity)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6)))
            .accessibilityHidden(true)   // the bubble says it, as its value
    }
}

extension View {
    /// The bubble's long-press menu; a long bubble lifts as `preview` instead of itself.
    @ViewBuilder func bubbleMenu<M: View, P: View>(long: Bool, @ViewBuilder _ menu: () -> M, @ViewBuilder preview: () -> P) -> some View {
        if long { contextMenu(menuItems: menu, preview: preview) } else { contextMenu(menuItems: menu) }
    }

    /// `.system(size:)` that follows the reader's text size, scaling the way `style` does.
    /// Exactly `size` at the default text size, so the metrics measured off Messages hold there.
    /// (A text style itself would bring its own line spacing, taller than Messages' when text wraps.)
    func font(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil, relativeTo style: Font.TextStyle) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, style: style))
    }

    /// A 44pt-tall tap target for a line of text under a bubble, without moving the text.
    /// It reaches up only across the 6pt gap, never onto the bubble (its double-tap and menu),
    /// and 8pt each side, half the 16pt between suggested replies. Down, it stops where the
    /// next row starts (4–10pt on); on the newest message it runs into the composer's empty
    /// top strip, which DockView hands back to the thread: the full 44 with the keyboard down,
    /// about 30 while typing (the composer keeps its strip then).
    func hitSlop() -> some View {
        background(alignment: .top) {
            Color.clear.contentShape(.rect).frame(minHeight: 44)
                .padding(EdgeInsets(top: -6, leading: -8, bottom: 0, trailing: -8))
        }
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?
    init(size: CGFloat, weight: Font.Weight?, design: Font.Design?, style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight, design: design)) }
}

struct Typing: View {
    /// What Otto is doing, shown beside the dots; nil is just the dots.
    let status: String?
    /// The list Otto is working through, under the step; empty shows nothing.
    var todos: [TodoItem] = []
    /// Off while the server is unreachable: the line says it's reconnecting instead of the step.
    let connected: Bool

    var body: some View {
        // Top-aligned so the dots stay on the first line when a long status wraps. The same three dots
        // as a pip's typing line: one typing signal across the app.
        HStack(alignment: .top, spacing: 8) {
            TypingDots().frame(width: 29, height: 7).padding(.top, 6)
            // A status from before the drop would be stale; say what's actually happening.
            VStack(alignment: .leading, spacing: 8) {
                if let status = connected ? status : "Reconnecting…" {
                    // The same view, re-texted: each step rolls into the next letter by letter,
                    // the way the chat list's busy line does.
                    Text(status)
                        .font(size: 14, relativeTo: .subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
                if connected && !todos.isEmpty { TodoList(items: todos).transition(.opacity) }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(BubbleShape(mine: false, tail: true).fill(.incomingBubble))
        .padding(.trailing, 90)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Last, so the bubble behind the text is inside the animation too: it grows and
        // shrinks with a longer or shorter step instead of jumping to the new size.
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: status)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: todos)
        .animation(.snappy(duration: 0.25), value: connected)
    }
}

/// Otto's to-do list inside the thinking bubble: done ones ticked and faded, the current one in full ink.
struct TodoList: View {
    let items: [TodoItem]

    var body: some View {
        let done = items.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: icon(item.status))
                        .font(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(item.status == .in_progress ? Color.accentColor : .secondary)
                        .symbolEffect(.pulse, isActive: item.status == .in_progress)
                        .frame(minWidth: 14)
                    Text(item.text)
                        .font(size: 13, weight: item.status == .in_progress ? .medium : .regular, relativeTo: .footnote)
                        .foregroundStyle(item.status == .in_progress ? .primary : .secondary)
                        .strikethrough(item.status == .completed, color: .secondary)
                        .opacity(item.status == .completed ? 0.7 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("\(done) of \(items.count) done")
    }

    private func icon(_ s: TodoItem.Status) -> String {
        switch s {
        case .completed: "checkmark.circle.fill"
        case .in_progress: "circle.dotted.circle"
        case .pending: "circle"
        }
    }
}

/// First run, or a cleared thread: Otto front and centre with one line of what to do.
private struct EmptyChat: View {
    let asleep: Bool
    let connected: Bool

    private var line: String {
        if !connected { return "Can’t reach the server. What you send goes out when it’s back." }
        return "Say hi. Reminders, mail, plans: I’ll keep track of the rest."
    }
    var body: some View {
        VStack(spacing: 14) {
            Text("Otto").font(.title2.weight(.semibold))
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut, value: asleep)
        .allowsHitTesting(false)
    }
}

/// The system camera, for the composer's + menu. Shoots in a burst: each tap of the shutter
/// lands in the composer as an attachment, Done goes back to the box to send them together.
private struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        c.showsCameraControls = false
        c.cameraOverlayView = context.coordinator.overlay(for: c)
        // The bare preview is 4:3 at the top; centre it, uncropped, so what you frame is what's sent.
        let screen = UIScreen.main.bounds.size
        c.cameraViewTransform = CGAffineTransform(translationX: 0, y: max(0, (screen.height - screen.width * 4 / 3) / 2))
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        private weak var picker: UIImagePickerController?
        private let count = UILabel()
        private let flash = UIView()
        private let shutter = UIButton(type: .custom)
        private let done = UIButton(configuration: .filled())
        private let haptic = UIImpactFeedbackGenerator(style: .medium)
        private var shots = 0
        init(_ p: CameraPicker) { parent = p }

        func overlay(for picker: UIImagePickerController) -> UIView {
            self.picker = picker
            let v = UIView(frame: UIScreen.main.bounds)
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]

            flash.backgroundColor = .black
            flash.alpha = 0
            flash.isUserInteractionEnabled = false
            flash.frame = v.bounds
            flash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            v.addSubview(flash)

            shutter.backgroundColor = .white
            shutter.layer.cornerRadius = 36
            shutter.layer.borderWidth = 5
            shutter.layer.borderColor = UIColor.white.withAlphaComponent(0.4).cgColor
            shutter.accessibilityLabel = "Take photo"
            shutter.addTarget(self, action: #selector(shoot), for: .touchUpInside)

            var cfg = UIButton.Configuration.filled()
            cfg.title = "Done"
            cfg.cornerStyle = .capsule
            cfg.baseBackgroundColor = UIColor.black.withAlphaComponent(0.5)
            done.configuration = cfg
            done.addTarget(self, action: #selector(finish), for: .touchUpInside)

            count.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            count.textColor = .white
            count.textAlignment = .center
            count.backgroundColor = UIColor.black.withAlphaComponent(0.5)
            count.layer.cornerRadius = 18
            count.clipsToBounds = true
            count.isHidden = true
            haptic.prepare()

            for b in [shutter, done, count] as [UIView] { b.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(b) }
            let g = v.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                shutter.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                shutter.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -24),
                shutter.widthAnchor.constraint(equalToConstant: 72),
                shutter.heightAnchor.constraint(equalToConstant: 72),
                done.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
                done.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
                count.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
                count.centerYAnchor.constraint(equalTo: shutter.centerYAnchor),
                count.heightAnchor.constraint(equalToConstant: 36),
                count.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
            ])
            return v
        }

        /// takePicture() is a no-op while a capture is in flight, so the shutter (and Done, which
        /// would drop that capture) wait for the delegate.
        @objc private func shoot() {
            shutter.isEnabled = false
            done.isEnabled = false
            picker?.takePicture()
            haptic.impactOccurred()
            haptic.prepare()
            flash.alpha = 0.8
            UIView.animate(withDuration: 0.25) { self.flash.alpha = 0 }
        }
        @objc private func finish() { parent.dismiss() }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            shutter.isEnabled = true
            done.isEnabled = true
            guard let img = info[.originalImage] as? UIImage else { return }
            // A full-res capture is ~50 MB decoded; a burst of them gets the app killed. Keep 1600px.
            let k = min(1, 1600 / max(img.size.width * img.scale, img.size.height * img.scale))
            let size = CGSize(width: img.size.width * img.scale * k, height: img.size.height * img.scale * k)
            shots += 1
            count.text = "  \(shots)  "
            count.accessibilityLabel = "\(shots) photos"
            count.isHidden = false
            UIAccessibility.post(notification: .announcement, argument: "\(shots) photos")
            let onPick = parent.onPick
            Task { onPick(await img.byPreparingThumbnail(ofSize: size) ?? img) }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Tap the mic to record, tap send to upload. AAC at 16 kHz mono: Whisper needs no more.
@MainActor @Observable
final class VoiceRecorder {
    /// True while a note is recording, so the background keepalive leaves the mic's session alone.
    static var active = false
    private(set) var started: Date?
    private var recorder: AVAudioRecorder?

    func start() async {
        guard recorder == nil, await AVAudioApplication.requestRecordPermission() else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = URL.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.isMeteringEnabled = true
        guard r.record() else { return }
        recorder = r
        started = .now
        Self.active = true
        // A screen that auto-locks mid-note backgrounds the app and the recording dies with it.
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// The finished file, or nil if nothing was recording.
    func stop() -> URL? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        started = nil
        Self.active = false
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return r.url
    }

    /// Linear 0–1 loudness for the glow. Read off the recorder, not a second mic tap: the
    /// library's own meter opens a mixable session, which lets music back in mid-note.
    func level() -> Double {
        guard let r = recorder else { return 0 }
        #if DEBUG
        // `-recordDemo`: a talking-shaped level, since the simulator's mic hears a quiet room.
        if ProcessInfo.processInfo.arguments.contains("-recordDemo") {
            let t = Date.now.timeIntervalSinceReferenceDate
            return 0.06 + 0.1 * abs(sin(t * 5)) * abs(sin(t * 1.3))
        }
        #endif
        r.updateMeters()
        // The average is smoothed flat; part of the peak puts the punch of each word back.
        let avg = pow(10, Double(r.averagePower(forChannel: 0)) / 20)
        let peak = pow(10, Double(r.peakPower(forChannel: 0)) / 20)
        return max(avg, peak * 0.6)
    }

    func cancel() { if let url = stop() { try? FileManager.default.removeItem(at: url) } }
}

/// Decoded photos, so scrolling past one doesn't re-decode its JPEG on every frame.
private enum Thumbs {
    static let cache = NSCache<NSUUID, UIImage>()
    static func image(for m: Message) -> UIImage? {
        guard m.isPhoto else { return nil }
        if let hit = cache.object(forKey: m.id as NSUUID) { return hit }
        guard let data = m.imageData, let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: m.id as NSUUID)
        return img
    }
}

/// What the thread needs to know about the composer, across the two hosting controllers.
@Observable final class ComposerUI {
    var focused = false
    /// How much of the thread's bottom the composer covers.
    var bottomInset: CGFloat = 0
    /// UIKit's keyboard curve (curve 7) as a SwiftUI spring, so the thread moves with the keyboard.
    /// Whether the last inset change came from an animation (keyboard open/close, the box
    /// growing) rather than a drag-to-dismiss.
    @ObservationIgnored var insetAnimated = false
    static let keyboard = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
    /// Asks the dock to re-measure the composer (a draft wrapped onto a new line).
    @ObservationIgnored var relayout: () -> Void = {}
    /// A voice note is recording, and how loud it is (0–1): drives the screen glow.
    var recording = false
    @ObservationIgnored var level: () -> Double = { 0 }
    /// The composer's height, so a sent bubble knows how far below it the text field was.
    @ObservationIgnored var height: CGFloat = 50
    /// The thread is being searched: the composer steps aside, so there's one text field at a time.
    var searching = false
}

/// The voice glow rising from the bottom edge of the screen while a note records. Its own
/// full-screen layer between thread and composer: inside the composer's host it is clipped
/// to the box. Extra gain for a phone at arm's length, a short attack so syllables show.
private struct ScreenGlow: View {
    let ui: ComposerUI
    var body: some View {
        Color.clear
            .voiceGlow(type: .mobile, levelProvider: { ui.level() }, active: ui.recording,
                       cornerRadius: 55, options: {   // roughly the display's own corner
                           var o = VoiceGlowOptions()
                           o.sensitivity = 10; o.attack = 0.12; o.release = 0.5; o.idle = 0.4
                           o.brightness = 1.4; o.saturation = 1.5
                           return o
                       }())
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The chat screen. UIKit only for layout: the composer is pinned to
/// `keyboardLayoutGuide`, which follows the keyboard frame by frame, including a
/// drag-to-dismiss — SwiftUI's keyboard safe area jumps there instead.
struct ChatScreen: UIViewControllerRepresentable {
    let store: OttoStore
    /// Otto's own when nil.
    var thread: (any ChatThread)? = nil
    var onBack: (() -> Void)? = nil
    func makeUIViewController(context: Context) -> KeyboardDock {
        KeyboardDock(store: store, thread: thread ?? store, onBack: onBack)
    }
    func updateUIViewController(_ vc: KeyboardDock, context: Context) {}
}

final class KeyboardDock: UIViewController {
    private let thread: UIHostingController<AnyView>
    private let composer: UIHostingController<AnyView>
    private let glow: UIHostingController<AnyView>
    private let ui: ComposerUI
    private var composerHeight: NSLayoutConstraint!
    private var glowBottom: NSLayoutConstraint!

    init(store: OttoStore, thread chat: any ChatThread, onBack: (() -> Void)? = nil) {
        let ui = ComposerUI()
        self.ui = ui
        thread = UIHostingController(rootView: AnyView(ChatView(ui: ui, thread: chat, onBack: onBack).environment(store)))
        composer = UIHostingController(rootView: AnyView(Composer(ui: ui, thread: chat).environment(store)))
        glow = UIHostingController(rootView: AnyView(ScreenGlow(ui: ui)))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let dock = DockView()
        dock.thread = thread.view
        dock.composer = composer.view
        // Composer's .padding(.top, 6) plus its .offset(y: 10), while the keyboard is down. Not while
        // typing: a tap just above the field would land on the thread and close the keyboard.
        dock.emptyTop = { [ui] in ui.focused ? 0 : 16 }
        view = dock
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for host in [thread, glow, composer] {   // back to front
            addChild(host)
            view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            host.safeAreaRegions = .container   // the keyboard is handled here, not by SwiftUI
            host.didMove(toParent: self)
        }
        glow.view.isUserInteractionEnabled = false   // touches go through to the thread
        glow.safeAreaRegions = []                    // down to the real screen edge
        // Measured at the real width (intrinsic size measures unconstrained, so a long
        // draft never wrapped and the box stayed one line tall).
        composerHeight = composer.view.heightAnchor.constraint(equalToConstant: 52)
        glowBottom = glow.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ui.relayout = { [weak self] in DispatchQueue.main.async { self?.measureComposer(animated: true) } }
        NSLayoutConstraint.activate([
            thread.view.topAnchor.constraint(equalTo: view.topAnchor),
            // Full height: resizing the thread with the keyboard re-laid SwiftUI out at the
            // final size in one jump. The keyboard is an inset instead (below).
            thread.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thread.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thread.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glow.view.topAnchor.constraint(equalTo: view.topAnchor),
            glowBottom,
            glow.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glow.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composerHeight,
        ])
    }

    /// The thread scrolls under the composer (the glass needs something behind it), so
    /// its bottom inset is whatever the composer and keyboard cover.
    private func measureComposer(animated: Bool) {
        guard view.bounds.width > 0 else { return }
        let h = composer.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        ui.height = h
        guard abs(h - composerHeight.constant) > 0.5 else { return }
        composerHeight.constant = h
        if animated { UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() } }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        measureComposer(animated: false)
        // This view stops above the home indicator; the glow rises from the glass edge below it.
        if let window = view.window {
            let gap = max(0, window.bounds.maxY - view.convert(view.bounds, to: window).maxY)
            if abs(glowBottom.constant - gap) > 0.5 { glowBottom.constant = gap }
        }
        let covered = max(0, view.bounds.maxY - composer.view.frame.minY - view.safeAreaInsets.bottom)
        guard abs(ui.bottomInset - covered) > 0.5 else { return }
        // Inside the keyboard's animation block this runs once, with the final frame; a
        // drag-to-dismiss calls it every frame outside any block. ChatView animates the former.
        ui.insetAnimated = UIView.inheritedAnimationDuration > 0
        ui.bottomInset = covered
    }
}

/// The dock's own view. The composer's host takes every touch in its frame, but with the keyboard
/// down its top strip is empty, so a tap there goes to the thread behind: the newest message's
/// suggested replies and "Try again" reach into it for their 44pt (see hitSlop).
private final class DockView: UIView {
    weak var thread: UIView?
    weak var composer: UIView?
    var emptyTop: () -> CGFloat = { 0 }
    override func hitTest(_ p: CGPoint, with event: UIEvent?) -> UIView? {
        if let thread, let composer, p.y >= composer.frame.minY, p.y < composer.frame.minY + emptyTop() {
            return thread.hitTest(convert(p, to: thread), with: event)
        }
        return super.hitTest(p, with: event)
    }
}


extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// The system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// A message's text with real selection handles, for copying part of it.
/// SwiftUI's `.textSelection` only offers the whole string on iOS.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.font = .systemFont(ofSize: 17)
        v.textContainerInset = UIEdgeInsets(top: 28, left: 16, bottom: 16, right: 16)
        v.dataDetectorTypes = [.link, .phoneNumber]
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}

extension PKPass: @retroactive Identifiable { public var id: String { serialNumber } }

/// The system Add to Wallet card for one pass.
private struct AddPassSheet: UIViewControllerRepresentable {
    let pass: PKPass
    func makeUIViewController(context: Context) -> PKAddPassesViewController { PKAddPassesViewController(pass: pass)! }
    func updateUIViewController(_ vc: PKAddPassesViewController, context: Context) {}
}


extension ShapeStyle where Self == Color {
    /// Yours: the slate grey of the user's side in the reference (sampled #60656B in dark mode).
    /// Light mode is a shade darker than a straight lift, so white text clears 4.5:1.
    /// Increase Contrast pushes both a step further from the background, as the system greys do.
    static var outgoingBubble: Color {
        Color(UIColor { t in
            let high = t.accessibilityContrast == .high
            return t.userInterfaceStyle == .dark
                ? UIColor(red: 0.376, green: 0.396, blue: 0.420, alpha: 1).adjusted(by: high ? 0.08 : 0)
                : UIColor(red: 0.420, green: 0.443, blue: 0.471, alpha: 1).adjusted(by: high ? -0.08 : 0)
        })
    }
    /// Messages' grey for the other side, a shade darker than systemGray5 in dark mode.
    static var incomingBubble: Color {
        Color(UIColor { t in
            let high = t.accessibilityContrast == .high
            return t.userInterfaceStyle == .dark
                ? UIColor(red: 0.149, green: 0.145, blue: 0.165, alpha: 1).adjusted(by: high ? 0.08 : 0)
                : UIColor(red: 0.914, green: 0.914, blue: 0.922, alpha: 1).adjusted(by: high ? -0.08 : 0)
        })
    }
}

private extension UIColor {
    /// The same grey, lighter (+) or darker (−) by `d` on each channel.
    func adjusted(by d: CGFloat) -> UIColor {
        guard d != 0 else { return self }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r + d, green: g + d, blue: b + d, alpha: a)
    }
}
