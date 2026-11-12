import AVFoundation
import Combine
import SwiftUI
import Vapi
import VoiceGlowKit

/// A Vapi web call to the Otto assistant: audio over the internet instead of the
/// phone network, so no carrier minutes. Config lives in UserDefaults like the
/// server's: `vapiPublicKey`, `vapiAssistantId`, and `ownerNumber`, which is passed
/// as the caller's number because a web call has none and the assistant's prompt
/// recognises its owner by `{{customer.number}}`.
@MainActor @Observable
final class CallManager {
    enum Phase { case idle, connecting, live, ended }
    var phase = Phase.idle { didSet { Self.active = phase == .connecting || phase == .live } }
    /// The keepalive's silent audio must stay out of a call's audio session.
    static var active = false
    var muted = false
    var speaker = false
    var ottoSpeaking = false
    var startedAt: Date?
    var error: String?

    private var vapi: Vapi?
    private var bag = Set<AnyCancellable>()
    /// The request that sets the call up; cancelled when it's given up on, so it can't connect later.
    private var attempt: Task<Void, Never>?

    static var configured: Bool {
        let d = UserDefaults.standard
        return !(d.string(forKey: "vapiPublicKey") ?? "").isEmpty && !(d.string(forKey: "vapiAssistantId") ?? "").isEmpty
    }

    /// 0…1, how loud Otto is right now; drives the face.
    var level: Float { vapi?.remoteAudioLevel ?? 0 }
    /// 0…1, whoever is louder, Otto or the user (unless muted); drives the screen glow.
    var anyLevel: Float { max(level, muted ? 0 : vapi?.localAudioLevel ?? 0) }

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
        error = nil
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
            case .callDidEnd: if phase == .connecting { fail("Couldn’t connect.") } else { phase = .ended }
            case .speechUpdate(let s): if s.role == .assistant { ottoSpeaking = s.status == .started }
            case .error(let e): fail(e.localizedDescription)
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
    func hangUp() { attempt?.cancel(); bag = []; vapi?.stop(); phase = .ended }

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

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.1, blue: 0.06), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // The same glow as a recording voice note, rising from the screen's edge with either voice.
            Color.clear
                .voiceGlow(type: .mobile, levelProvider: { [call] in Double(min(1, call.anyLevel * 4)) },
                           active: call.phase == .live, theme: .dark, cornerRadius: 55, options: {
                               var o = VoiceGlowOptions()
                               o.sensitivity = 10; o.attack = 0.12; o.release = 0.5; o.idle = 0.4
                               o.brightness = 1.4; o.saturation = 1.5
                               return o
                           }())
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()
                TimelineView(.animation) { _ in
                    OttoAvatar(size: 180, thinking: call.phase == .connecting)
                        .scaleEffect(1 + CGFloat(min(1, call.level * 4)) * 0.08)   // remote levels are quiet; boost
                        .animation(.easeOut(duration: 0.12), value: call.level)
                }
                .frame(height: 340)

                Text("Otto").font(.largeTitle.weight(.semibold)).foregroundStyle(.white)
                    .padding(.top, 8)
                status.font(.headline).foregroundStyle(.white.opacity(0.6)).padding(.top, 4)
                if let e = call.error {
                    Text(e).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                        .padding(.top, 8).padding(.horizontal, 40)
                }
                Spacer()

                HStack(spacing: 40) {
                    if call.error != nil {
                        // A failed call keeps its screen with the two ways on, as FaceTime does.
                        RoundButton(symbol: "xmark", fill: .white.opacity(0.18), tint: .white, label: "close") { dismiss() }
                        RoundButton(symbol: "phone.fill", fill: .green, tint: .white, label: "try again") { call.start(context: context) }
                    } else {
                        RoundButton(symbol: call.speaker ? "speaker.wave.3.fill" : "speaker.fill",
                                    fill: call.speaker ? .white : .white.opacity(0.18),
                                    tint: call.speaker ? .black : .white,
                                    label: "speaker") { call.toggleSpeaker() }
                        RoundButton(symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                                    fill: call.muted ? .white : .white.opacity(0.18),
                                    tint: call.muted ? .black : .white,
                                    label: "mute") { call.toggleMute() }
                        RoundButton(symbol: "phone.down.fill", fill: .red, tint: .white, label: "end") {
                            call.hangUp(); dismiss()
                        }
                    }
                }
                .animation(.easeOut(duration: 0.2), value: call.error != nil)   // a cross-fade, so Reduce Motion needs nothing else
                .padding(.bottom, 50)
            }
        }
        .onAppear { call.start(context: context) }
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
