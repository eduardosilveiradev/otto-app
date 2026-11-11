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
    /// The last note sent, offered again if it gets nowhere.
    @State private var note: Message.ID?
    /// A minute went by with no answer.
    @State private var gaveUp = false
    @State private var reply: Message?
    /// The reply already played or read out, so a later change doesn't start it again.
    @State private var heard: UUID?
    @State private var levels: [CGFloat] = Array(repeating: 0, count: 28)
    @State private var speech = AVSpeechSynthesizer()
    private var player: AudioPlayer { .shared }

    private enum Phase { case idle, listening, thinking, speaking }
    private var phase: Phase {
        if recorder.started != nil { return .listening }
        if let r = reply, let a = r.audio, player.playing == a.id { return .speaking }
        if speech.isSpeaking { return .speaking }
        if sentAt != nil && reply == nil && !stuck { return .thinking }
        return .idle
    }

    private var sent: Message? { note.flatMap { id in store.messages.last { $0.id == id } } }
    /// Going nowhere: the note didn't get through, or nothing came back in a minute.
    private var stuck: Bool { reply == nil && note != nil && (gaveUp || sent?.failed == true) }

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
                .font(size: 17, weight: .semibold, relativeTo: .headline)
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
            Group {
                if stuck {
                    // The thread's own words for an unsent message, and the same way on.
                    Button(action: retry) {
                        (Text(sent?.pending == true ? "Not delivered · " : "Otto didn't answer · ").foregroundStyle(.red)
                         + Text("Try again").foregroundStyle(.blue)).hitSlop()
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(reply.map { $0.text.isEmpty ? "…" : $0.text } ?? "Hold Otto and talk. Let go to send.")
                        .foregroundStyle(reply == nil ? .secondary : .primary)
                }
            }
            .font(size: 16, relativeTo: .callout)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(minHeight: 72, alignment: .top)
            .contentTransition(.opacity)
            .animation(.easeInOut, value: reply?.text)
            .animation(.easeInOut(duration: 0.2), value: stuck)   // cross-fades: nothing for Reduce Motion to stop
        }
        .background(Color(.systemBackground))
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            #if DEBUG
            // `-walkieNote` (with `-walkie`): a stand-in note goes out on open, as if held and let go,
            // to test what happens when no answer comes (a dead server, or one that never replies).
            if ProcessInfo.processInfo.arguments.contains("-walkieNote") {
                let url = URL.temporaryDirectory.appending(path: "walkie-note.m4a")
                try? Data(count: 1024).write(to: url)
                send(url)
            }
            #endif
        }
        // "Thinking" gives up after a minute, and the note is offered again.
        .task(id: sentAt) {
            guard sentAt != nil else { return }
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled && reply == nil { sentAt = nil; gaveUp = true }
        }
        #if DEBUG
        .task(id: stuck) {
            guard stuck, labTryAgain else { return }
            labTryAgain = false
            try? await Task.sleep(for: .seconds(3))
            retry()
        }
        #endif
        .onDisappear {
            _ = recorder.stop()
            player.stop(); speech.stopSpeaking(at: .immediate)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task { await meter() }
        .onChange(of: store.messages.last?.id) { pickUpReply() }
        .onChange(of: store.messages.last?.audio?.id) { pickUpReply() }
        .onChange(of: store.messages.last?.isVoice) { pickUpReply() }
        .sensoryFeedback(.impact(weight: .medium), trigger: holding)
        .sensoryFeedback(.success, trigger: reply?.id)
        .sensoryFeedback(.error, trigger: stuck) { _, now in now }   // eyes on the street: felt, not just shown
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
        send(url)
    }

    private func send(_ url: URL) {
        reply = nil
        gaveUp = false
        sentAt = .now
        note = store.sendVoice(url)
    }

    /// The same note while it's still unsent (the thread's retry, so no second copy); said again
    /// once it got there and nothing came back.
    private func retry() {
        guard let m = sent else { return }
        if m.pending == true {
            store.retry(m.id)
            gaveUp = false
            sentAt = .now
        } else {
            let copy = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
            guard (try? FileManager.default.copyItem(at: VoiceStore.url(m.id), to: copy)) != nil else { return }
            send(copy)
        }
    }

    /// The first thing Otto says after the note went up. Plays its voice when it has one;
    /// a text-only answer is read out on the phone so you never have to look.
    private func pickUpReply() {
        if let since = sentAt, let m = store.messages.last(where: { $0.from == .otto && $0.date >= since }) {
            sentAt = nil
            reply = m
        }
        guard let id = reply?.id, heard != id, let m = store.messages.first(where: { $0.id == id }) else { return }
        reply = m
        if let a = m.audio {
            heard = id
            Task { await player.toggle(a.id) { await store.backend.file(a.id) } }
        } else if !m.isVoice, !m.text.isEmpty {
            heard = id
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            speech.speak(AVSpeechUtterance(string: m.text))
        }
        // Otherwise its voice is still on the way: the text goes out first and the clip follows.
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
