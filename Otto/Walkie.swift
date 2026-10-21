import SwiftUI
import AVFoundation
import AppIntents

/// Opens the walkie-talkie from anywhere: the header's phone button (long press) or the
/// "Walkie-talkie" App Shortcut, which is what goes on the Action Button.
@MainActor @Observable
final class WalkieLauncher {
    static let shared = WalkieLauncher()
    #if DEBUG
    // `-walkie`: open straight into it, for screenshots.
    var open = ProcessInfo.processInfo.arguments.contains("-walkie")
    #else
    var open = false
    #endif
}

struct OpenWalkie: AppIntent {
    static let title: LocalizedStringResource = "Walkie-talkie with Otto"
    static let description = IntentDescription("Hold to talk, let go, hear Otto answer. Made for walking.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WalkieLauncher.shared.open = true
        return .result()
    }
}

// MARK: - The screen

/// Hold-to-talk for when the phone is in your hand and your eyes are on the street: Otto's face
/// is the button. It sends a voice note, so the reply comes back spoken, and plays on its own.
struct WalkieView: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceRecorder()
    @State private var holding = false
    @State private var sentAt: Date?
    @State private var reply: Message?
    @State private var levels: [CGFloat] = Array(repeating: 0, count: 28)
    @State private var speech = AVSpeechSynthesizer()
    private var player: AudioPlayer { .shared }

    private enum Phase { case idle, listening, thinking, speaking }
    private var phase: Phase {
        if recorder.started != nil { return .listening }
        if let r = reply, let a = r.audio, player.playing == a.id { return .speaking }
        if speech.isSpeaking { return .speaking }
        if sentAt != nil && reply == nil { return .thinking }
        return .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
                .accessibilityLabel("Close walkie-talkie")
            }
            .padding(.horizontal, 16).padding(.top, 8)

            Spacer(minLength: 24)

            talkButton

            Text(caption)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: caption)
                .padding(.top, 28)

            Waveform(levels: levels, tint: phase == .listening ? Color.orange : Color.secondary)
                .frame(height: 44)
                .padding(.horizontal, 40)
                .padding(.top, 18)
                .opacity(phase == .listening || phase == .speaking ? 1 : 0.25)

            Spacer(minLength: 24)

            // The last answer, one line: enough to glance at a crossing, no more.
            Text(reply.map { $0.text.isEmpty ? "…" : $0.text } ?? "Hold Otto and talk. Let go to send.")
                .font(.system(size: 16))
                .foregroundStyle(reply == nil ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
                .frame(minHeight: 72, alignment: .top)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: reply?.text)
        }
        .background(Color(.systemBackground))
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            _ = recorder.stop()
            player.stop(); speech.stopSpeaking(at: .immediate)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task { await meter() }
        .onChange(of: store.messages.last?.id) { pickUpReply() }
        .onChange(of: store.messages.last?.audio?.id) { pickUpReply() }
        .sensoryFeedback(.impact(weight: .medium), trigger: holding)
        .sensoryFeedback(.success, trigger: reply?.id)
    }

    // MARK: Talk button: Otto, with a ring that breathes with your voice

    private var talkButton: some View {
        let level = levels.last ?? 0
        return ZStack {
            Circle()
                .fill(Color.orange.opacity(phase == .listening ? 0.18 : 0.08))
                .frame(width: 236, height: 236)
                .scaleEffect(phase == .listening ? 1 + level * 0.35 : 1)
                .animation(.easeOut(duration: 0.08), value: level)
            Circle()
                .strokeBorder(Color.orange.opacity(phase == .listening ? 0.9 : 0), lineWidth: 3)
                .frame(width: 200, height: 200)
                .scaleEffect(phase == .listening ? 1 : 0.9)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: phase == .listening)
            OttoAvatar(size: 180, thinking: phase == .thinking, lookingAtCursor: phase == .listening)
                .scaleEffect(holding ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: holding)
        }
        .contentShape(.circle)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true; Task { await begin() } } }
                .onEnded { _ in holding = false; end() }
        )
        .accessibilityElement()
        .accessibilityLabel("Talk to Otto")
        .accessibilityHint("Touch and hold while you speak, then let go to send.")
        .accessibilityAddTraits(.isButton)
    }

    private var caption: String {
        switch phase {
        case .listening: "Listening"
        case .thinking: "Otto's thinking"
        case .speaking: "Otto"
        case .idle: "Hold to talk"
        }
    }

    // MARK: Recording → voice note → spoken reply

    private func begin() async {
        player.stop(); speech.stopSpeaking(at: .immediate)
        await recorder.start()
        if !holding { end() }   // let go before the mic opened
    }

    private func end() {
        guard let started = recorder.started else { return }
        let short = Date.now.timeIntervalSince(started) < 0.5
        guard let url = recorder.stop() else { return }
        UIApplication.shared.isIdleTimerDisabled = true   // stop() hands the timer back
        if short { try? FileManager.default.removeItem(at: url); return }   // a brush, not a sentence
        reply = nil
        sentAt = .now
        store.sendVoice(url)
    }

    /// The first thing Otto says after the note went up. Plays its voice when it has one;
    /// a text-only answer is read out on the phone so you never have to look.
    private func pickUpReply() {
        guard let since = sentAt,
              let m = store.messages.last(where: { $0.from == .otto && $0.date >= since }) else { return }
        let fresh = reply?.id != m.id
        reply = m
        if let a = m.audio {
            if player.playing != a.id { Task { await player.toggle(a.id) { await store.backend.file(a.id) } } }
        } else if fresh, !m.text.isEmpty {
            // Wait a beat: the spoken version usually follows the text by a moment.
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard reply?.id == m.id, reply?.audio == nil else { return }
                try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
                speech.speak(AVSpeechUtterance(string: m.text))
            }
        }
        sentAt = nil
    }

    /// Feeds the waveform: your level while you talk, a bouncing trace while Otto talks.
    private func meter() async {
        while !Task.isCancelled {
            let v: CGFloat
            switch phase {
            case .listening: v = CGFloat(min(1, recorder.level() * 4))
            case .speaking:
                let t = Date.now.timeIntervalSinceReferenceDate
                v = 0.2 + 0.6 * abs(sin(t * 7.3)) * (0.5 + 0.5 * abs(sin(t * 2.1)))
            default: v = 0
            }
            levels.removeFirst(); levels.append(v)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let tint: Color
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(tint)
                    .frame(width: 4, height: max(4, levels[i] * 44))
            }
        }
        .animation(.linear(duration: 0.06), value: levels)
        .accessibilityHidden(true)
    }
}
