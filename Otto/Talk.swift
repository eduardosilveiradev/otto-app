import ActivityKit
import AppIntents
import AVFoundation
import SwiftUI
import VoiceRingKit

/// Opens talk mode from anywhere: the header's phone button (a tap once Talk is the pick, or its menu), the
/// "Talk with Otto" App Shortcut on the Action Button, the Lock Screen widget and the Control Center control.
@MainActor @Observable
final class TalkLauncher {
    static let shared = TalkLauncher()
    #if DEBUG
    // `-talk`: open straight into it, for screenshots.
    var open = ProcessInfo.processInfo.arguments.contains("-talk")
    #else
    var open = false
    #endif
}

/// Still named for the walkie-talkie it replaced: Shortcuts and the Action Button hold an intent by its type,
/// so a rename would unbind them. Only what people read changed.
struct OpenWalkie: AppIntent {
    static let title: LocalizedStringResource = "Talk with Otto"
    static let description = IntentDescription("Talk hands-free. Otto answers out loud, and you can cut in.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Doors.open("walkie")   // through the door that brings Otto's thread up first: talk's cover lives there, not on the drawer
        return .result()
    }
}

// MARK: - Turn-taking

/// Where your turns start and end, from the microphone's loudness alone, on the phone: a voice that holds
/// starts a turn, a pause ends it. Biased to miss rather than fire, since every turn it sends is a voice note
/// in the thread that Otto answers.
struct TurnDetector {
    // The knobs. Measured nowhere but the simulator and a quiet room: tune them on a phone.
    /// Seconds of voice before a turn starts.
    static let startAfter = 0.15
    /// Seconds of voice over Otto before it stops: longer, since some of its own voice leaks past the echo cancelling.
    static let cutInAfter = 0.35
    /// Seconds of quiet that end your turn.
    static let endAfter = 0.8
    /// Seconds of voice a turn needs to be sent at all: a cough or a door is dropped.
    static let minVoiced = 0.4
    /// A turn this long is sent as it stands, so a radio left on can't hold the microphone forever.
    static let maxTurn = 60.0
    /// Voice is this many times the room's own level, and never quieter than `quietest`.
    static let ratio: Float = 3
    static let quietest: Float = 0.008

    enum Event: Equatable { case start, end(send: Bool) }

    /// The room's level when nobody talks: falls quickly to quiet, rises slowly, so a steady fan becomes the floor.
    private(set) var floor: Float = 0.004
    private(set) var inTurn = false
    private var voiceRun = 0.0, quietRun = 0.0, voiced = 0.0, length = 0.0

    mutating func step(level: Float, dt: Double, ottoSpeaking: Bool) -> Event? {
        let loud = level > max(floor * Self.ratio, Self.quietest)
        floor += (level - floor) * (level < floor ? 0.2 : 0.004)
        guard inTurn else {
            voiceRun = loud ? voiceRun + dt : 0
            guard voiceRun >= (ottoSpeaking ? Self.cutInAfter : Self.startAfter) else { return nil }
            inTurn = true
            voiced = voiceRun; length = voiceRun; quietRun = 0
            return .start
        }
        length += dt
        if loud { voiced += dt; quietRun = 0 } else { quietRun += dt }
        guard quietRun >= Self.endAfter || length >= Self.maxTurn else { return nil }
        return close()
    }

    /// Ends the turn now (muted, paused, the route changed): sent if there was enough of it.
    mutating func close() -> Event? {
        guard inTurn else { return nil }
        inTurn = false
        voiceRun = 0
        return .end(send: voiced >= Self.minVoiced)
    }
}

/// The microphone's side of a talk, fed from the audio engine's thread: how loud you and Otto are, the last
/// moments before a turn (so it keeps its first syllable), and the open turn's file.
final class TalkMic: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    private var mic: Float = 0, otto: Float = 0
    /// A level to report instead of the microphone's (DEBUG's fake mic).
    private var override: Float?

    var level: Float { lock.withLock { override ?? mic } }
    var playing: Float { lock.withLock { otto } }
    func fake(_ level: Float?) { lock.withLock { override = level } }

    func heard(_ b: AVAudioPCMBuffer) {
        let rms = Self.rms(b)
        let copy = Self.mono(b)
        lock.withLock {
            mic = rms
            guard let copy else { return }
            if let file { try? file.write(from: copy); return }
            preroll.append(copy); prerollFrames += copy.frameLength
            // About 0.4 s kept: the voice that started the turn was already under way when it was recognised as one.
            while prerollFrames > AVAudioFrameCount(b.format.sampleRate * 0.4), preroll.count > 1 {
                prerollFrames -= preroll.removeFirst().frameLength
            }
        }
    }

    func played(_ b: AVAudioPCMBuffer) { let rms = Self.rms(b); lock.withLock { otto = rms } }

    /// Opens a turn's file: AAC, mono, at the microphone's rate (the Mac's transcriber takes it as it takes a voice note).
    func begin(_ url: URL, format: AVAudioFormat) throws {
        let f = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            for b in preroll { try? f.write(from: b) }
            preroll = []; prerollFrames = 0
            file = f
        }
    }

    /// Closes the turn's file, if one is open.
    @discardableResult func end() -> Bool {
        lock.withLock {
            defer { file?.close(); file = nil; mic = 0; otto = 0 }
            return file != nil
        }
    }

    private static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let d = b.floatChannelData, b.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(b.frameLength) { sum += d[0][i] * d[0][i] }
        return (sum / Float(b.frameLength)).squareRoot()
    }

    /// The first channel, copied: the engine reuses its buffers, and the voice-processing input can carry more
    /// channels than a voice note needs (the simulator's did, and the AAC writer refused them).
    private static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let f = AVAudioFormat(standardFormatWithSampleRate: b.format.sampleRate, channels: 1),
              let c = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength),
              let from = b.floatChannelData, let to = c.floatChannelData else { return nil }
        c.frameLength = b.frameLength
        to[0].update(from: from[0], count: Int(b.frameLength))
        return c
    }
}

// MARK: - The session

/// A hands-free talk with Otto. It listens all the time; a pause ends your turn, which goes up as a voice note
/// exactly as the walkie-talkie sent one; whatever Otto says back is said out loud (its own voice when the reply
/// has one, the phone's voice otherwise); talking over Otto stops it and starts your turn. The microphone and
/// Otto's voice run through one engine with the phone's echo cancelling on, so Otto doesn't hear itself.
@MainActor @Observable
final class TalkSession {
    /// The talk under way, for its Live Activity's buttons.
    static weak var current: TalkSession?
    /// While a talk holds the microphone: the background keepalive and Otto's reply banners stand aside.
    nonisolated(unsafe) static var active = false

    enum Mic: Equatable { case starting, on, denied, failed, paused }
    enum Phase: Equatable { case starting, noMic, failed, paused, hearing, speaking, waiting, thinking, working, listening }

    /// Something said in this talk, and when (seconds in). Otto's carry how much of it was said before you cut in.
    struct Line: Identifiable, Equatable {
        let id: Message.ID
        let at: TimeInterval
        let otto: Bool
        var cut: Double?
    }
    struct Step: Equatable { let at: TimeInterval; let text: String }

    private(set) var mic = Mic.starting
    var muted = false { didSet { if muted { closeTurn(send: true) } } }
    private(set) var started = Date.now
    private(set) var ended = false
    private(set) var endedAt: Date?
    /// Your turn is being recorded.
    private(set) var hearing = false
    /// The last thing Otto said was cut off by you.
    private(set) var cutIn = false
    /// What Otto is saying out loud now, and how far through it (0–1).
    private(set) var saying: Message.ID?
    private(set) var said: Double = 0
    /// A note went up and nothing has come back yet.
    private(set) var awaiting = false
    private(set) var lines: [Line] = []
    /// Otto's steps on what you last asked, as its status line changed.
    private(set) var steps: [Step] = []

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player = AVAudioPlayerNode()
    @ObservationIgnored private var format: AVAudioFormat?
    /// Read by the ring every frame, off observation.
    @ObservationIgnored let tap = TalkMic()
    @ObservationIgnored private var detector = TurnDetector()
    @ObservationIgnored private var turn: URL?
    @ObservationIgnored private var playing: (frames: Double, gen: Int)?
    /// Bumped whenever Otto's voice is stopped or replaced, so a late callback from the last one is ignored.
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let aloud = Aloud()
    /// When talk first saw each of Otto's messages, for how long a clip has been waited for.
    @ObservationIgnored private var seen: [Message.ID: Date] = [:]
    /// Messages there before the talk, and Otto's ones already said or skipped: none of these is said again.
    @ObservationIgnored private var heard: Set<Message.ID> = []
    @ObservationIgnored private var asked = Date.now
    @ObservationIgnored private var lastStatus: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var activity: Activity<TalkActivityAttributes>?
    @ObservationIgnored private var shown: TalkActivityAttributes.ContentState?
    @ObservationIgnored private var tried = Date.distantPast
    /// When the engine last stopped under the talk, and whether it now runs without voice processing because of them.
    @ObservationIgnored private var stops: [Date] = []
    @ObservationIgnored private var plain = false
    #if DEBUG
    @ObservationIgnored var fixtureTexts: [Message.ID: String] = [:]
    @ObservationIgnored private var firstSpoke: Date?
    #endif

    private var store: OttoStore { .shared }

    var phase: Phase {
        switch mic {
        case .starting: return .starting
        case .denied: return .noMic
        case .failed: return .failed
        case .paused: return .paused
        case .on: break
        }
        if hearing { return .hearing }
        if saying != nil { return .speaking }
        if !store.approvals.isEmpty { return .waiting }
        if awaiting || store.ottoTyping { return steps.isEmpty ? .thinking : .working }
        return .listening
    }

    /// A message's words: your turns fill in once the Mac has transcribed them.
    func text(_ id: Message.ID) -> String {
        #if DEBUG
        if let t = fixtureTexts[id] { return t }
        #endif
        return store.messages.last { $0.id == id }?.text ?? ""
    }

    /// Your last turn didn't reach the Mac.
    var undelivered: Message.ID? {
        guard awaiting, let you = lines.last(where: { !$0.otto }) else { return nil }
        return store.messages.last { $0.id == you.id }?.failed == true ? you.id : nil
    }

    // MARK: Start and end

    func start() async {
        Self.current = self
        Self.active = true
        ended = false; endedAt = nil; started = .now; asked = .now; tried = .distantPast; stops = []; plain = false
        lines = []; steps = []; cutIn = false; awaiting = false; saying = nil; said = 0
        heard = Set(store.messages.map(\.id)); seen = [:]
        AudioPlayer.shared.stop()   // a voice note playing in the thread
        UIApplication.shared.isIdleTimerDisabled = true
        #if DEBUG
        if let state = Self.fixtureState { return fixture(state) }
        #endif
        observe()
        await openMic()
        show()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func end() {
        guard !ended else { return }
        ended = true; endedAt = .now
        loop?.cancel(); loop = nil
        _ = detector.close()
        hearing = false
        if let turn { tap.end(); try? FileManager.default.removeItem(at: turn) }   // ended mid-sentence: dropped, not sent
        turn = nil
        stopVoice()
        closeEngine()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Self.active = false
        UIApplication.shared.isIdleTimerDisabled = false
        Keepalive.update(background: UIApplication.shared.applicationState == .background)
        if let a = activity { activity = nil; shown = nil; Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Back after a phone call or Siri, or the microphone's Try again.
    func resume() async {
        guard !ended else { return }
        await openMic()
        show()
    }

    // MARK: The engine

    private func openMic() async {
        mic = .starting
        guard await AVAudioApplication.requestRecordPermission() else { mic = .denied; return }
        guard !ended else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            // voiceChat: the phone's echo cancelling and voice levelling, as a FaceTime call has. HFP so AirPods' mics work.
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try s.setActive(true)
            let e = AVAudioEngine()
            // On before the format is read: it changes the input's format. A phone that refuses it talks without it.
            if !plain { try? e.inputNode.setVoiceProcessingEnabled(true) }
            player = AVAudioPlayerNode()
            e.attach(player)
            e.connect(player, to: e.mainMixerNode, format: nil)
            engine = e
            try tapAndStart(e)
            detector = TurnDetector()
            mic = .on
        } catch {
            closeEngine()
            mic = .failed
        }
    }

    /// Taps the input at its format now (a route change changes it) and starts the engine.
    private func tapAndStart(_ e: AVAudioEngine) throws {
        e.inputNode.removeTap(onBus: 0)
        e.mainMixerNode.removeTap(onBus: 0)
        let f = e.inputNode.outputFormat(forBus: 0)
        guard f.sampleRate > 0, f.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: f, block: Self.feed(tap))
        e.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.meter(tap))
        e.prepare()
        try e.start()
        format = f
    }

    /// The engine stopped under the talk (AirPods in or out): the same engine again, at the input's new format. What
    /// you were saying goes, and Otto stops. Voice processing can keep stopping it (the simulator's does, every few
    /// hundred milliseconds), which would close every turn unsent: after a fourth stop in five seconds the talk goes
    /// on without it.
    private func restart() {
        guard let e = engine else { return }
        closeTurn(send: true)
        if saying != nil { cut() }
        stops = stops.filter { Date.now.timeIntervalSince($0) < 5 } + [.now]
        #if DEBUG
        NSLog("talk: engine stopped (%d in 5 s)", stops.count)
        #endif
        if stops.count > 3 && !plain {
            plain = true
            closeEngine()
            Task { await openMic() }
            return
        }
        do { try tapAndStart(e) } catch { closeEngine(); mic = .failed }
    }

    // Made outside the main actor: the engine calls these on its own thread.
    private nonisolated static func feed(_ tap: TalkMic) -> AVAudioNodeTapBlock { { b, _ in tap.heard(b) } }
    private nonisolated static func meter(_ tap: TalkMic) -> AVAudioNodeTapBlock { { b, _ in tap.played(b) } }

    private func closeEngine() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.mainMixerNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers = [
            // A phone call or Siri takes the microphone: what you were saying goes, Otto stops, and the talk waits.
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let options = AVAudioSession.InterruptionOptions(rawValue: n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                MainActor.assumeIsolated {
                    guard let self, !self.ended else { return }
                    if type == .began { self.pause() }
                    else if type == .ended, options.contains(.shouldResume), self.mic == .paused { Task { await self.resume() } }
                }
            },
            // AirPods in or out: the input's format changes under the engine, which stops. Built again on the new route.
            // One still running (voice processing settling in posts one too) is left alone, or it would rebuild forever.
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
                let changed = n.object as AnyObject?
                MainActor.assumeIsolated {
                    guard let self, !self.ended, self.mic == .on, let e = self.engine, changed === e, !e.isRunning else { return }
                    self.restart()
                }
            },
            // Headphones gone: Otto doesn't carry on out of the speaker, as music doesn't.
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                MainActor.assumeIsolated {
                    guard let self, reason == .oldDeviceUnavailable, self.saying != nil else { return }
                    self.cut()
                }
            },
        ]
    }

    /// Stops listening and speaking where they are. What you'd said by then still goes.
    private func pause() {
        closeTurn(send: true)
        if saying != nil { cut() }
        closeEngine()
        mic = .paused
        show()
    }

    // MARK: Every 50 ms

    private func tick() {
        guard !ended, mic == .on else { return show() }
        var level = muted ? 0 : tap.level
        #if DEBUG
        if let f = fakeMic() { tap.fake(muted ? 0 : f); level = muted ? 0 : f }
        #endif
        switch detector.step(level: level, dt: 0.05, ottoSpeaking: saying != nil) {
        case .start?: beginTurn()
        case .end(let send)?: finishTurn(send: send)
        case nil: break
        }
        if let p = playing, p.gen == gen, let t = player.lastRenderTime, let pt = player.playerTime(forNodeTime: t), p.frames > 0 {
            said = min(1, max(0, Double(pt.sampleTime) / p.frames))
        }
        if let s = store.ottoStatus, !s.isEmpty, s != lastStatus, awaiting || store.ottoTyping {
            lastStatus = s
            steps.append(Step(at: Date.now.timeIntervalSince(asked), text: s))
            if steps.count > 30 { steps.removeFirst() }
        }
        if saying == nil && !hearing { sayNext() }
        show()
    }

    private func beginTurn() {
        if saying != nil { cut() }
        guard let format else { return }
        let url = URL.temporaryDirectory.appending(path: "talk-\(UUID().uuidString).m4a")
        do { try tap.begin(url, format: format) } catch {
            // Nowhere to put what you say: said as a microphone that won't start (Try again builds it afresh).
            #if DEBUG
            NSLog("talk: no turn file for %@: %@", format.description, String(describing: error))
            #endif
            _ = detector.close()
            closeEngine()
            mic = .failed
            return
        }
        turn = url
        hearing = true
    }

    private func finishTurn(send: Bool) {
        hearing = false
        tap.end()
        guard let url = turn else { return }
        turn = nil
        guard send, let id = store.sendVoice(url) else { try? FileManager.default.removeItem(at: url); return }
        heard.insert(id)
        lines.append(Line(id: id, at: Date.now.timeIntervalSince(started), otto: false))
        awaiting = true
        asked = .now; steps = []; lastStatus = store.ottoStatus
    }

    private func closeTurn(send: Bool) {
        if case .end(let ok)? = detector.close() { finishTurn(send: send && ok) }
    }

    /// The note again, as the thread's own retry does: no second copy.
    func retry() {
        guard let id = undelivered else { return }
        store.retry(id)
    }

    // MARK: Otto's voice

    /// How long a reply's own voice is waited for before its words go out in the phone's voice. The Mac sends a
    /// reply's text first and its clip after; with its speech slow or off the clip is late or never comes, and
    /// the store only gives up on it after 90 s, far too long to sit silent in a conversation.
    static let clipWait: TimeInterval = 3

    enum Say: Equatable { case clip, text, wait, skip }

    /// What talk does with an Otto message that came in during it: play its clip, say its words, wait a moment
    /// for its clip, or leave it to the thread. `waited`: seconds since the talk first saw it.
    nonisolated static func say(_ m: Message, waited: TimeInterval) -> Say {
        guard isReply(m), m.patch == nil else { return .skip }
        if m.audio != nil { return .clip }
        if m.isVoice && waited < clipWait { return .wait }
        return m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .skip : .text
    }

    /// Otto answering you, as against news it sends anyway (a reminder, the brief, a job: those carry a `src`).
    /// A reply the Mac couldn't pin to your turn still comes as `src: "chat"`, and is still an answer.
    nonisolated static func isReply(_ m: Message) -> Bool { m.from == .otto && (m.src == nil || m.src == "chat") }

    /// Otto's next new message, said out loud, in the order they came.
    private func sayNext() {
        let since = started.addingTimeInterval(-30)   // history caught up after a reconnect is old news
        let now = Date.now
        for m in store.messages where m.from == .otto && !heard.contains(m.id) && m.date >= since {
            let first = seen[m.id] ?? now
            seen[m.id] = first
            switch Self.say(m, waited: now.timeIntervalSince(first)) {
            case .skip: heard.insert(m.id)
            case .wait: return   // what Otto said after it waits behind it
            case .clip: heard.insert(m.id); awaiting = false; return sayClip(m, m.audio!)
            case .text: heard.insert(m.id); awaiting = false; return sayText(m)
            }
        }
    }

    private func sayClip(_ m: Message, _ clip: RemoteFile) {
        let g = begin(m)
        Task {
            let data = try? await store.backend.file(clip.id)
            guard g == gen else { return }
            let ext = (clip.name as NSString).pathExtension
            let url = URL.temporaryDirectory.appending(path: "talk-reply-\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
            guard let data, (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url), let engine else {
                // The clip couldn't be had: its words, in the phone's voice.
                return m.text.isEmpty ? done(g) : sayText(m)
            }
            player.stop()
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: Self.finished { [weak self] in self?.done(g) })
            play(frames: Double(file.length), gen: g)
        }
    }

    /// A reply with no voice of its own: the phone's voice, rendered first so it plays through the same engine
    /// (and its echo cancelling) as everything else Otto says.
    private func sayText(_ m: Message) {
        let g = saying == m.id ? gen : begin(m)
        let box = Rendered()
        synth.write(AVSpeechUtterance(string: m.text), toBufferCallback: Self.collect(box) { [weak self] in self?.playRendered(box.buffers, m, gen: g) })
        // Nothing rendered in 3 s: the phone's voice straight out instead, so the reply is never left unsaid.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, g == self.gen, self.saying == m.id, self.playing == nil, box.isEmpty else { return }
            self.synth.stopSpeaking(at: .immediate)
            self.sayAloud(m)
        }
    }

    private func playRendered(_ buffers: [AVAudioPCMBuffer], _ m: Message, gen g: Int) {
        guard g == gen else { return }
        guard let engine, let first = buffers.first,
              let f = AVAudioFormat(standardFormatWithSampleRate: first.format.sampleRate, channels: first.format.channelCount) else { return sayAloud(m) }
        let floats = buffers.compactMap { Self.float($0, f) }
        guard !floats.isEmpty else { return sayAloud(m) }
        player.stop()
        engine.connect(player, to: engine.mainMixerNode, format: f)
        for (i, b) in floats.enumerated() {
            player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack,
                                  completionHandler: i == floats.count - 1 ? Self.finished { [weak self] in self?.done(g) } : nil)
        }
        play(frames: floats.reduce(0) { $0 + Double($1.frameLength) }, gen: g)
    }

    /// The phone's voice spoken directly, for when rendering it gave nothing to play. It doesn't pass through the
    /// engine, so the echo cancelling may not take it out of the microphone; that beats a reply left unsaid.
    private func sayAloud(_ m: Message) {
        gen += 1
        let g = gen
        saying = m.id; playing = nil
        let n = Double(max(1, (m.text as NSString).length))
        aloud.heard = { [weak self] range, over in
            guard let self, g == self.gen else { return }
            if over { self.done(g) } else { self.said = Double(range.upperBound) / n }
        }
        aloud.synth.speak(AVSpeechUtterance(string: m.text))
    }

    private func begin(_ m: Message) -> Int {
        gen += 1
        saying = m.id; said = 0; cutIn = false
        lines.append(Line(id: m.id, at: Date.now.timeIntervalSince(started), otto: true))
        return gen
    }

    private func play(frames: Double, gen g: Int) {
        playing = (frames, g)
        if engine?.isRunning == false { try? engine?.start() }
        player.play()
        #if DEBUG
        if firstSpoke == nil { firstSpoke = .now }
        #endif
    }

    private func done(_ g: Int) {
        guard g == gen else { return }
        playing = nil; saying = nil; said = 1
    }

    /// You talked over Otto, or its route went: it stops mid-word, and what it had got through is kept with its line.
    private func cut() {
        guard let id = saying else { return }
        if let i = lines.lastIndex(where: { $0.id == id }) { lines[i].cut = said }
        stopVoice()
        cutIn = true
        // What Otto had queued after it is moot now that you've moved on: it stays in the thread, unsaid.
        for m in store.messages where m.from == .otto { heard.insert(m.id) }
    }

    private func stopVoice() {
        gen += 1
        player.stop()
        synth.stopSpeaking(at: .immediate)
        aloud.synth.stopSpeaking(at: .immediate)
        playing = nil; saying = nil
    }

    private nonisolated static func finished(_ then: @escaping @MainActor () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in Task { @MainActor in then() } }
    }

    /// The phone's voice as it renders, filled on the synthesizer's thread.
    final class Rendered: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [AVAudioPCMBuffer] = []
        var buffers: [AVAudioPCMBuffer] { lock.withLock { all } }
        var isEmpty: Bool { lock.withLock { all.isEmpty } }
        func add(_ b: AVAudioPCMBuffer) { lock.withLock { all.append(b) } }
    }

    /// The phone's voice spoken straight out, telling talk how far it has got and when it's done.
    final class Aloud: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        let synth = AVSpeechSynthesizer()
        var heard: (@MainActor (NSRange, Bool) -> Void)?
        override init() { super.init(); synth.delegate = self }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange, utterance: AVSpeechUtterance) {
            let f = heard; Task { @MainActor in f?(r, false) }
        }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            let f = heard; Task { @MainActor in f?(NSRange(), true) }
        }
    }

    private nonisolated static func collect(_ box: Rendered, then: @escaping @MainActor () -> Void) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { Task { @MainActor in then() }; return }
            box.add(pcm)
        }
    }

    /// The phone's voice comes as 16-bit samples on some voices; the mixer takes floats.
    private nonisolated static func float(_ b: AVAudioPCMBuffer, _ f: AVAudioFormat) -> AVAudioPCMBuffer? {
        if b.format == f { return b }
        guard let c = AVAudioConverter(from: b.format, to: f), let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: b.frameLength) else { return nil }
        return (try? c.convert(to: out, from: b)) != nil ? out : nil
    }

    // MARK: Outside the app

    /// The Lock Screen and the Dynamic Island: only local updates from the running app (its microphone keeps it
    /// running in the background), and only when what it says changes, never per word.
    private func show() {
        guard !ended else { return }
        let state = outside
        guard let a = activity else {
            // Only the app in front may start one. Opened from the Action Button or a widget, the talk can start before
            // the app is: it's asked again on every tick until it's up.
            guard UIApplication.shared.applicationState == .active, Date.now.timeIntervalSince(tried) > 2 else { return }
            tried = .now
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                #if DEBUG
                NSLog("talk: live activities are off for Otto")
                #endif
                return
            }
            do { activity = try Activity.request(attributes: TalkActivityAttributes(), content: .init(state: state, staleDate: nil)); shown = state } catch {
                #if DEBUG
                NSLog("talk: no live activity yet: %@", String(describing: error))
                #endif
            }
            return
        }
        guard state != shown else { return }
        shown = state
        Task { await a.update(.init(state: state, staleDate: nil)) }
    }

    private var outside: TalkActivityAttributes.ContentState {
        let otto = lines.last(where: \.otto).map { text($0.id) } ?? ""
        let you = lines.last(where: { !$0.otto }).map { text($0.id) } ?? ""
        let (title, line, symbol): (String, String, String) = switch phase {
        case .starting: ("Starting", "", "ellipsis")
        case .noMic: ("Otto can’t hear you", "Turn on Microphone for Otto in Settings.", "mic.slash")
        case .failed: ("Microphone off", "Open Otto to try again.", "mic.slash")
        case .paused: ("Paused", "Open Otto to carry on.", "pause.fill")
        case .hearing: ("Hearing you", "", "waveform")
        case .speaking: ("Otto", otto, "speaker.wave.2.fill")
        case .waiting: ("Waiting for you", "Approve it in Otto.", "hand.raised.fill")
        case .thinking: ("Thinking", you, "ellipsis")
        case .working: ("Working", steps.last?.text ?? "", "ellipsis")
        case .listening: ("Listening", otto, "waveform")
        }
        let mute = muted && mic == .on
        return .init(title: mute && phase == .listening ? "Muted" : title, line: line, symbol: mute ? "mic.slash" : symbol, started: started, muted: muted)
    }

    // MARK: DEBUG

    #if DEBUG
    /// `-talkState <name>`: a talk frozen in one state, for screenshots (no microphone, no engine).
    static let fixtureState: String? = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-talkState").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
    }()

    private func fixture(_ state: String) {
        started = .now.addingTimeInterval(-84)
        func say(_ otto: Bool, _ at: TimeInterval, _ text: String, cut: Double? = nil) -> Message.ID {
            let id = UUID(); fixtureTexts[id] = text
            lines.append(Line(id: id, at: at, otto: otto, cut: cut)); return id
        }
        mic = .on
        let ask = say(false, 2, "Find me a train to Turin on Saturday, something before nine.")
        _ = ask
        let offer = "There’s a 7:52 from Milano Centrale that gets you in at 8:55, and an 8:10 that’s cheaper but slower. Want the 7:52?"
        switch state {
        case "listening": lines = []
        case "hearing": lines = []; hearing = true
        case "thinking": awaiting = true
        case "speaking": saying = say(true, 6, offer); said = 0.48
        case "cutin":
            _ = say(true, 6, offer, cut: 0.42)
            hearing = true; cutIn = true
        case "working":
            _ = say(true, 6, offer, cut: 0.42)
            _ = say(false, 11, "The 7:52, window seat please.")
            _ = say(true, 13, "Booking the 7:52. I’ll grab a window seat.")
            awaiting = true
            steps = [Step(at: 3, text: "Searched Milano Centrale to Torino Porta Nuova, Saturday 7–9"),
                     Step(at: 7, text: "Picked the 7:52, arriving 8:55"),
                     Step(at: 9, text: "Choosing a window seat in coach 6")]
        case "mic": lines = []; mic = .denied
        case "paused": mic = .paused
        case "failed": lines = []; mic = .failed
        case "muted": lines = []; muted = true
        case "ended":
            _ = say(true, 6, "There’s a 7:52 from Milano Centrale that gets you in at 8:55, and an 8:10 that’s cheaper but slower. Want the 7:52?", cut: 0.42)
            _ = say(false, 11, "The 7:52, window seat please.")
            _ = say(true, 13, "Booking the 7:52. I’ll grab a window seat.")
            _ = say(true, 31, "It’s €24.90 for seat 14A. I won’t buy it until you approve on your iPhone.")
            _ = say(false, 44, "Yes, go ahead.")
            _ = say(true, 58, "Booked. Coach 6, seat 14A. The ticket is in your email.")
            started = .now.addingTimeInterval(-151)
            ended = true; endedAt = .now
            Self.active = false
        case "long":
            // Worst case: a long reply mid-sentence, and a long run of steps.
            saying = say(true, 6, String(repeating: "There’s a 7:52 from Milano Centrale that gets you in at 8:55, and an 8:10 that’s cheaper but slower. ", count: 4) + "Want the 7:52?")
            said = 0.7
        default: break
        }
        show()
    }

    /// `-talkFakeMic`: a voice where the simulator has none. You talk from 1 s to 3.5 s (a turn that's sent), then
    /// talk over Otto 1.2 s into its first answer for 1.6 s (a cut-in, sent as a second turn).
    private func fakeMic() -> Float? {
        guard ProcessInfo.processInfo.arguments.contains("-talkFakeMic") else { return nil }
        let t = Date.now.timeIntervalSince(started)
        if t > 1 && t < 3.5 { return 0.08 }
        if let s = firstSpoke { let u = Date.now.timeIntervalSince(s); if u > 1.2 && u < 2.8 { return 0.08 } }
        return 0.002
    }
    #endif
}

// MARK: - The screen

/// Talk with Otto, full screen: the ring in the middle, what's being said under it (Otto's words lighting up
/// as it says them), and while Otto works, its steps and the page it has open. Leaving the app keeps the talk
/// going in the Dynamic Island.
struct TalkView: View {
    @Environment(OttoStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// Reduce Motion: the ring holds still on its own (VoiceRingKit reads it); here, changes cross-fade instead of moving.
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var session = TalkSession()

    var body: some View {
        Group {
            if session.ended { TalkTranscript(session: session, again: { Task { await session.start() } }, done: { dismiss() }) }
            else { live }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task { await session.start() }
        .onDisappear { session.end() }
        // Ended with nothing said: there's no transcript to show, so it just closes.
        .onChange(of: session.ended) { _, over in if over && session.lines.isEmpty { dismiss() } }
        .sensoryFeedback(.impact(weight: .light), trigger: session.hearing) { _, now in now }   // felt as your turn starts
        .sensoryFeedback(.error, trigger: session.undelivered) { _, now in now != nil }
    }

    private var phase: TalkSession.Phase { session.phase }
    private var working: Bool { phase == .working }

    private var live: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Otto").font(size: 17, weight: .semibold, relativeTo: .headline)
                Text(session.started, style: .timer).font(size: 17, relativeTo: .headline).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 12)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)
            VStack(spacing: 0) {
                ring
                words
                if working { work }
            }
            .animation(still ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0), value: working)
            Spacer(minLength: 12)

            controls.padding(.bottom, 16)
        }
        // Past the first accessibility size the working state (steps and the page) no longer fits one screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: The ring

    private var ring: some View {
        let (state, otto): (VoiceState, Bool) = switch phase {
        case .hearing, .listening: (.listening, false)
        case .speaking: (.speaking, true)
        case .thinking, .working, .starting: (.processing, false)
        default: (.idle, false)
        }
        let tap = session.tap, muted = session.muted, size: CGFloat = working ? 120 : 220
        return VoiceRing(.mono, state: state, source: .level { muted ? 0 : Double(min(1, (otto ? tap.playing : tap.level) * 8)) },
                         style: { var s = VoiceStyle(); s.theme = .dark; return s }(), size: size)
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore).accessibilityHidden(true)   // the caption under it says the same in words
    }

    // MARK: The words

    @ViewBuilder private var words: some View {
        VStack(spacing: 10) {
            switch phase {
            case .noMic:
                problem("Otto can’t hear you", "Turn on Microphone for Otto in Settings, then come back.") {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    Button("Type instead") { dismiss() }.tint(.actionInk).frame(minHeight: 44)
                }
            case .failed:
                problem("Couldn’t start the microphone", "Something else may be using it.") {
                    Button("Try again") { Task { await session.resume() } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                }
            case .paused:
                problem("Paused", "A call or Siri needed the microphone.") {
                    Button("Carry on") { Task { await session.resume() } }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                }
            default:
                Text(label).font(size: 15, relativeTo: .subheadline).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: label)
                said
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.top, working ? 12 : 28)
        .frame(maxWidth: 520)
    }

    private var label: String {
        if store.asleep && !store.noNetwork && phase == .listening { return "Can’t reach your Mac" }
        if store.noNetwork && phase == .listening { return "No connection" }
        if session.muted && (phase == .listening || phase == .thinking) { return "Muted" }
        return switch phase {
        case .starting: "Starting"
        case .hearing: session.cutIn ? "You cut in, so Otto stopped" : "Hearing you"
        case .speaking: "Otto · talk to cut in"
        case .waiting: "Waiting for you"
        case .thinking: "Thinking"
        case .working: "Working · talk any time"
        default: "Listening"
        }
    }

    @ViewBuilder private var said: some View {
        let big = Font.Weight.regular
        switch phase {
        case .speaking:
            if let id = session.saying { Lit(text: session.text(id), fraction: session.said).font(size: 20, weight: big, relativeTo: .title3) }
        case .hearing:
            if session.cutIn, let cut = session.lines.last(where: \.otto) {
                Text(Lit.head(session.text(cut.id), cut.cut ?? 0) + "—")
                    .font(size: 16, relativeTo: .callout).foregroundStyle(.secondary).lineLimit(3)
            } else {
                Text("Otto answers when you pause.").font(size: 20, relativeTo: .title3).foregroundStyle(.secondary)
            }
        case .thinking:
            if let id = session.undelivered {
                Button { session.retry() } label: {
                    Text("\(Text("Not delivered · ").foregroundStyle(Color.redInk))\(Text("Try again").foregroundStyle(Color.actionInk))")
                        .font(size: 17, relativeTo: .body).frame(minHeight: 44)
                }
                .buttonStyle(.press)
                .id(id)
            } else if let you = session.lines.last(where: { !$0.otto }) {
                Text(session.text(you.id)).font(size: 20, relativeTo: .title3).lineLimit(5)
            }
        case .working:
            // Otto's answer to what you last said; until it has one, what you said (its last line answered something older).
            if let line = session.lines.last, !session.text(line.id).isEmpty {
                Text(session.text(line.id)).font(size: 20, weight: line.otto ? .semibold : .regular, relativeTo: .title3).lineLimit(4)
            }
        case .waiting:
            Text("Otto needs your OK. Approve it on this iPhone, not by voice.").font(size: 20, relativeTo: .title3).foregroundStyle(.secondary)
        default:
            if store.asleep {
                Text("What you say waits here and goes when your Mac is back.").font(size: 20, relativeTo: .title3).foregroundStyle(.secondary)
            } else if session.muted {
                Text("Otto can’t hear you. Unmute to talk.").font(size: 20, relativeTo: .title3).foregroundStyle(.secondary)
            } else if let otto = session.lines.last(where: \.otto) {
                Text(session.text(otto.id)).font(size: 20, relativeTo: .title3).lineLimit(5)
            } else {
                Text("Talk whenever you like. Talk over Otto to cut in.").font(size: 20, relativeTo: .title3).foregroundStyle(.secondary)
            }
        }
    }

    private func problem(_ title: String, _ detail: String, @ViewBuilder actions: () -> some View) -> some View {
        VStack(spacing: 10) {
            Text(title).font(size: 22, weight: .semibold, relativeTo: .title2)
            Text(detail).font(size: 17, relativeTo: .body).foregroundStyle(.secondary)
            VStack(spacing: 8) { actions() }.padding(.top, 14)
        }
    }

    // MARK: While Otto works

    private var work: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.steps.suffix(4).enumerated()), id: \.offset) { i, step in
                    let newest = i == min(session.steps.count, 4) - 1
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Duration.seconds(step.at).formatted(.time(pattern: .minuteSecond)))
                            .font(size: 13, relativeTo: .footnote).monospacedDigit().foregroundStyle(.secondary)
                        Text(step.text).font(size: 15, relativeTo: .subheadline)
                            .foregroundStyle(newest ? .primary : .secondary).lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let b = store.browser { BrowserTileView(browser: b, full: true) }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .transition(.opacity)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 56) {
            let on = session.mic == .on
            TalkButton(symbol: session.muted ? "mic.slash.fill" : "mic.fill",
                       label: on ? (session.muted ? "Unmute" : "Mute") : "Mic off",
                       fill: session.muted ? .white : .white.opacity(0.16), tint: session.muted ? .black : .white) {
                session.muted.toggle()
            }
            .disabled(!on)
            .accessibilityAddTraits(session.muted ? .isSelected : [])
            TalkButton(symbol: "xmark", label: "End", fill: .red, tint: .white) { session.end() }
        }
    }
}

/// A round control with its name under it, as the Phone app draws them.
private struct TalkButton: View {
    let symbol: String
    let label: String
    let fill: Color
    let tint: Color
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                    .frame(width: 64, height: 64)
                    .background(fill, in: .circle)
                    .foregroundStyle(tint)
                Text(label).font(size: 13, relativeTo: .footnote).foregroundStyle(.white.opacity(enabled ? 0.7 : 0.35))
            }
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }
}

/// Otto's words, lit up to where its voice has got: what's been said in full white, the rest dimmed.
private struct Lit: View {
    let text: String
    let fraction: Double
    var body: some View {
        let head = Self.head(text, fraction)
        // A long answer shows from the sentence being said, so the lit words never run past the last line shown.
        let from = Self.sentenceStart(head)
        let said = (from == head.startIndex ? "" : "…") + head[from...]
        // Half white for what's still to come: dimmer than the said part at a glance, and still 5:1 on black to read.
        Text("\(Text(said))\(Text(text.dropFirst(head.count)).foregroundStyle(.white.opacity(0.5)))")
            .lineLimit(6)
            .accessibilityLabel(text)
    }

    /// Where the sentence `head` ends in starts, once `head` is long enough to push it out of six lines; else the start.
    private static func sentenceStart(_ head: String) -> String.Index {
        guard head.count > 200 else { return head.startIndex }
        let stops = head.indices.filter { i in ".?!".contains(head[i]) && head.index(after: i) < head.endIndex && head[head.index(after: i)] == " " }
        return stops.last.map { head.index($0, offsetBy: 2) } ?? head.startIndex
    }

    /// The text up to `fraction` of the way through, ending on a whole word.
    // ponytail: spoken position read off the share of audio played, so a pause in the voice runs a word or two
    // ahead; AVSpeechSynthesizer's markers would give exact words for the phone's voice, the Mac's clips have none.
    static func head(_ text: String, _ fraction: Double) -> String {
        guard fraction < 1 else { return text }
        var i = text.index(text.startIndex, offsetBy: Int(Double(text.count) * max(0, fraction)))
        while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
        return String(text[..<i])
    }
}

/// After the talk: what was said, line by line, with where you cut Otto off.
private struct TalkTranscript: View {
    let session: TalkSession
    let again: () -> Void
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Talk with Otto").font(size: 28, weight: .bold, relativeTo: .largeTitle)
                    Text("\(length) · \(session.started.formatted(date: .omitted, time: .shortened))")
                        .font(size: 15, relativeTo: .subheadline).foregroundStyle(.secondary)
                }
                ForEach(session.lines) { line in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Duration.seconds(line.at).formatted(.time(pattern: .minuteSecond))) · \(line.otto ? "Otto" : "You")")
                            .font(size: 13, relativeTo: .footnote).monospacedDigit().foregroundStyle(.secondary)
                        let words = session.text(line.id)
                        Text(line.cut.map { Lit.head(words, $0) + "—" } ?? (words.isEmpty ? "Voice note" : words))
                            .font(size: 17, relativeTo: .body).textSelection(.enabled)
                        if line.cut != nil {
                            Text("Stopped when you cut in").font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button(action: again) { Text("Talk again").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.bordered).tint(.white)
                Button(action: done) { Text("Done").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule).controlSize(.large)
            .font(size: 17, weight: .semibold, relativeTo: .body)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: 640)
            .background(Color.black)
        }
    }

    private var length: String {
        let s = max(1, Int((session.endedAt ?? .now).timeIntervalSince(session.started).rounded()))
        return "Talked for " + Duration.seconds(s).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}
