import AVFoundation
import SwiftUI
import UserNotifications
import VisionKit

/// First launch: meet Otto, pair with the Mac, then the few switches that make it useful.
/// Runs before OttoStore exists, so the store starts on the server it just paired with.
struct OnboardingFlow: View {
    let finish: () -> Void
    @State private var step = Step.hello
    @State private var forward = true
    /// Reduce Motion: pages cross-fade instead of sliding.
    @Environment(\.accessibilityReduceMotion) private var still

    enum Step: Int, CaseIterable { case hello, connect, notify, talk, share, awake, done }

    var body: some View {
        VStack(spacing: 0) {
            if step != .hello && step != .done { dots.padding(.top, 12) }
            ZStack {
                page(step)
                    .id(step)
                    .transition(still ? .opacity : .asymmetric(
                        insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                        removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .background(Color(.systemBackground))
        #if DEBUG
        .onAppear {
            // `-onboardingStep 3` opens on that page, for screenshots.
            let n = UserDefaults.standard.integer(forKey: "onboardingStep")
            if let s = Step(rawValue: n) { step = s }
        }
        #endif
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropFirst().dropLast(), id: \.self) { s in
                Capsule()
                    .fill(s == step ? Color.orange : Color(.tertiarySystemFill))
                    .frame(width: s == step ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: step)
    }

    private func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        withAnimation(.smooth(duration: 0.35)) { step = s }
    }
    private func next() { if let s = Step(rawValue: step.rawValue + 1) { go(s) } }

    @ViewBuilder private func page(_ s: Step) -> some View {
        switch s {
        case .hello: HelloPage(next: next)
        case .connect: ConnectPage(next: next)
        case .notify: NotifyPage(next: next)
        case .talk: TalkPage(next: next)
        case .share: SharePage(next: next)
        case .awake: AwakePage(next: next)
        case .done: DonePage(finish: finish)
        }
    }
}

// MARK: - Shared pieces

/// The page's picture, the headline and a line under it, then anything the page asks of you, and the
/// button that moves on. A form or a list comes after the words that explain it, for the eye and VoiceOver.
private struct Page<Hero: View, Content: View, Footer: View>: View {
    let title: String
    let line: String
    @ViewBuilder let hero: Hero
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        // Fills the page as before; scrolls only once large text no longer fits on it.
        GeometryReader { g in
            ScrollView {
                VStack(spacing: 0) {
                    // A fixed start, not a centring spacer: the picture and headline sit at the same height on every step.
                    Color.clear.frame(height: max(24, g.size.height * 0.1))
                    if Hero.self != EmptyView.self { hero.padding(.bottom, 32) }
                    VStack(spacing: 10) {
                        Text(title).font(size: 28, weight: .bold, relativeTo: .title).multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(line).font(size: 16, relativeTo: .callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    if Content.self != EmptyView.self { content.padding(.top, 24) }
                    Spacer(minLength: 32)
                    // Room for one link under the button on every step, so the button doesn't jump between them:
                    // a hidden button and link set the height, at whatever size the text is.
                    ZStack(alignment: .top) {
                        VStack(spacing: 6) { Primary(label: " ") {}; Secondary(label: " ") {} }.hidden()
                        VStack(spacing: 6) { footer }
                    }
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, minHeight: g.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

extension Page where Content == EmptyView {
    init(title: String, line: String, @ViewBuilder hero: () -> Hero, @ViewBuilder footer: () -> Footer) {
        self.init(title: title, line: line, hero: hero, content: { EmptyView() }, footer: footer)
    }
}

private struct Primary: View {
    let label: String
    var busy = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Text(label).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(Color(white: 0.12)) }
            }
            .font(size: 17, weight: .semibold, relativeTo: .headline)
            .foregroundStyle(Color(white: 0.12))   // white on this orange is ~2:1
            .frame(maxWidth: .infinity).frame(minHeight: 52)
        }
        .buttonStyle(.glassProminent)
        .tint(.orange)
        .disabled(busy)
    }
}

private struct Secondary: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(label, action: action)
            .font(size: 15, weight: .medium, relativeTo: .subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
    }
}

/// A big SF Symbol on a soft tinted disc: each page's picture.
private struct Glyph: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 52, weight: .regular))
            .foregroundStyle(.primary)   // white in dark, black in light; the circle keeps the orange
            .frame(width: 128, height: 128)
            .background(Color.orange.opacity(0.12), in: .circle)
            .symbolEffect(.bounce, options: .nonRepeating, isActive: !still)
    }
}

// MARK: - Pages

private struct HelloPage: View {
    let next: () -> Void
    @State private var awake = false

    var body: some View {
        Page(title: "Hi, I’m Otto.",
             line: "One chat that keeps track of the rest: your mail, your calendar, what you said you’d do, and what you asked me to remember.") {
            OttoAvatar(size: 148, asleep: !awake)
                .onTapGesture { withAnimation(.spring) { awake = true } }
                .task { try? await Task.sleep(for: .seconds(1.2)); withAnimation(.spring) { awake = true } }
        } footer: {
            Primary(label: "Get started", action: next)
        }
    }
}

/// Pairs with the Mac: a QR code from `bun otto/apptokens.ts new <name> --server <url>`,
/// the same otto://pair link pasted, or the two fields typed in. Checked against the server
/// before it's saved, so a typo shows here rather than as an Otto that never wakes up.
private struct ConnectPage: View {
    let next: () -> Void
    @AppStorage("serverURL") private var savedServer = ""
    @AppStorage("serverToken") private var savedToken = ""
    @State private var server = ""
    @State private var token = ""
    @State private var manual = false
    @State private var scanning = false
    @State private var checking = false
    @State private var problem: String?
    /// Paste only when there's something to paste; the system draws an empty one dimmed, like a broken button.
    /// Reading `hasStrings` doesn't trigger the paste prompt.
    @State private var canPaste = UIPasteboard.general.hasStrings

    private var canScan: Bool { DataScannerViewController.isSupported }

    /// Right under what it's about (the fields, or the command and Paste), not under a link or down by the
    /// buttons. Its line is always held, so the page doesn't re-centre and jump when an error arrives.
    private var problemLine: some View {
        Text(problem ?? " ").font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            .opacity(problem == nil ? 0 : 1)
            .accessibilityHidden(problem == nil)
    }

    var body: some View {
        Page(title: "Connect to your Mac",
             line: manual ? "The server address and the app token from your Mac."
                          : "Run this on your Mac, then scan the code it opens.") {
            if !manual { Glyph(name: "qrcode.viewfinder") }
        } content: {
            VStack(spacing: 12) {
                if manual {
                    // Two fields with a hairline between, so filled in they still read as two.
                    VStack(spacing: 0) {
                        TextField("https://your-mac.your-tailnet.ts.net", text: $server)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityLabel("Server address")   // the placeholder is an example, not a name
                            .padding(14)
                        Divider().padding(.leading, 14)
                        SecureField("App token", text: $token)
                            .padding(14)
                    }
                    .textFieldStyle(.plain)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))
                    problemLine
                    Secondary(label: "Scan a code instead") { withAnimation { manual = false; problem = nil } }
                } else {
                    // The whole command, as it runs: a shell line continuation keeps "--server" in one piece,
                    // and the address is an example to swap for the Mac's own.
                    Text(verbatim: "bun otto/apptokens.ts new iPhone \\\n  --server \\\n  https://your-mac.your-tailnet.ts.net")
                        .font(size: 13, design: .monospaced, relativeTo: .footnote)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12, style: .continuous))
                    // The same pairing link, pasted: with the command it pairs, not down among the buttons.
                    if canPaste {
                        PasteButton(payloadType: String.self) { strings in
                            guard let s = strings.first else { return }
                            Task { @MainActor in await take(s) }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.titleAndIcon)
                        .tint(.orange)   // the page's one accent
                    }
                    problemLine
                    // The other way in, beside the one it replaces; with no camera it's the big button instead.
                    if canScan { Secondary(label: "Type it in") { withAnimation { manual = true; problem = nil } } }
                }
            }
        } footer: {
            if manual {
                Primary(label: "Connect", busy: checking) { Task { await connect(server, token) } }
            } else if canScan {
                Primary(label: "Scan code", busy: checking) {
                    // Denied, the scanner opens black with no word why: say so here instead.
                    if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video)) {
                        problem = "Otto can’t use the camera. Turn it on in Settings, or type it in."
                    } else { scanning = true }
                }
            } else {
                // No camera scanner: typing it in is the main way, so it gets the big button.
                Primary(label: "Type it in") { withAnimation { manual = true; problem = nil } }
            }
            Secondary(label: "Look around with sample data") { next() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
        #if DEBUG
        // `-connectManual` opens the typed form; `-connectProblem` with it shows the error line.
        .onAppear {
            if CommandLine.arguments.contains("-connectManual") { manual = true; server = "https://mac.example.ts.net"; token = "demo-token" }
            if CommandLine.arguments.contains("-connectProblem") { problem = "Can’t reach the Mac. Is Tailscale on?" }
        }
        #endif
        .sheet(isPresented: $scanning) {
            QRScanner { code in
                scanning = false
                Task { await take(code) }
            }
            .ignoresSafeArea()
            .overlay(alignment: .topTrailing) {
                Button("Cancel", systemImage: "xmark") { scanning = false }
                    .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.large).padding()
            }
            .presentationDetents([.large])
        }
    }

    /// An otto://pair link from the scanner or the clipboard.
    private func take(_ text: String) async {
        guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "otto", c.host == "pair",
              let s = c.queryItems?.first(where: { $0.name == "server" })?.value,
              let t = c.queryItems?.first(where: { $0.name == "token" })?.value
        else { problem = "That isn’t an Otto pairing code."; return }
        server = s; token = t
        await connect(s, t)
    }

    private func connect(_ s: String, _ t: String) async {
        let s = s.trimmingCharacters(in: .whitespaces), t = t.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: s), url.host != nil, !t.isEmpty else { problem = "Fill in both."; return }
        checking = true; problem = nil
        defer { checking = false }
        var req = URLRequest(url: url.appending(path: "app/settings"), timeoutInterval: 10)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        do {
            let (_, res) = try await URLSession.shared.data(for: req)
            switch (res as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300:
                savedServer = s; savedToken = t
                next()
            case 401: problem = "The Mac didn’t accept that token."
            default: problem = "Reached something, but it isn’t Otto."
            }
        } catch {
            problem = "Can’t reach the Mac. Is Tailscale on?"
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                guard !done, let s = b.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                found(s)
            }
        }
    }
}

private struct NotifyPage: View {
    let next: () -> Void
    var body: some View {
        Page(title: "Let me tap you on the shoulder",
             line: "Replies, reminders you set, and the odd thing that can’t wait. Everything else waits for a quiet moment.") {
            Glyph(name: "bell.badge")
        } footer: {
            Primary(label: "Allow notifications") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                    Task { @MainActor in next() }
                }
            }
            Secondary(label: "Not now", action: next)
        }
    }
}

private struct TalkPage: View {
    let next: () -> Void
    var body: some View {
        Page(title: "Talk to me anywhere",
             line: "You don’t have to open the app.") {
            Glyph(name: "person.wave.2.fill")
        } content: {
            VStack(spacing: 0) {
                row("mic.fill", "\u{201C}Hey Siri, ask Otto\u{2026}\u{201D}", "I answer out loud.")
                Divider().padding(.leading, 52)
                row("button.horizontal.top.press", "The Action Button", "Settings → Action Button → Shortcut → Message Otto.")
                Divider().padding(.leading, 52)
                row("waveform", "Walkie-talkie", "Hold the phone button in the chat.")
            }
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18, style: .continuous))
        } footer: {
            Primary(label: "Continue", action: next)
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // The text colour, as the onboarding glyphs are, and scaled with the title beside it.
            Image(systemName: icon).font(size: 18, relativeTo: .callout).foregroundStyle(.primary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(size: 16, weight: .semibold, relativeTo: .callout)
                Text(detail).font(size: 14, relativeTo: .subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

private struct SharePage: View {
    let next: () -> Void
    var body: some View {
        Page(title: "Send me anything",
             line: "Links, photos, PDFs, a receipt. Share from any app and pick Otto. If it isn’t in the row, tap More and add it.") {
            Glyph(name: "square.and.arrow.up")
        } footer: {
            Primary(label: "Continue", action: next)
        }
    }
}

private struct AwakePage: View {
    let next: () -> Void
    /// Read by Keepalive.enabled.
    @AppStorage("stayAwake") private var stayAwake = true
    var body: some View {
        Page(title: "Stay connected",
             line: "Keeps the line to your Mac open in the background, so messages arrive the moment I send them. Costs a little battery.") {
            Glyph(name: "bolt.horizontal.fill")
        } footer: {
            // Asked like notifications are: a yes and a not now, no switch to read first.
            Primary(label: "Stay connected") { stayAwake = true; next() }
            Secondary(label: "Not now") { stayAwake = false; next() }
        }
    }
}

private struct DonePage: View {
    let finish: () -> Void
    @AppStorage("serverURL") private var server = ""
    var body: some View {
        Page(title: "All set",
             line: server.isEmpty ? "You’re on sample data. Pair with your Mac any time from my contact card."
                                  : "Say hi whenever. I’ll be here.") {
            OttoAvatar(size: 148)
        } footer: {
            Primary(label: "Say hi", action: finish)
        }
    }
}
