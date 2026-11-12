import SwiftUI
import LocalAuthentication

/// A change to Otto's own core that needs your say-so — the in-app version of typing
/// "i approve the otto core change". The server sends it (what, why, every file with its
/// tier, and a diff stat it computed itself); Approve sits behind Face ID. A payment
/// (`ask_payment`) rides the same screen: merchant, every line, the total and the card.
struct ApprovalRequest: Decodable, Identifiable, Hashable {
    struct File: Decodable, Hashable { let path: String; let tier: String; let why: String }
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

enum ApprovalUpdate { case show(ApprovalRequest), done(String) }

struct ApprovalSheet: View {
    @Environment(OttoStore.self) private var store
    let request: ApprovalRequest
    @State private var busy = false
    @State private var failed: String?
    /// The decision sent without an answer: the sheet then only offers that one again.
    @State private var unconfirmed: Bool?
    /// Paid: the decision has gone to the Mac, and the receipt prints before the sheet closes.
    /// `-receiptDemo`: straight to the receipt, for recordings (Face ID can't be tapped in the simulator).
    @State private var paid = ProcessInfo.processInfo.arguments.contains("-receiptDemo")

    var body: some View {
        NavigationStack {
            List {
                if paid, let p = request.payment {
                    Section { PrintedReceipt(payment: p).listRowBackground(Color.clear).listRowInsets(EdgeInsets()) }
                } else if let p = request.payment { paymentRows(p) } else { changeRows }

                if let failed {
                    Section { Text(failed).foregroundStyle(.red).font(.footnote) }
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
                HStack(spacing: 12) {
                    Button(role: .destructive) { Task { await decide(false) } } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await decide(true) } } label: {
                        Label(request.payment.map { "Pay \($0.money($0.total))" } ?? "Approve", systemImage: "faceid").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .disabled(busy)
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

        if !p.notes.isEmpty || p.test == true {
            Section {
                if p.test == true { Label("Test — nothing will be charged", systemImage: "testtube.2").foregroundStyle(.secondary) }
                ForEach(p.notes, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.subheadline) }
            } header: { Text("Before you pay") }
        }
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
                    HStack(spacing: 6) {
                        Text(f.path).font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                        Spacer(minLength: 4)
                        Pill(text: f.tier, tint: f.tier == "guarded" ? .orange : .secondary)
                    }
                    Text(f.why).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: { Text("Files") }

        if let stat = request.stat {
            Section {
                // Wrapped, not a sideways scroll nothing hinted at.
                Text(stat).font(.system(.caption, design: .monospaced))
            } header: { Text(request.branch.map { "Diff against main · \($0)" } ?? "Diff") }
        }
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
            failed = "Couldn’t confirm with your Mac. Check the chat, or try again."
            unconfirmed = approve
        }
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
            machine.zIndex(2)
            output.padding(.top, -16).zIndex(1)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        // Printed: its longest row ("Paid with … 6983") is already the paper's width at the default
        // size, so the receipt shrinks with smaller text but doesn't grow. VoiceOver reads it whole.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .task { await run() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Receipt for \(payment.money(payment.total)) to \(payment.merchant)")
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
        HStack(alignment: .firstTextBaseline) { Text(l).lineLimit(1); Spacer(minLength: 12); Text(r).lineLimit(1) }
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
