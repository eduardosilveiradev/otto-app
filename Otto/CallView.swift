import ActivityKit
import AVFoundation
import Combine
import SwiftUI
import Vapi

/// A Vapi web call to the Otto assistant: audio over the internet instead of the
/// phone network, so no carrier minutes. Config lives in UserDefaults like the
/// server's: `vapiPublicKey`, `vapiAssistantId`, and `ownerNumber`, which is passed
/// as the caller's number because a web call has none and the assistant's prompt
/// recognises its owner by `{{customer.number}}`.
/// Calls Otto from anywhere: the header's phone button, or the "Call Otto" App Shortcut.
/// `-call` (with `-vapiPublicKey`, `-vapiAssistantId` and, in DEBUG, `-vapiHost`): open straight into one.
@MainActor @Observable
final class CallLauncher {
    static let shared = CallLauncher()
    /// The web call's screen is up.
    var open = ProcessInfo.processInfo.arguments.contains("-call")
    /// Neither a web call nor Otto's number is set up: the alert that says where.
    var explain = false

    /// A web call (free, over the internet) when Vapi is set up; Otto's phone line, dialled with the Phone
    /// app, otherwise; and with neither, the alert pointing at details.
    func start() {
        // Otto's phone line (the Vapi assistant). Set in details.
        let digits = (UserDefaults.standard.string(forKey: "callNumber") ?? "").filter { $0.isNumber || $0 == "+" }
        if CallManager.configured { open = true }
        else if let url = URL(string: "tel:\(digits)"), !digits.isEmpty { UIApplication.shared.open(url) }
        else { explain = true }
    }
}

@MainActor @Observable
final class CallManager {
    /// The call under way, for what reaches it from outside the call screen: its Live Activity's buttons, the Action Button.
    static weak var current: CallManager?
    enum Phase { case idle, connecting, live, ended }
    var phase = Phase.idle { didSet { Self.active = phase == .connecting || phase == .live; showOutside() } }
    /// The keepalive's silent audio must stay out of a call's audio session.
    static var active = false
    var muted = false { didSet { updateOutside() } }
    var speaker = false
    var ottoSpeaking = false
    var startedAt: Date?
    var error: String?
    /// What's been said, as the call service writes it down: the finished sentences, and the one still being spoken.
    private(set) var lines: [CallRecord.Line] = []
    private(set) var hearing: CallRecord.Line?
    /// The thread the call was placed from; nil is Otto's own, where it leaves its line when it ends.
    private var context: String?

    private var vapi: Vapi?
    private var bag = Set<AnyCancellable>()
    /// The request that sets the call up; cancelled when it's given up on, so it can't connect later.
    private var attempt: Task<Void, Never>?
    /// The call on the Lock Screen and in the Dynamic Island while it's live (the audio keeps the app
    /// running in the background, so it can end it itself).
    private var activity: Activity<CallActivityAttributes>?

    private func showOutside() {
        if phase == .live, activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled {
            activity = try? Activity.request(attributes: CallActivityAttributes(), content: .init(state: .init(started: .now, muted: muted), staleDate: nil))
        } else if phase == .ended || phase == .idle, let a = activity {
            activity = nil
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Mute changed here or from the Lock Screen: the Live Activity's button follows.
    private func updateOutside() {
        guard let a = activity else { return }
        let state = CallActivityAttributes.ContentState(started: startedAt ?? .now, muted: muted)
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    static var configured: Bool {
        let d = UserDefaults.standard
        return !(d.string(forKey: "vapiPublicKey") ?? "").isEmpty && !(d.string(forKey: "vapiAssistantId") ?? "").isEmpty
    }

    /// 0…1, how loud Otto is right now; drives the face.
    var level: Float { vapi?.remoteAudioLevel ?? 0 }

    func start(context: String? = nil) {
        let d = UserDefaults.standard
        guard let key = d.string(forKey: "vapiPublicKey"), let assistant = d.string(forKey: "vapiAssistantId") else { return }
        #if DEBUG
        // `-vapiHost localhost`: Vapi's API at localhost:3001, a dead or stalling stand-in, to test how calls fail.
        let vapi = Vapi(publicKey: key, host: d.string(forKey: "vapiHost"))
        #else
        let vapi = Vapi(publicKey: key)
        #endif
        self.vapi = vapi
        self.context = context
        Self.current = self
        error = nil
        lines = []; hearing = nil; startedAt = nil
        phase = .connecting
        vapi.eventPublisher.receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self else { return }
            switch event {
            case .callDidStart:
                phase = .live; startedAt = .now
                // Daily reports no levels until asked to: without these both stay nil.
                Task {
                    try? await vapi.startRemoteParticipantsAudioLevelObserver()
                    try? await vapi.startLocalAudioLevelObserver()
                }
            // Ended before it started: a room that can't be joined says "left" before its error.
            case .callDidEnd: if phase == .connecting { fail("Couldn’t connect.") } else { finish() }
            case .speechUpdate(let s): if s.role == .assistant { ottoSpeaking = s.status == .started }
            case .transcript(let t):
                let line = CallRecord.Line(otto: t.role == .assistant, text: t.transcript)
                if t.transcriptType == .final { lines.append(line); hearing = nil } else { hearing = line }
            // The app's own words, not the system's ("Could not connect to the server."). A web call goes over
            // the internet to the call service, not to the Mac, so the Mac isn't what it blames.
            case .error: fail("Couldn’t start the call. Check your connection and try again.")
            default: break
            }
        }.store(in: &bag)
        // "calling…" doesn't wait forever: a call that hasn't connected in 20 seconds won't.
        Task {
            try? await Task.sleep(for: .seconds(20))
            if self.vapi === vapi && phase == .connecting { fail("Couldn’t connect.") }
        }

        var overrides: [String: Any] = [:]
        var values: [String: Any] = [:]
        if let owner = d.string(forKey: "ownerNumber"), !owner.isEmpty { values["customer"] = ["number": owner] }
        // Which conversation the call came from; the assistant's prompt reads it as {{conversation}}.
        if let context { values["conversation"] = context }
        if !values.isEmpty { overrides["variableValues"] = values }
        // A failure comes back as an `.error` event (Vapi sends one before it throws); the timeout covers the rest.
        attempt = Task { _ = try? await vapi.start(assistantId: assistant, assistantOverrides: overrides) }
    }

    /// Ends this attempt for good: nothing it sends later (a late answer, an event) changes the screen.
    func hangUp() { attempt?.cancel(); bag = []; vapi?.stop(); finish() }

    /// Over. A call that was live leaves its line in Otto's thread: how long it ran, with what was said behind it.
    private func finish() {
        if phase == .live, context == nil, let start = startedAt {
            if let hearing { lines.append(hearing) }   // cut off mid-sentence: what was heard of it still counts
            OttoStore.shared.logCall(CallRecord(seconds: max(1, Int(Date.now.timeIntervalSince(start).rounded())), lines: lines))
        }
        phase = .ended
    }

    private func fail(_ message: String) { error = message; hangUp() }

    /// Loudspeaker vs earpiece. The call's audio session is Vapi's; this only reroutes it.
    func toggleSpeaker() {
        speaker.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    func toggleMute() {
        muted.toggle()
        let m = muted
        Task { try? await vapi?.setMuted(m) }
    }
}

struct CallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var call = CallManager()
    /// The group or pip the call was placed from; nil from Otto's own thread.
    var context: String? = nil
    @State private var transcript = false
    /// Reduce Motion: the face keeps its size; the caption and the timer say the call is live.
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()   // plain black: nothing glows

            VStack(spacing: 0) {
                Spacer()
                TimelineView(.animation) { _ in
                    OttoAvatar(size: 180, thinking: call.phase == .connecting)
                        .scaleEffect(still ? 1 : 1 + CGFloat(min(1, call.level * 4)) * 0.08)   // remote levels are quiet; boost
                        .animation(.easeOut(duration: 0.12), value: call.level)
                }
                .frame(height: 340)

                Text("Otto").font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
                    .padding(.top, 8)
                status.font(.headline).foregroundStyle(.white.opacity(0.6)).padding(.top, 4)
                // What's being said, in words, for a noisy street or ears that didn't catch it: the last line,
                // and the whole call behind it.
                if let line = call.hearing ?? call.lines.last {
                    Button { transcript = true } label: {
                        Text((line.otto ? "" : "You: ") + line.text)
                            .font(.subheadline).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).lineLimit(3)
                            .padding(.horizontal, 32).padding(.vertical, 10).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((line.otto ? "Otto said: " : "You said: ") + line.text)
                    .accessibilityHint("Shows everything said so far")
                    .transition(.opacity)
                }
                if let e = call.error {
                    Text(e).font(.footnote).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)   // one status with "call failed"
                        .padding(.top, 8).padding(.horizontal, 40)
                }
                Spacer()

                HStack(spacing: 40) {
                    if call.error != nil {
                        // A failed call keeps its screen with the two ways on, as FaceTime does.
                        RoundButton(symbol: "xmark", fill: .white.opacity(0.18), tint: .white, label: "Close") { dismiss() }
                        RoundButton(symbol: "phone.fill", fill: .blue, tint: .white, label: "Try again") { call.start(context: context) }
                    } else {
                        RoundButton(symbol: call.speaker ? "speaker.wave.3.fill" : "speaker.fill",
                                    fill: call.speaker ? .white : .white.opacity(0.18),
                                    tint: call.speaker ? .black : .white,
                                    label: "Speaker") { call.toggleSpeaker() }
                        RoundButton(symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                                    fill: call.muted ? .white : .white.opacity(0.18),
                                    tint: call.muted ? .black : .white,
                                    label: "Mute") { call.toggleMute() }
                        RoundButton(symbol: "phone.down.fill", fill: .red, tint: .white, label: "End") {
                            call.hangUp(); dismiss()
                        }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: call.error != nil)   // a cross-fade, so Reduce Motion needs nothing else
                .padding(.bottom, 50)
            }
        }
        .onAppear { call.start(context: context) }
        .sheet(isPresented: $transcript) { CallTranscript(lines: call.lines + (call.hearing.map { [$0] } ?? []), title: "This call") }
        #if DEBUG
        .task(id: call.error) {
            guard call.error != nil, labTryAgain else { return }
            labTryAgain = false
            try? await Task.sleep(for: .seconds(3))
            call.start(context: context)
        }
        #endif
        .onChange(of: call.phase) { _, p in
            if p == .ended && call.error == nil { dismiss() }
        }
        .onDisappear { if call.phase != .ended { call.hangUp() } }
    }

    @ViewBuilder private var status: some View {
        switch call.phase {
        case .idle, .connecting: Text("calling…")
        case .ended: Text(call.error == nil ? "call ended" : "call failed")
        case .live:
            if let start = call.startedAt {
                Text(start, style: .timer).monospacedDigit()
            }
        }
    }
}

/// What was said on a call, line by line, yours on the trailing side as in the thread.
struct CallTranscript: View {
    let lines: [CallRecord.Line]
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.otto ? "Otto" : "You").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                            Text(line.text).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
            .overlay { if lines.isEmpty { ContentUnavailableView("Nothing was written down", systemImage: "text.bubble", description: Text("The call service sent no transcript for this call.")) } }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

#if DEBUG
/// `-tryAgainOnce`: the first "try again" (a call's or the walkie's) presses itself three seconds after
/// it shows, through the tap's own action, to test the retry where nothing can tap (a headless simulator).
var labTryAgain = ProcessInfo.processInfo.arguments.contains("-tryAgainOnce")
#endif

private struct RoundButton: View {
    let symbol: String
    let fill: Color
    let tint: Color
    let label: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 28, weight: .semibold))
                    .frame(width: 76, height: 76)
                    .background(fill, in: .circle)
                    .foregroundStyle(tint)
            }
            .accessibilityLabel(label)   // what the caption says, not the symbol's name
            .accessibilityAddTraits(fill == .white ? .isSelected : [])   // a white fill is a toggle that's on
            Text(label).font(.footnote).foregroundStyle(.white.opacity(0.7)).accessibilityHidden(true)
        }
    }
}
