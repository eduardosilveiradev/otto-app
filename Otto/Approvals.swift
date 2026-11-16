import SwiftUI
import LocalAuthentication

/// A change to Otto's own core that needs your say-so — the in-app version of typing
/// "i approve the otto core change". The server sends it (what, why, every file with its
/// tier, and a diff stat it computed itself); Approve sits behind Face ID. A payment
/// (`ask_payment`) rides the same screen: merchant, every line, the total and the card.
struct ApprovalRequest: Decodable, Identifiable, Hashable {
    struct File: Decodable, Hashable {
        let path: String; let tier: String; let why: String
        /// A few of the file's changed lines, each led by "+", "-" or a space as git writes them.
        /// Optional: a server that sends none shows the file with its reason alone.
        var lines: [String]? = nil
    }
    struct Payment: Decodable, Hashable {
        struct Item: Decodable, Hashable { let name: String; let detail: String?; let quantity: Int; let unit: Double }
        let merchant: String
        let site: String?
        let items: [Item]
        let total: Double
        let currency: String
        let method: String
        let notes: [String]
        let test: Bool?
        func money(_ v: Double) -> String { v.formatted(.currency(code: currency)) }
    }
    let id: String
    let title: String
    let summary: String
    let files: [File]
    let branch: String?
    let stat: String?
    let expires: String?
    var payment: Payment? = nil
}

extension ApprovalRequest {
    /// What it asks, in a few words: the payment's amount and payee, or the change's title.
    var ask: String { payment.map { "Pay \($0.money($0.total)) to \($0.merchant)" } ?? title }
    /// Whole minutes until the Mac drops it, rounded up; nil when the server sent no time.
    func minutesLeft(at now: Date) -> Int? {
        LiveBackend.date(expires).map { max(1, Int(($0.timeIntervalSince(now) / 60).rounded(.up))) }
    }
}

enum ApprovalUpdate { case show(ApprovalRequest), done(String) }

/// An approval put off with Later, over the composer until it's answered or lapses: what it asks
/// and how long the Mac holds it. Tapping it brings the sheet back. Once the Mac has let it lapse
/// unanswered, the same line says so until it's tapped away.
struct ApprovalPill: View {
    let request: ApprovalRequest
    var lapsed = false
    let tap: () -> Void
    @Environment(\.dynamicTypeSize) private var size

    var body: some View {
        // At accessibility sizes the time goes under the ask, which gets two lines: the amount leads it and never truncates.
        let stacked = size.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        Button(action: tap) {
            HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: 8) {
                // On the ask's first line when it stacks, not halfway down three.
                Circle().fill(lapsed ? Color.secondary : Color.otto).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                layout {
                    Text(request.ask).foregroundStyle(lapsed ? .secondary : .primary).lineLimit(stacked ? 2 : 1)
                    if !stacked { Spacer(minLength: 0) }
                    Group {
                        if lapsed {
                            Text("Expired")
                        } else {
                            TimelineView(.periodic(from: .now, by: 15)) { tl in
                                if let m = request.minutesLeft(at: tl.date) { Text("\(m) min left").monospacedDigit() }
                            }
                        }
                    }
                    .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: lapsed ? "xmark" : "chevron.up")
                    .font(size: 10, weight: .semibold, relativeTo: .caption2)
                    .foregroundStyle(.secondary)
            }
            .font(size: 13, weight: .medium, relativeTo: .footnote)
            .padding(.vertical, stacked ? 8 : 0)
            .frame(minHeight: 34)
            // 44pt to tap, reaching into the gap above the box, as the to-do pill does.
            .padding(.bottom, 10).contentShape(.rect).padding(.bottom, -10)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 17, style: .continuous))
        .accessibilityLabel(lapsed ? "Expired before you answered: \(request.ask)" : "Waiting on you: \(request.ask)")
        .accessibilityValue(lapsed ? "" : request.minutesLeft(at: .now).map { "\($0) minutes left" } ?? "")
        .accessibilityHint(lapsed ? "Dismisses it" : "Opens it to approve or decline")
    }
}

struct ApprovalSheet: View {
    @Environment(OttoStore.self) private var store
    let request: ApprovalRequest
    @State private var busy = false
    @State private var failed: String?
    /// The decision sent without an answer: the sheet then only offers that one again. Kept by the
    /// store, so Later and the pill bringing the sheet back can't offer the other one.
    private var unconfirmed: Bool? { store.unconfirmedApprovals[request.id] }
    /// Paid: the decision has gone to the Mac, and the receipt prints before the sheet closes.
    /// `-receiptDemo`: straight to the receipt, for recordings (Face ID can't be tapped in the simulator).
    @State private var paid = ProcessInfo.processInfo.arguments.contains("-receiptDemo")

    var body: some View {
        NavigationStack {
            List {
                if paid, let p = request.payment {
                    Section { PrintedReceipt(payment: p).listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                } else if let p = request.payment { paymentRows(p) } else { changeRows }

                if let failed = failed ?? unconfirmed.map({ _ in Self.unconfirmedLine }) {
                    Section { Text(failed).foregroundStyle(Color.redInk).font(.footnote) }
                }
            }
            // "Approved", not "Paid": the Mac has the go-ahead; the payment itself is Otto's to report in the chat.
            // The amount the way the sheet writes it ("€17.00"), not the server's "17.00 EUR".
            .navigationTitle(paid ? "Approved" : request.payment.map { "Pay \($0.money($0.total))" } ?? request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !paid {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Later") { store.hideApproval(request.id) }
                    }
                }
            }
            // A system bar: the sheet's soft scroll edge under the buttons, not a ruled strip across the rows.
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                Group {
                if paid {
                    Button { store.closeApproval(request.id) } label: { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                } else if let tried = unconfirmed {
                    // The first answer may have landed: only the same one can be sent again, never the other.
                    Button { Task { await decide(tried) } } label: {
                        Text(tried ? "Try again: \(request.payment.map { "Pay \($0.money($0.total))" } ?? "Approve")" : "Try again: Decline").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                } else {
                VStack(spacing: 10) {
                // The Mac holds it for half an hour; Later doesn't stop that clock.
                TimelineView(.periodic(from: .now, by: 15)) { tl in
                    if let m = request.minutesLeft(at: tl.date) {
                        Text("Expires in \(m) min").monospacedDigit()
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { Task { await decide(false) } } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    .quietButton()
                    Button { Task { await decide(true) } } label: {
                        Label(request.payment.map { "Pay \($0.money($0.total))" } ?? "Approve", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                }
                .font(.headline)
                .controlSize(.large)
                .disabled(busy)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                }
                }
                .bottomBarFade()
            }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder private func paymentRows(_ p: ApprovalRequest.Payment) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.money(p.total)).monospacedDigit().font(size: 34, weight: .semibold, relativeTo: .largeTitle)
                Text(p.merchant).font(.headline)
                if let site = p.site { Text(site).font(.subheadline).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }

        // Right under the amount, so a caveat (no refunds, a seat hold) is read before the lines and the
        // buttons, never left under the bar's fade at the bottom of a long list.
        if !p.notes.isEmpty || p.test == true {
            Section {
                if p.test == true { Label("Test — nothing will be charged", systemImage: "testtube.2").foregroundStyle(.secondary) }
                ForEach(p.notes, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.subheadline) }
            } header: { Text("Before you pay") }
            .labelStyle(PlainIcon())   // a caveat isn't an action: its glyph takes the text colour, not the blue
        }

        Section {
            ForEach(Array(p.items.enumerated()), id: \.offset) { _, i in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.quantity > 1 ? "\(i.quantity) × \(i.name)" : i.name)
                        if let d = i.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    Text(p.money(i.unit * Double(i.quantity))).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Text("Total").fontWeight(.semibold)
                Spacer()
                Text(p.money(p.total)).fontWeight(.semibold).monospacedDigit()
            }
        } header: { Text("Items") }

        Section {
            Label(p.method, systemImage: "creditcard")
        } header: { Text("Paying with") }
        .labelStyle(PlainIcon())

    }

    @ViewBuilder private var changeRows: some View {
        Section {
            Text(request.summary)
                .font(.body)
                .textSelection(.enabled)
        } header: { Text("What it does") }

        Section {
            ForEach(request.files, id: \.path) { f in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(f.path).font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                        Spacer(minLength: 4)
                        // Guarded is why this needs you, so it wears the mark; any other tier is only named.
                        if f.tier == "guarded" { NeedsMark(text: f.tier) }
                        else { Text(f.tier.prefix(1).uppercased() + f.tier.dropFirst()).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Text(f.why.prefix(1).uppercased() + f.why.dropFirst()).font(.footnote).foregroundStyle(.secondary)
                    if let lines = f.lines, !lines.isEmpty { DiffPreview(lines: lines).padding(.top, 6) }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(request.files.count == 1 ? "Changes · 1 file" : "Changes · \(request.files.count) files")
        } footer: {
            if let totals { Text(totals) }
        }

        // A stat that isn't git's summary is the change itself (the memory clean-up sends the lines it
        // drops): what you approve stays on the screen, tinted like the previews.
        if totals == nil, let stat = request.stat, !stat.isEmpty {
            Section("Details") { DiffPreview(lines: stat.split(whereSeparator: \.isNewline).map(String.init), whole: true) }
        }
    }

    /// The diff's size in words, read off the stat the server computed. The raw `git diff --stat` is never shown.
    private var totals: String? {
        guard let stat = request.stat else { return nil }
        let added = stat.firstMatch(of: #/(\d+) insertion/#).flatMap { Int($0.1) }
        let removed = stat.firstMatch(of: #/(\d+) deletion/#).flatMap { Int($0.1) }
        guard added != nil || removed != nil else { return nil }
        let size = [added.map { "\($0) added" }, removed.map { "\($0) removed" }].compactMap { $0 }.joined(separator: " and ")
        let preview = request.files.contains { !($0.lines ?? []).isEmpty }
        return (preview ? "A few lines from each file. " : "") + "In all, \(size) against main" + (request.branch.map { ", on \($0)." } ?? ".")
    }

    private func decide(_ approve: Bool) async {
        busy = true
        defer { busy = false }
        if approve {
            let ctx = LAContext()
            let reason = request.payment.map { "Pay \($0.money($0.total)) to \($0.merchant)" } ?? "Approve this change to Otto"
            do {
                // Face ID, falling back to the passcode: someone holding an unlocked phone still can't approve.
                guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return }
            } catch {
                failed = "Not approved — \(error.localizedDescription)"
                return
            }
        }
        // A paid payment goes to the Mac now, then the sheet stays for the receipt until Done.
        let keep = approve && request.payment != nil   // the receipt stays up until Done
        switch await store.decide(request.id, approve: approve, keep: keep) {
        case .done: if keep { withAnimation(.snappy) { paid = true } }
        case .gone: failed = "This had expired before your answer reached your Mac, so nothing was done. Ask Otto again."
        // The decision may have landed and only its answer been lost: trying again is safe (same decision),
        // but saying "nothing was paid" might not be true.
        case .unknown:
            failed = Self.unconfirmedLine
            store.unconfirmedApprovals[request.id] = approve
        }
    }
    private static let unconfirmedLine = "Couldn’t confirm with your Mac. Check the chat, or try again."
}

/// A few changed lines of one file: removed on the red tint, added on the green. The sign leads each
/// line, so the tint is never the only cue.
private struct DiffPreview: View {
    let lines: [String]
    /// Every line, instead of the first six. Each one wraps in full either way: what's cut off can't be read before Face ID.
    var whole = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(whole ? .max : 6).enumerated()), id: \.offset) { _, l in
                // "--- file" and "+++ file" name what follows; they aren't changed lines.
                let names = l.hasPrefix("---") || l.hasPrefix("+++")
                let removed = !names && l.hasPrefix("-"), added = !names && l.hasPrefix("+")
                let code = names ? Substring(l.drop { $0 == "-" || $0 == "+" || $0 == " " }) : l.dropFirst(removed || added || l.hasPrefix(" ") ? 1 : 0)
                let lead = removed ? "− " : added ? "+ " : "  "
                Text(verbatim: names ? String(code) : lead + code)
                    .font(.system(.caption, design: .monospaced).weight(names ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(removed ? Color.redTint : added ? Color.greenTint : Color.clear)
                    .accessibilityLabel((removed ? "Removed: " : added ? "Added: " : "") + code)
            }
        }
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
    }
}

/// Kitchen's Receipt Printer (dqnamo.com/experiments/receipt-printer), rebuilt: a dark printer
/// whose screen says what it's doing (processing, printing, complete), and a receipt that feeds
/// out of its slot in ten short pushes, bigger in the middle, over 1.75s.
struct PrintedReceipt: View {
    let payment: ApprovalRequest.Payment
    enum Stage { case processing, printing, complete }
    @State private var stage: Stage = .processing
    /// 0 hidden in the slot, 1 fully out; the paper is offset by (frac - 1) of its own height.
    @State private var frac: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Kitchen's stepped feed: where the paper stops after each push (fraction still inside),
    // each push 0.13s, each pause 0.05s, linear.
    private static let stops: [Double] = [0.91, 0.81, 0.70, 0.58, 0.45, 0.32, 0.20, 0.10, 0.03, 0]
    private static let push = 0.13, pause = 0.0525
    private static let easeOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)

    var body: some View {
        VStack(spacing: 0) {
            machine.zIndex(2).accessibilityHidden(true)   // the printer is decoration; the paper carries the facts
            output.padding(.top, -16).zIndex(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        // Grows with the text size like everything else; a row too wide for the paper stacks its value
        // under its label (see row). VoiceOver walks the paper row by row, as it's printed.
        .task { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Receipt")
    }

    private func run() async {
        if reduceMotion { stage = .complete; frac = 1; return }
        try? await Task.sleep(for: .milliseconds(700))
        withAnimation(Self.easeOut) { stage = .printing }
        let tick = UIImpactFeedbackGenerator(style: .soft)
        for s in Self.stops {
            withAnimation(.linear(duration: Self.push)) { frac = 1 - s }
            tick.impactOccurred(intensity: 0.5)
            try? await Task.sleep(for: .seconds(Self.push + Self.pause))
        }
        withAnimation(Self.easeOut) { stage = .complete }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: the printer

    private var machine: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "creditcard.fill").font(.system(size: 13)).foregroundStyle(Color(white: 0.55))
                    .frame(width: 22, height: 22).background(Color(white: 0.22), in: .rect(cornerRadius: 5))
                Spacer()
                Text(payment.test == true ? "Test" : "Approved").font(size: 12, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(Color(white: 0.75))
                    .padding(.horizontal, 10).frame(minHeight: 24).background(Color(white: 0.22), in: .capsule)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payment.merchant).font(size: 14, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.white).lineLimit(1)
                        Text(payment.items.count == 1 ? payment.items[0].name : "\(payment.items.count) items")
                            .font(size: 12, relativeTo: .caption).foregroundStyle(Color(white: 0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Total").font(size: 11, relativeTo: .caption2).foregroundStyle(Color(white: 0.6))
                        Text(payment.money(payment.total)).monospacedDigit().font(size: 17, weight: .semibold, relativeTo: .headline).foregroundStyle(.white)
                    }
                }
                status
            }
            .padding(14)
            .background(Color(white: 0.09), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(white: 0.2)))
            Color.clear.frame(height: 8)
        }
        .padding(10)
        .background(Color(white: 0.15), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color(white: 0.25)))
        // The slot the paper comes out of.
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.04))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(white: 0.22)))
                .frame(height: 8).padding(.horizontal, 24).padding(.bottom, 9)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var status: some View {
        HStack(spacing: 8) {
            ZStack {
                if stage == .complete {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.mini).tint(Color(white: 0.6))
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .frame(width: 18, height: 18)
            ZStack(alignment: .leading) {
                Text(label).id(stage)
                    .transition(.asymmetric(insertion: .offset(y: 4).combined(with: .opacity), removal: .offset(y: -4).combined(with: .opacity)))
            }
            .font(size: 12, weight: .medium, relativeTo: .caption).foregroundStyle(Color(white: 0.7))
        }
        .clipped()
    }

    private var label: String {
        switch stage {
        case .processing: "Processing your payment"
        case .printing: "Printing your receipt"
        case .complete: payment.test == true ? "Test complete" : "Sent to Otto"
        }
    }

    // MARK: the paper

    private var output: some View {
        paper
            .visualEffect { [frac] c, g in c.offset(y: -g.size.height * (1 - frac) + 2) }
            .padding(.horizontal, 24)
            .clipped()
            // The slot's shadow on the paper as it comes out.
            .overlay(alignment: .top) {
                Rectangle().fill(.black.opacity(0.55)).frame(height: 8).blur(radius: 6).padding(.horizontal, 24).offset(y: -4)
            }
            .opacity(stage == .processing ? 0 : 1)
    }

    private var paper: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkle").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(Color(white: 0.12), in: .rect(cornerRadius: 6))
                .frame(maxWidth: .infinity).padding(.bottom, 14)
            dashed
            ForEach(Array(payment.items.enumerated()), id: \.offset) { _, i in
                VStack(alignment: .leading, spacing: 1) {
                    row((i.quantity > 1 ? "\(i.quantity) × \(i.name)" : i.name).uppercased(), payment.money(i.unit * Double(i.quantity))).fontWeight(.bold)
                    if let d = i.detail { Text(d).foregroundStyle(Color(white: 0.45)) }
                }
                .padding(.vertical, 4)
            }
            dashed
            row("TOTAL", payment.money(payment.total)).font(size: 13, weight: .bold, design: .monospaced, relativeTo: .footnote).padding(.vertical, 6)
            dashed
            VStack(alignment: .leading, spacing: 3) {
                row("Merchant", payment.site ?? payment.merchant)
                row("Paid with", payment.method)
                row("Date", Date.now.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()).uppercased())
            }
            .foregroundStyle(Color(white: 0.35))
            .padding(.vertical, 6)
            Barcode(seed: payment.merchant + payment.money(payment.total)).frame(height: 34).padding(.top, 10).padding(.horizontal, 30)
                .accessibilityHidden(true)
            Text(payment.test == true ? "TEST · NOTHING CHARGED" : "THANK YOU").font(size: 9, design: .monospaced, relativeTo: .caption2)
                .foregroundStyle(Color(white: 0.5)).frame(maxWidth: .infinity).padding(.top, 4)
        }
        .font(size: 11, weight: .medium, design: .monospaced, relativeTo: .caption2)
        .foregroundStyle(Color(white: 0.12))
        .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 26)
        .background(Color(white: 0.985))
        .clipShape(Torn())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    private var dashed: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color(white: 0.78)).frame(height: 1).padding(.vertical, 6)
    }

    private func row(_ l: String, _ r: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { Text(l).lineLimit(1); Spacer(minLength: 12); Text(r).lineLimit(1) }
            VStack(alignment: .leading, spacing: 2) { Text(l); Text(r) }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)   // "Total, €17.00", one stop
    }

    private struct Line: Shape { func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } } }

    /// The tear: a row of small teeth along the bottom edge.
    private struct Torn: Shape {
        func path(in r: CGRect) -> Path {
            let teeth = 28, depth: CGFloat = 6
            return Path { p in
                p.move(to: .zero); p.addLine(to: CGPoint(x: r.maxX, y: 0)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
                for i in stride(from: teeth, through: 0, by: -1) {
                    let x = r.width * CGFloat(i) / CGFloat(teeth)
                    p.addLine(to: CGPoint(x: x, y: i % 2 == 0 ? r.maxY - depth : r.maxY))
                }
                p.closeSubpath()
            }
        }
    }

    /// Bars from a hash of the payment, so the same receipt always prints the same code.
    private struct Barcode: View {
        let seed: String
        var body: some View {
            Canvas { ctx, size in
                var h = UInt64(seed.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 })
                var x: CGFloat = 0
                while x < size.width {
                    h = h &* 6364136223846793005 &+ 1442695040888963407
                    let w = CGFloat(1 + (h >> 33) % 3), gap = CGFloat(1 + (h >> 40) % 2)
                    ctx.fill(Path(CGRect(x: x, y: 0, width: min(w, size.width - x), height: size.height)), with: .color(Color(white: 0.1)))
                    x += w + gap
                }
            }
        }
    }
}
