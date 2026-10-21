import SwiftUI
import PhotosUI

// MARK: - Model

/// The flight-day card (`GET /app/gate`, otto/gate.ts). Times are wall clock at each airport.
struct GateCard: Codable, Equatable {
    let key: String
    let flight: String
    let carrier: String
    var from: String?
    var to: String?
    var fromCity: String?
    var toCity: String?
    let date: String
    let departs: String
    var arrives: String?
    var departsEst: String?
    var arrivesEst: String?
    var departsAt: String?
    var durationMinutes: Int?
    var state: String?
    var delayMinutes: Int?
    var gate: String?
    var terminal: String?
    var seat: String?
    var cabin: String?
    var booking: String?
    var statusAsOf: String?
    var notes: [String] = []

    var departure: Date? { LiveBackend.date(departsAt) }
    /// "TA 482": the carrier's code set apart, the way a pass prints it.
    var flightLabel: String {
        flight.hasPrefix(carrier) && flight.count > carrier.count ? "\(carrier) \(flight.dropFirst(carrier.count))" : flight
    }
}

/// `card` nil is the server saying there's no flight coming; the reply itself nil is no answer at all.
struct GateReply: Decodable { let card: GateCard? }

// MARK: - Keeping it on the phone

/// The card and the boarding pass picture live in Application Support, so both are
/// there at the gate with no signal. The server only ever adds to what's known.
@MainActor @Observable
final class GateWatch {
    private(set) var card: GateCard?
    private(set) var fetchedAt: Date?
    private(set) var pass: UIImage?

    private let dir = URL.applicationSupportDirectory
    private var cardFile: URL { dir.appending(path: "gate.json") }
    private func passFile(_ key: String) -> URL {
        dir.appending(path: "gate-pass-\(key.filter { $0.isLetter || $0.isNumber || $0 == "-" }).jpg")
    }

    private struct Saved: Codable { let card: GateCard; let fetchedAt: Date }

    init() {
        if let s = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: cardFile)) {
            card = s.card; fetchedAt = s.fetchedAt
            pass = UIImage(contentsOfFile: passFile(s.card.key).path)
        }
    }

    /// Shown until an hour after departure, whether or not the server has been reachable since.
    func visible(at now: Date = .now) -> GateCard? {
        guard let c = card else { return nil }
        if let d = c.departure, now.timeIntervalSince(d) > 3600 { return nil }
        return c
    }

    func run(_ backend: OttoBackend) async {
        while !Task.isCancelled {
            let reply = await backend.gate()
            if let reply { apply(reply.card) }
            let soon = card?.departure.map { $0.timeIntervalSinceNow < 3 * 3600 } ?? false
            try? await Task.sleep(for: reply == nil || soon ? .seconds(60) : .seconds(300))
        }
    }

    private func apply(_ next: GateCard?) {
        fetchedAt = .now
        if next?.key != card?.key {
            if let old = card { try? FileManager.default.removeItem(at: passFile(old.key)) }
            pass = next.flatMap { UIImage(contentsOfFile: passFile($0.key).path) }
        }
        card = next
        if let next, let data = try? JSONEncoder().encode(Saved(card: next, fetchedAt: .now)) {
            try? data.write(to: cardFile, options: .atomic)
        } else if next == nil {
            try? FileManager.default.removeItem(at: cardFile)
        }
    }

    func setPass(_ data: Data) -> Bool {
        guard let c = card, let img = UIImage(data: data), let jpeg = img.jpegData(compressionQuality: 0.92) else { return false }
        guard (try? jpeg.write(to: passFile(c.key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return false }
        pass = img
        return true
    }

    func removePass() {
        if let c = card { try? FileManager.default.removeItem(at: passFile(c.key)) }
        pass = nil
    }
}

// MARK: - The banner over the chat

struct GateBanner: View {
    let card: GateCard
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(GateStatus(card).tint, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.gate.map { "\(card.flightLabel) · Gate \($0)" } ?? card.flightLabel)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let d = card.departure {
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        Text(Self.countdown(to: d, from: tl.date))
                    }
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .accessibilityLabel("Flight \(card.flightLabel) today. Open the boarding pass.")
    }

    private var subtitle: String {
        let route = [card.from, card.to].compactMap { $0 }.joined(separator: " → ")
        let time = card.departsEst.map { "departs \($0), was \(card.departs)" } ?? "departs \(card.departs)"
        return route.isEmpty ? time : "\(route) · \(time)"
    }

    static func countdown(to d: Date, from now: Date) -> String {
        let m = Int(d.timeIntervalSince(now) / 60)
        if m <= 0 { return "now" }
        return m < 60 ? "in \(m)m" : "in \(m / 60)h \(String(format: "%02d", m % 60))m"
    }
}

// MARK: - Status

/// The badge: what flight status says, or "Scheduled" when nothing live is known.
struct GateStatus: Equatable {
    enum Tone { case ok, late, bad, quiet }
    let label: String
    let tone: Tone

    init(_ c: GateCard) {
        switch c.state {
        case "cancelled": (label, tone) = ("Cancelled", .bad)
        case "diverted": (label, tone) = ("Diverted", .late)
        case "departed": (label, tone) = ("Departed", .quiet)
        case "landed": (label, tone) = ("Landed", .quiet)
        case "boarding": (label, tone) = ("Boarding", .ok)
        case nil: (label, tone) = ("Scheduled", .quiet)
        default: (label, tone) = (c.delayMinutes ?? 0 >= 15 ? "Delayed" : "On time", c.delayMinutes ?? 0 >= 15 ? .late : .ok)
        }
    }

    var fill: Color {
        switch tone {
        case .ok: Color(light: 0xE7F9F3, dark: 0x12271F)
        case .late: Color(light: 0xFDEFE2, dark: 0x2C1E10)
        case .bad: Color(light: 0xFDE8E8, dark: 0x2E1414)
        case .quiet: Color(light: 0xF0F0F2, dark: 0x26262A)
        }
    }
    var ink: Color {
        switch tone {
        case .ok: Color(light: 0x216E55, dark: 0x72D6B0)
        case .late: Color(light: 0xC56511, dark: 0xF2A764)
        case .bad: Color(light: 0xB42318, dark: 0xF97066)
        case .quiet: Color(light: 0x6B6B73, dark: 0xA1A1AA)
        }
    }
    var tint: Color {
        switch tone { case .ok: .green; case .late: .orange; case .bad: .red; case .quiet: .gray }
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

// MARK: - The sheet

struct GateSheet: View {
    let watch: GateWatch
    @State private var showPass = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let card = watch.card {
                    BoardingPass(card: card, watch: watch, showPass: $showPass)
                    if !card.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(card.notes, id: \.self) { n in
                                Label(n, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: 340, alignment: .leading)
                    }
                    if let at = watch.fetchedAt {
                        Text("Checked \(at, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 28).padding(.horizontal, 16).padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showPass) { PassView(watch: watch) }
    }
}

// MARK: - The pass (after Jakub Antalik's "Boarding Pass Check-in", transitions.dev)

private enum PassAction: Equatable { case add, adding, show }

struct BoardingPass: View {
    let card: GateCard
    let watch: GateWatch
    @Binding var showPass: Bool

    @State private var topHeight: CGFloat = 150
    @State private var picking = false
    @State private var item: PhotosPickerItem?
    @State private var adding = false
    @Environment(\.colorScheme) private var scheme

    private var action: PassAction { adding ? .adding : watch.pass == nil ? .add : .show }
    private var status: GateStatus { GateStatus(card) }

    var body: some View {
        VStack(spacing: 0) {
            top
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            perforation
            bottom
        }
        .frame(maxWidth: 340)
        .background {
            let shape = TicketShape(notchY: topHeight + 12)
            shape.cutFill(Color(.secondarySystemGroupedBackground))
                .overlay { Grain().opacity(scheme == .dark ? 0.07 : 0.05).clipShape(shape) }
                .overlay { shape.stroke(Color.primary.opacity(0.06), lineWidth: 1) }
                .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
                .shadow(color: .black.opacity(0.04), radius: 1.5, y: 1)
        }
        .photosPicker(isPresented: $picking, selection: $item, matching: .images)
        .onChange(of: item) {
            guard let item else { return }
            adding = true
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                try? await Task.sleep(for: .milliseconds(450))   // long enough to read the spinner
                withAnimation(.smooth(duration: 0.3)) {
                    if let data { _ = watch.setPass(data) }
                    adding = false
                }
                self.item = nil
            }
        }
        .sensoryFeedback(.success, trigger: watch.pass != nil)
    }

    // MARK: Top: flight, status, route

    private var top: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Text("\(card.flightLabel) · \(Self.day(card.date))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(status.label)
                    .id(status.label)
                    .transition(.blurReplace(.upUp))   // exits up, the new word rises in from below
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6).frame(height: 18)
                    .foregroundStyle(status.ink)
                    .background(status.fill, in: .capsule)
                    .overlay { Capsule().strokeBorder(status.ink.opacity(0.14), lineWidth: 1) }
                    .animation(.easeInOut(duration: 0.15), value: status)
            }
            HStack(alignment: .top, spacing: 8) {
                end(code: card.from, city: card.fromCity, time: card.departsEst ?? card.departs, leading: true)
                path.padding(.top, 16)
                end(code: card.to, city: card.toCity, time: card.arrivesEst ?? card.arrives, leading: false)
            }
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 12)
    }

    private func end(code: String?, city: String?, time: String?, leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: 0) {
            Text(code ?? "—").font(.system(size: 40, weight: .medium)).frame(height: 48)
            Text(city ?? " ").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            if let time {
                Text(time)
                    .font(.system(size: 13)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.5, dampingFraction: 0.62), value: time)
                    .padding(.top, 8)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var path: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 6, height: 6)
                Dashes(on: 3, off: 3).dashed(Color.secondary.opacity(0.45), lineWidth: 1).frame(height: 1)
                Image(systemName: "airplane").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Dashes(on: 3, off: 3).dashed(Color.secondary.opacity(0.45), lineWidth: 1).frame(height: 1)
                Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 6, height: 6)
            }
            if let m = card.durationMinutes {
                Text("\(m / 60)h \(m % 60)m").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Perforation and bottom

    private var perforation: some View {
        Dashes(on: 4, off: 4).dashed(Color.primary.opacity(0.12), lineWidth: 1)
            .frame(height: 1)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                         .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .padding(.horizontal, 20)
            .frame(height: 24)
    }

    private var bottom: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                cell("Gate", card.gate)
                cell("Terminal", card.terminal)
                cell("Seat", card.seat)
                cell("Class", card.cabin)
            }
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color.primary.opacity(0.08), location: 0.2),
                                   .init(color: Color.primary.opacity(0.08), location: 0.8), .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            HStack(spacing: 12) {
                Text(card.carrier)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(light: 0x222A54, dark: 0xD8E8F3))
                    .frame(width: 32, height: 32)
                    .background(Color(light: 0xD8E8F3, dark: 0x2C3352), in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.booking.map { "Booking \($0)" } ?? card.flightLabel).font(.system(size: 13)).lineLimit(1)
                    Text(watch.pass == nil ? "No pass saved" : "Pass saved on this phone")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                cta
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
    }

    private func cell(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.system(size: 13)).monospacedDigit().lineLimit(1)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.5, dampingFraction: 0.62), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The button: Add pass → (spinner) → Show pass

    private var cta: some View {
        Button {
            switch action {
            case .add: picking = true
            case .adding: break
            case .show: showPass = true
            }
        } label: {
            HStack(spacing: 0) {
                ZStack {
                    Spinner().opacity(action == .adding ? 1 : 0).scaleEffect(action == .adding ? 1 : 0.25).blur(radius: action == .adding ? 0 : 2)
                    Image(systemName: "qrcode").font(.system(size: 13, weight: .semibold))
                        .opacity(action == .show ? 1 : 0).scaleEffect(action == .show ? 1 : 0.25).blur(radius: action == .show ? 0 : 2)
                }
                .frame(width: action == .add ? 0 : 16, height: 16)
                .padding(.trailing, action == .add ? 0 : 6)
                .clipped()
                Text(label)
                    .id(label)
                    .transition(.blurReplace)
            }
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.leading, action == .add ? 12 : 10).padding(.trailing, 12)
            .frame(height: 36)
            .foregroundStyle(action == .show ? Color.primary : Color(.systemBackground))
            .background(action == .show ? Color(uiColor: .label).opacity(scheme == .dark ? 0.07 : 0.04) : Color(uiColor: .label), in: .capsule)
            .shadow(color: .black.opacity(action == .show ? 0 : (scheme == .dark ? 0.4 : 0.2)), radius: 1, y: 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: action)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(action == .show ? "Show boarding pass" : action == .adding ? "Adding boarding pass" : "Add boarding pass from Photos")
    }

    private var label: String {
        switch action { case .add: "Add pass"; case .adding: "Adding"; case .show: "Show pass" }
    }

    private static func day(_ ymd: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: ymd) else { return ymd }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Pieces

/// A rounded ticket with two half-circle bites at the perforation, cut through so whatever is
/// behind the card shows in them.
struct TicketShape: Shape {
    var notchY: CGFloat
    var radius: CGFloat = 24
    var notch: CGFloat = 10

    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
        for x in [r.minX, r.maxX] {
            p.addEllipse(in: CGRect(x: x - notch, y: notchY - notch, width: notch * 2, height: notch * 2))
        }
        return p
    }

    /// Even-odd, so the bites are holes rather than more card.
    func cutFill<S: ShapeStyle>(_ style: S) -> some View { fill(style, style: FillStyle(eoFill: true)) }
}

struct Dashes: Shape {
    var on: CGFloat
    var off: CGFloat
    func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: r.minX, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    func dashed(_ color: Color, lineWidth: CGFloat) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: [on, off]))
    }
}

/// The paper's grain: fixed specks, drawn once.
private struct Grain: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> CGFloat { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return CGFloat(seed % 10_000) / 10_000 }
            for _ in 0..<Int(size.width * size.height / 5) {
                let g = next()
                ctx.fill(Path(CGRect(x: next() * size.width, y: next() * size.height, width: 1, height: 1)),
                         with: .color(Color(white: g, opacity: 0.9)))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

private struct Spinner: View {
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0.1, to: 1)
            .stroke(AngularGradient(colors: [.clear, .primary], center: .center), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(configuration.isPressed ? nil : .spring(response: 0.15), value: configuration.isPressed)
    }
}

/// The saved pass, full screen on white with the brightness up for the scanner; put back on close.
private struct PassView: View {
    let watch: GateWatch
    @Environment(\.dismiss) private var dismiss
    @State private var before: CGFloat?
    @State private var replacing = false
    @State private var item: PhotosPickerItem?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.white.ignoresSafeArea()
            if let img = watch.pass {
                Image(uiImage: img).resizable().scaledToFit().padding(16)
            }
            HStack(spacing: 10) {
                Menu {
                    Button("Replace pass", systemImage: "photo") { replacing = true }
                    Button("Remove pass", systemImage: "trash", role: .destructive) { watch.removePass(); dismiss() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Pass options")
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Close")
            }
            .tint(.black)
            .padding(16)
        }
        .onAppear { before = screen?.brightness; screen?.brightness = 1 }
        .onDisappear { if let before { screen?.brightness = before } }
        .photosPicker(isPresented: $replacing, selection: $item, matching: .images)
        .onChange(of: item) {
            guard let item else { return }
            Task { if let data = try? await item.loadTransferable(type: Data.self) { _ = watch.setPass(data) }; self.item = nil }
        }
        .preferredColorScheme(.light)
    }
}
