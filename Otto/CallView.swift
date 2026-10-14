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

    static var configured: Bool {
        let d = UserDefaults.standard
        return !(d.string(forKey: "vapiPublicKey") ?? "").isEmpty && !(d.string(forKey: "vapiAssistantId") ?? "").isEmpty
    }

    /// 0…1, how loud Otto is right now; drives the face.
    var level: Float { vapi?.remoteAudioLevel ?? 0 }
    /// 0…1, whoever is louder, Otto or the user (unless muted); drives the screen glow.
    var anyLevel: Float { max(level, muted ? 0 : vapi?.localAudioLevel ?? 0) }

    func start() {
        let d = UserDefaults.standard
        guard let key = d.string(forKey: "vapiPublicKey"), let assistant = d.string(forKey: "vapiAssistantId") else { return }
        let vapi = Vapi(publicKey: key)
        self.vapi = vapi
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
            case .callDidEnd: phase = .ended
            case .speechUpdate(let s): if s.role == .assistant { ottoSpeaking = s.status == .started }
            case .error(let e): error = e.localizedDescription; phase = .ended
            default: break
            }
        }.store(in: &bag)

        var overrides: [String: Any] = [:]
        if let owner = d.string(forKey: "ownerNumber"), !owner.isEmpty {
            overrides["variableValues"] = ["customer": ["number": owner]]
        }
        Task {
            do { _ = try await vapi.start(assistantId: assistant, assistantOverrides: overrides) }
            catch { self.error = error.localizedDescription; self.phase = .ended }
        }
    }

    func hangUp() { vapi?.stop(); phase = .ended }

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
                    Text(e).font(.footnote).foregroundStyle(.red.opacity(0.8)).multilineTextAlignment(.center)
                        .padding(.top, 8).padding(.horizontal, 40)
                }
                Spacer()

                HStack(spacing: 40) {
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
                .padding(.bottom, 50)
            }
        }
        .onAppear { call.start() }
        .onChange(of: call.phase) { _, p in
            if p == .ended && call.error == nil { dismiss() }
        }
        .onDisappear { if call.phase != .ended { call.hangUp() } }
    }

    @ViewBuilder private var status: some View {
        switch call.phase {
        case .idle, .connecting: Text("calling…")
        case .ended: Text("call ended")
        case .live:
            if let start = call.startedAt {
                Text(start, style: .timer).monospacedDigit()
            }
        }
    }
}

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
            Text(label).font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
    }
}
