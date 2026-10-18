import AVFoundation
import SwiftUI

// Calls Otto places for you (callbot on the Mac), live: the transcript as it is
// spoken, the call's audio, and a hand on it — say a line, give the bot an
// instruction, end it, or have it transferred to your phone. All of it comes
// from the dashboard API's /app/dash/calls routes with the app's own token.
// A Mac without callbot answers those with an error, and then none of this shows.

// MARK: - Wire types (otto/dash-types.ts)

struct DashCall: Decodable, Identifiable, Equatable {
    struct Line: Decodable, Equatable { let role: String; let text: String }
    let id: String; let to: String; let task: String; let status: String; let seq: Int
    let createdAt: Double; let startedAt: Double?; let endedAt: Double?; let endedReason: String?
    let lines: [Line]; let partial: [String: String]; let takeover: Bool

    var live: Bool { status != "ended" }
    var created: Date { Date(timeIntervalSince1970: createdAt / 1000) }
    var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    var ended: Date? { endedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// "Live", "Ringing", "Handed to you"…
    var statusLabel: String {
        switch status {
        case "in-progress": "Live"
        case "ringing": "Ringing"
        case "forwarding": "Transferring"
        case "ended": endedReason == "assistant-forwarded-call" ? "Handed to you" : "Ended"
        default: "Dialing"
        }
    }
    var statusTint: Color { status == "in-progress" ? .green : live ? .orange : .secondary }
}

struct DashCalls: Decodable { let calls: [DashCall] }
private struct ControlResult: Decodable { let ok: Bool; let error: String? }
private struct ListenTicket: Decodable { let url: String }

// MARK: - The call list, watched

/// Every call the Mac holds (live, or ended in the last two hours), re-read every
/// few seconds while the chat is on screen. `live` drives the banner.
@MainActor @Observable
final class CallWatch {
    var calls: [DashCall] = []
    /// False once the Mac has answered with an error: no callbot there, so stop asking often.
    var available = true
    var live: DashCall? { calls.first(where: \.live) }

    func run(_ backend: OttoBackend) async {
        while !Task.isCancelled {
            if let r: DashCalls = await backend.dash("calls") {
                calls = r.calls
                available = true
            } else {
                available = false
            }
            let wait: Duration = !available ? .seconds(60) : live != nil ? .seconds(3) : .seconds(8)
            try? await Task.sleep(for: wait)
        }
    }
}

// MARK: - The banner over the chat

/// A FaceTime-style pill under the header while Otto is on a call. Tap to open it.
struct CallBanner: View {
    let call: DashCall
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(call.statusTint, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Calling \(call.to)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(call.task).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                CallClock(call: call).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .tint(.primary)
        .padding(.horizontal, 16)
        .accessibilityLabel("Otto is on a call to \(call.to). Open it.")
    }
}

/// "1:23" since the call connected, or the status before it does.
struct CallClock: View {
    let call: DashCall
    var body: some View {
        if let start = call.started {
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                let s = Int((call.ended ?? tl.date).timeIntervalSince(start))
                Text(String(format: "%d:%02d", s / 60, s % 60))
            }
        } else {
            Text(call.statusLabel)
        }
    }
}

// MARK: - One call

/// The call itself: transcript, Listen, and the controls. Long-polls the Mac while it is live.
struct CallSheet: View {
    @State var call: DashCall
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var note: String?
    @State private var handedOff = false
    @State private var confirmEnd = false
    @State private var confirmTakeover = false
    @State private var listener = CallListener()

    private var canAct: Bool { call.live && !handedOff }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                if canAct { controls }
            }
            .navigationTitle(call.to)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(call.to).font(.headline).monospacedDigit()
                        HStack(spacing: 4) {
                            Circle().fill(call.statusTint).frame(width: 6, height: 6)
                            Text(call.statusLabel)
                            if call.started != nil { Text("·"); CallClock(call: call) }
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if call.live {
                        Button { Task { await listener.toggle(call: call.id, backend: store.backend) } } label: {
                            Image(systemName: listener.playing ? "speaker.wave.2.fill" : "headphones")
                        }
                        .accessibilityLabel(listener.playing ? "Stop listening" : "Listen")
                        .tint(listener.playing ? .accentColor : .primary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
        .task(id: call.live) { await follow() }
        .onChange(of: call.live) { if !call.live { listener.stop() } }
        .onDisappear { listener.stop() }
        .confirmationDialog("End the call?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Hang Up", role: .destructive) { Task { await send("end") } }
        }
        .confirmationDialog("Take over the call?", isPresented: $confirmTakeover, titleVisibility: .visible) {
            Button("Ring My Phone") { Task { await send("takeover") } }
        } message: { Text("Otto tells them to hold on and transfers the call to your number.") }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                Text(call.task)
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                let partial = ["user", "assistant"].compactMap { r in call.partial[r].map { DashCall.Line(role: r, text: $0) } }
                if call.lines.isEmpty && partial.isEmpty {
                    Text(call.live ? "Nobody has spoken yet." : "Nothing was said on this call.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(Array(call.lines.enumerated()), id: \.offset) { i, l in
                    CallBubble(line: l, first: i == 0 || call.lines[i - 1].role != l.role)
                }
                ForEach(partial, id: \.role) { l in
                    CallBubble(line: l, first: call.lines.last?.role != l.role, partial: true)
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
                Color.clear.frame(height: 1).id("end")
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Something to say on the call", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassEffect(.regular, in: .rect(cornerRadius: 20))
                Menu {
                    Button { Task { await say("say") } } label: { Label("Say it word for word", systemImage: "speaker.wave.2") }
                    Button { Task { await say("tell") } } label: { Label("Tell the bot", systemImage: "text.bubble") }
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(Color.blue, in: .circle)
                } primaryAction: { Task { await say("say") } }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                .accessibilityLabel("Say it. Hold for more.")
            }
            HStack(spacing: 10) {
                Button { confirmTakeover = true } label: {
                    Label("Take Over", systemImage: "phone.arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(!call.takeover)
                Button(role: .destructive) { confirmEnd = true } label: {
                    Label("End", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).tint(.red)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
        .background(.bar)
    }

    private func say(_ action: String) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if await send(action, text: text) { draft = "" }
    }

    @discardableResult
    private func send(_ action: String, text: String? = nil) async -> Bool {
        var body: [String: Any] = ["id": call.id, "action": action]
        if let text { body["text"] = text }
        guard let r: ControlResult = await store.backend.dash("calls/control", method: "POST", body: body) else {
            note = "Couldn't reach your Mac."
            return false
        }
        if r.ok {
            note = ["say": "Said on the call.", "tell": "Passed to the bot.", "end": "Hanging up.", "takeover": "Ringing your phone."][action]
            if action == "end" || action == "takeover" { handedOff = true; listener.stop() }
        } else {
            note = r.error ?? "Otto couldn't do that."
        }
        return r.ok
    }

    /// Waits on the Mac for each change while the call is live; a failed poll backs off.
    private func follow() async {
        var fails = 0
        while call.live && !Task.isCancelled {
            if let c: DashCall = await store.backend.dash("calls", query: ["id": call.id, "after": String(call.seq)]) {
                if c != call { withAnimation(.snappy) { call = c } }
                fails = 0
            } else {
                fails += 1
                try? await Task.sleep(for: .seconds(min(30, 1 << min(fails, 5))))
            }
        }
    }
}

private struct CallBubble: View {
    let line: DashCall.Line
    let first: Bool
    var partial = false
    /// Otto speaks for you, so its lines sit on your side.
    private var ours: Bool { line.role == "assistant" }

    var body: some View {
        VStack(alignment: ours ? .trailing : .leading, spacing: 2) {
            if first {
                Text(ours ? "Otto" : "Them").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
            }
            Text(line.text)
                .foregroundStyle(ours ? .white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(ours ? Color.blue : Color(.systemGray5), in: .rect(cornerRadius: 18))
                .opacity(partial ? 0.55 : 1)
                .frame(maxWidth: 300, alignment: ours ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: ours ? .trailing : .leading)
    }
}

// MARK: - The contact card's list

/// Calls in the last two hours, newest first.
struct CallsScreen: View {
    @Environment(OttoStore.self) private var store
    @State private var open: DashCall?

    var body: some View {
        Loaded(path: "calls") { (r: DashCalls, reload) in
            List {
                if r.calls.isEmpty {
                    Text("No calls in the last two hours. Ask Otto to call somewhere and it shows up here while it rings.")
                        .foregroundStyle(.secondary)
                }
                ForEach(r.calls) { c in
                    Button { open = c } label: {
                        HStack(spacing: 12) {
                            RowIcon(symbol: c.live ? "phone.fill" : "phone", tint: c.live ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.to).monospacedDigit()
                                Text(c.task).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Pill(text: c.statusLabel, tint: c.live ? c.statusTint : .secondary)
                                Text(ago(c.created)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Calls").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $open) { CallSheet(call: $0) }
    }
}

// MARK: - Listening

/// Plays a call's audio from a one-time socket the Mac hands out: raw 16-bit PCM
/// whose first text frame names the sample rate and channels (one side of the
/// call per channel). Both sides are mixed to mono into a player node.
@MainActor @Observable
final class CallListener {
    private(set) var playing = false
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var task: Task<Void, Never>?

    func toggle(call id: String, backend: OttoBackend) async {
        if playing { stop(); return }
        guard let t: ListenTicket = await backend.dash("calls/listen", method: "POST", body: ["id": id]),
              let url = URL(string: t.url) else { return }
        start(url)
    }

    private func start(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        playing = true
        task = Task { [weak self] in
            var rate = 16_000.0, channels = 2
            while let self, !Task.isCancelled {
                guard let msg = try? await socket.receive() else { break }
                switch msg {
                case .string(let s):
                    if let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                        rate = (j["sampleRate"] as? Double) ?? rate
                        channels = (j["channels"] as? Int) ?? channels
                    }
                case .data(let d):
                    self.play(d, rate: rate, channels: max(1, channels))
                @unknown default: break
                }
            }
            self?.stop()
        }
    }

    private func play(_ data: Data, rate: Double, channels: Int) {
        let frames = data.count / 2 / channels
        guard frames > 0, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        if engine == nil {
            let e = AVAudioEngine(), p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: format)
            try? e.start()
            p.play()
            engine = e; player = p
        }
        buf.frameLength = AVAudioFrameCount(frames)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let pcm = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += Float(Int16(littleEndian: pcm[i * channels + c])) }
                out[i] = s / Float(channels) / 32768
            }
        }
        player?.scheduleBuffer(buf)
    }

    func stop() {
        guard playing else { return }
        playing = false
        task?.cancel(); task = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        player?.stop(); engine?.stop()
        player = nil; engine = nil
    }
}
