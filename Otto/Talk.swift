import ActivityKit
import AppIntents
import AVFoundation
import CoreMotion
import ReplayKit
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
/// starts a turn, a pause ends it. Biased to miss rather than fire, since every turn it sends lands in the
/// thread for Otto to answer.
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
/// moments before a turn (so it keeps its first syllable), the open turn's voice note, and while the Mac's talk
/// stream takes the turn, the same sound as 16 kHz samples for it.
final class TalkMic: @unchecked Sendable {
    /// What the talk stream takes: 16 kHz, mono, 16-bit.
    static let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    private var mic: Float = 0, otto: Float = 0
    /// A level to report instead of the microphone's (DEBUG's fake mic).
    private var override: Float?
    /// The open turn's samples for the stream, not yet taken; nil while the turn isn't streamed.
    private var converter: AVAudioConverter?
    private var pcm = Data()
    /// Only what `heard(_:fed:)` is handed with `fed`, not the engine's: DEBUG's recorded voice.
    var fedOnly = false

    var level: Float { lock.withLock { override ?? mic } }
    var playing: Float { lock.withLock { otto } }
    func fake(_ level: Float?) { lock.withLock { override = level } }

    func heard(_ b: AVAudioPCMBuffer, fed: Bool = false) {
        guard fed || !fedOnly else { return }
        let rms = Self.rms(b)
        let copy = Self.mono(b)
        lock.withLock {
            mic = rms
            guard let copy else { return }
            if let file { try? file.write(from: copy); convert(copy); return }
            preroll.append(copy); prerollFrames += copy.frameLength
            // About 0.4 s kept: the voice that started the turn was already under way when it was recognised as one.
            while prerollFrames > AVAudioFrameCount(b.format.sampleRate * 0.4), preroll.count > 1 {
                prerollFrames -= preroll.removeFirst().frameLength
            }
        }
    }

    func played(_ b: AVAudioPCMBuffer) {
        let rms = Self.rms(b)
        lock.withLock { otto = rms }
        #if DEBUG
        // `-talkRecordOut <path>`: what the mixer plays, first channel, raw 32-bit floats, for measuring gaps.
        if let out = Self.recordOut, let d = b.floatChannelData { out.write(Data(bytes: d[0], count: Int(b.frameLength) * 4)) }
        #endif
    }
    #if DEBUG
    static let recordOut: FileHandle? = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-talkRecordOut"), a.indices.contains(i + 1) else { return nil }
        FileManager.default.createFile(atPath: a[i + 1], contents: nil)
        return FileHandle(forWritingAtPath: a[i + 1])
    }()
    #endif

    /// Opens a turn's file: AAC, mono, at the microphone's rate (the Mac's transcriber takes it as it takes a voice note).
    /// `stream`: the samples go to the talk stream too, from the first syllable.
    func begin(_ url: URL, format: AVAudioFormat, stream: Bool) throws {
        let f = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            pcm = Data()
            converter = stream ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1).flatMap { AVAudioConverter(from: $0, to: Self.wire) } : nil
            for b in preroll { try? f.write(from: b); convert(b) }
            preroll = []; prerollFrames = 0
            file = f
        }
    }

    /// The stream's samples since last asked.
    func take() -> Data { lock.withLock { defer { pcm = Data() }; return pcm } }

    /// The stream stops taking this turn (the socket went): the voice note carries on alone.
    func unstream() { lock.withLock { converter = nil; pcm = Data() } }

    /// Closes the turn's file, if one is open. What the stream hasn't taken yet stays for `take()`.
    @discardableResult func end() -> Bool {
        lock.withLock {
            defer { file?.close(); file = nil; converter = nil; mic = 0; otto = 0 }
            return file != nil
        }
    }

    /// Under the lock.
    private func convert(_ b: AVAudioPCMBuffer) {
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: Self.wire, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * 16000 / b.format.sampleRate) + 64)
        else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return b
        }
        if let d = out.int16ChannelData, out.frameLength > 0 { pcm.append(Data(bytes: d[0], count: Int(out.frameLength) * 2)) }
    }

    static func rms(_ b: AVAudioPCMBuffer) -> Float {
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

    /// One of Otto's clips off the talk stream: a WAV of 16-bit samples (the Mac's are 24 kHz mono), as floats to play.
    static func wav(_ data: Data) -> AVAudioPCMBuffer? {
        let d = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 | Int(d[i + 2]) << 16 | Int(d[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
        guard d.count >= 12, d[0..<4] == [82, 73, 70, 70], d[8..<12] == [87, 65, 86, 69] else { return nil }   // RIFF, WAVE
        var i = 12, channels = 0, rate = 0, bits = 0
        while i + 8 <= d.count {
            let size = u32(i + 4), tag = String(decoding: d[i..<i + 4], as: UTF8.self), at = i + 8
            guard at + size <= d.count else { return nil }
            if tag == "fmt ", size >= 16 { guard u16(at) == 1 else { return nil }; channels = u16(at + 2); rate = u32(at + 4); bits = u16(at + 14) }
            if tag == "data" {
                guard bits == 16, channels > 0, rate > 0, let f = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)) else { return nil }
                let frames = size / (2 * channels)
                guard frames > 0, let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames)), let out = b.floatChannelData else { return nil }
                b.frameLength = AVAudioFrameCount(frames)
                for n in 0..<frames { for c in 0..<channels { out[c][n] = Float(Int16(bitPattern: UInt16(u16(at + 2 * (n * channels + c))))) / 32768 } }
                return b
            }
            i = at + size + size % 2
        }
        return nil
    }
}

// MARK: - The session

/// A hands-free talk with Otto. It listens all the time; your voice starts a turn and a pause ends it. Each turn
/// streams to the Mac as you speak (otto-core's talk stream: your words come back as you say them, and Otto's
/// answer comes back as words, then its voice in short clips that play as they arrive). Talking over Otto stops it
/// at once and starts your turn. The microphone and Otto's voice run through one engine with the phone's echo
/// cancelling on, so Otto doesn't hear itself.
///
/// Every turn is also recorded as a voice note, and goes up as one whenever the stream can't take it: a Mac with
/// no talk stream, the socket dropping before the Mac wrote the turn down, or the Mac out of reach. Otto's answer
/// to a note is said as #55 said it: its own clip when it has one, the phone's voice when it doesn't.
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

    /// The turn going to the Mac over the talk stream, until the Mac has saved it.
    private struct Outgoing {
        /// The Mac's id for it, from talk.ready; nil until then.
        var turn: String?
        var line: Message.ID
        /// The same turn as a voice note, for when the stream can't take it.
        let note: URL
        let conn: Int
        let asked = Date.now
        var ended: Date?
        /// The Mac stopped listening on its own (a pause it heard, or the minute's limit): no more audio for it.
        var serverEnded = false
        var final = false
        var retried = false
        /// The stream gave up on it: it goes as a voice note under `turn`, once it's safe to (`settle()`).
        var abandoned: Date?
        /// talk.stop reached the socket the turn is on, so the Mac dropped it and can't finish it too.
        var stopped = false
    }

    /// Otto's answer coming down the talk stream: its words, then its voice in clips.
    private struct Reply {
        let turn: String
        let line: Message.ID
        var text: String
        let conn: Int
        let came = Date.now
        var clips = 0
        /// Frames scheduled and played, at `rate`.
        var queued = 0.0, played = 0.0, rate = 24_000.0
        /// Clips held back until there's enough to play without a gap (`release()`), and when the last one came.
        var held: [AVAudioPCMBuffer] = []
        var lastClip = Date.now
        /// Seconds held before playing starts or restarts; grows each time the clips run out mid-sentence.
        var hold = TalkSession.holdStart
        /// The longest clip so far: the Mac's are all one length but a sentence's last, which is shorter.
        var longest = 0.0
        /// A new sentence is coming (the last clip ended one, or talk.timing said so): its clips are held afresh.
        var fresh = false
        var done = false
        /// The socket went mid-answer: what came plays, and the line is kept as cut short there.
        var dropped = false
        /// Its voice didn't come in time, so the phone's said it.
        var phone = false
    }
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
    /// Words this talk has before the thread does: yours as the Mac hears them, Otto's as they come.
    private(set) var words: [Message.ID: String] = [:]
    /// The line whose words are still the Mac's guess (its last word may change).
    private(set) var guessing: Message.ID?
    /// The Mac heard nothing it could write down in your last turn.
    private(set) var missed = false
    /// Otto's steps on what you last asked, as its status line changed.
    private(set) var steps: [Step] = []
    /// Your screen goes to Otto with what you say (the OttoScreen broadcast), from when iOS's sheet starts it.
    private(set) var sharing = false
    /// The Mac doesn't take your screen (talk.error "unknown talk frame"): Share stays off on this connection.
    private(set) var screenRefused = false
    /// Why sharing just stopped, for a few seconds.
    private(set) var shareNote: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player = AVAudioPlayerNode()
    @ObservationIgnored private var format: AVAudioFormat?
    /// Read by the ring every frame, off observation.
    @ObservationIgnored let tap = TalkMic()
    @ObservationIgnored private var detector = TurnDetector()
    @ObservationIgnored private var turn: URL?
    /// The line of the turn being recorded.
    @ObservationIgnored private var turnLine: Message.ID?
    @ObservationIgnored private var outgoing: Outgoing?
    @ObservationIgnored private var reply: Reply?
    /// The turn whose answer talk will say: the last one the Mac wrote down, until you start another.
    @ObservationIgnored private var answering: String?
    /// Everything Otto answered over the stream, by turn: the same answer also comes as a message, not to be said twice.
    @ObservationIgnored private var replies: [String: String] = [:]
    /// Samples waiting for the turn's talk.ready.
    @ObservationIgnored private var pcm = Data()
    /// Whether this Mac has the talk stream: nil until a turn has tried it.
    @ObservationIgnored private var streams: Bool?
    /// The connection that verdict is about: a new one is asked again (a frozen socket can eat one talk.ready).
    @ObservationIgnored private var streamsConn = 0
    /// This talk has had a talk.ready: the Mac has the stream, so a missing one later is the link, not the Mac.
    @ObservationIgnored private var streamedOnce = false
    @ObservationIgnored private var frames: Task<Void, Never>?
    @ObservationIgnored private var playing: (frames: Double, gen: Int)?
    /// Bumped whenever Otto's voice is stopped or replaced, so a late callback from the last one is ignored.
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private let aloud = Aloud()
    @ObservationIgnored private var rendering: Rendering?
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
    @ObservationIgnored private var shareNoteAt = Date.distantPast
    @ObservationIgnored private var shareSince = Date.distantPast
    /// When a frame of your screen last went, and which one (its file's date).
    @ObservationIgnored private var screenSent: Date?
    @ObservationIgnored private var screenSentOf: Date?
    /// The connection asked whether it takes your screen.
    @ObservationIgnored private var screenAsked = -1
    @ObservationIgnored private var stamped = Date.distantPast
    #if DEBUG
    @ObservationIgnored private var fakeShare: Task<Void, Never>?
    @ObservationIgnored private var firstSpoke: Date?
    @ObservationIgnored private var fakeClips: [AVAudioPCMBuffer] = []
    @ObservationIgnored private var fakeFed: [AVAudioFrameCount] = []
    @ObservationIgnored private var dropped = false
    #endif

    private var store: OttoStore { .shared }
    private var live: LiveBackend? { store.backend as? LiveBackend }

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

    /// A line's words: the thread's once it has them, else what the talk stream said.
    func text(_ id: Message.ID) -> String {
        if let t = store.messages.last(where: { $0.id == id })?.text, !t.isEmpty { return t }
        return words[id] ?? ""
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
        words = [:]; guessing = nil; missed = false; turnLine = nil
        outgoing = nil; reply = nil; answering = nil; replies = [:]; pcm = Data(); streams = nil; streamedOnce = false
        sharing = false; screenRefused = false; shareNote = nil; screenSent = nil; screenSentOf = nil; screenAsked = -1
        heard = Set(store.messages.map(\.id)); seen = [:]
        AudioPlayer.shared.stop()   // a voice note playing in the thread
        UIApplication.shared.isIdleTimerDisabled = true
        #if DEBUG
        if let state = Self.fixtureState { return fixture(state) }
        loadFake()
        #endif
        observe()
        listen()
        await openMic()
        #if DEBUG
        if Self.fakeScreen { fakeSharing() }
        #endif
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
        stopSharing(nil)   // a talk's end always ends the broadcast, and leaves no frame
        loop?.cancel(); loop = nil
        _ = detector.close()
        hearing = false
        if let turn { tap.end(); try? FileManager.default.removeItem(at: turn) }   // ended mid-sentence: dropped, not sent
        // A turn already said goes on without the talk: the Mac saves it, and its answer lands in the thread, unspoken.
        if let o = outgoing, o.ended == nil { if o.abandoned == nil { live?.talkSend(["type": "talk.stop"]) } }
        else if outgoing?.abandoned != nil { settle(now: true) }   // a turn said and not yet sent: it still goes
        else if reply != nil { live?.talkSend(["type": "talk.cut"]) }
        turn = nil; outgoing = nil; reply = nil
        frames?.cancel(); frames = nil
        live?.talkSink = nil
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
        #if DEBUG
        if let c = fakeClips.first { format = c.format; tap.fedOnly = true }   // the recorded voice stands in for the microphone
        #endif
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
        // The broadcast extension starting and finishing (the system's red pill, Control Center, or its own end).
        DictationBridge.observe(ScreenShare.started) { MainActor.assumeIsolated { TalkSession.current?.shareStarted() } }
        DictationBridge.observe(ScreenShare.finished) { MainActor.assumeIsolated { TalkSession.current?.shareFinished() } }
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
        if !ended { screen() }   // first: a paused microphone (a call) doesn't stop sharing
        guard !ended, mic == .on else { return show() }
        var level = muted ? 0 : tap.level
        #if DEBUG
        if let f = fakeMic() { tap.fake(muted ? 0 : f); level = muted ? 0 : f }
        if let f = feedFake() { level = muted ? 0 : f }
        #endif
        switch detector.step(level: level, dt: 0.05, ottoSpeaking: saying != nil) {
        case .start?: beginTurn()
        case .end(let send)?: finishTurn(send: send)
        case nil: break
        }
        stream()
        speakRendered()
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
        if saying != nil || reply != nil { cut() }
        answering = nil   // whatever Otto was about to say to your last turn is moot now
        guard let format else { return }
        let url = URL.temporaryDirectory.appending(path: "talk-\(UUID().uuidString).m4a")
        if let live, live.connections != streamsConn { streams = nil }
        let streamed = streams != false && live?.isLive == true && !Self.notesOnly
        do { try tap.begin(url, format: format, stream: streamed) } catch {
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
        missed = false
        let line = UUID()
        turnLine = line
        lines.append(Line(id: line, at: Date.now.timeIntervalSince(started), otto: false))
        // The last turn, still being written down: the Mac carries on with it without us, or if it never said it was
        // listening, it goes as a voice note now.
        if let o = outgoing {
            if o.abandoned != nil { settle(now: true) }
            else if o.turn == nil { fallBack(); settle(now: true) }
            else { try? FileManager.default.removeItem(at: o.note); outgoing = nil; pcm = Data() }
        }
        if streamed, let live, live.talkSend(["type": "talk.start"]) {
            outgoing = Outgoing(line: line, note: url, conn: live.connections)
            guessing = line
        }
    }

    private func finishTurn(send: Bool) {
        hearing = false
        tap.end()
        guard let url = turn, let line = turnLine else { return }
        turn = nil; turnLine = nil
        guard send else {
            // Too short to be a turn (a cough, a door): gone, here and on the Mac.
            try? FileManager.default.removeItem(at: url)
            lines.removeAll { $0.id == line }
            words[line] = nil
            if outgoing != nil { outgoing = nil; pcm = Data(); guessing = nil; live?.talkSend(["type": "talk.stop"]) }
            return
        }
        if var o = outgoing {
            o.ended = .now
            outgoing = o
            if o.abandoned != nil { settle() }
            else {
                stream()   // what's left of it
                if o.turn != nil && !o.serverEnded { sendEnd() }
            }
        } else {
            note(line, url)
        }
        awaiting = true
        asked = .now; steps = []; lastStatus = store.ottoStatus
    }

    private func closeTurn(send: Bool) {
        if case .end(let ok)? = detector.close() { finishTurn(send: send && ok) }
    }

    /// The turn as a voice note, as the walkie-talkie sent one: its line becomes the note's bubble. Under the Mac's id
    /// for the turn when the stream had one: the Mac takes an id it already has in once, whichever way came first.
    private func note(_ line: Message.ID, _ url: URL, turn: String? = nil) {
        guard let id = store.sendVoice(url, wireID: turn, via: "talk") else {
            try? FileManager.default.removeItem(at: url)
            lines.removeAll { $0.id == line }
            return
        }
        heard.insert(id)
        rebind(line, to: id)
    }

    private func rebind(_ old: Message.ID, to new: Message.ID) {
        if let i = lines.firstIndex(where: { $0.id == old }) { let l = lines[i]; lines[i] = Line(id: new, at: l.at, otto: l.otto, cut: l.cut) }
        if let w = words.removeValue(forKey: old) { words[new] = w }
        if guessing == old { guessing = new }
        if turnLine == old { turnLine = new }
    }

    /// The note again, as the thread's own retry does: no second copy.
    func retry() {
        guard let id = undelivered else { return }
        store.retry(id)
    }

    // MARK: The talk stream

    private func listen() {
        frames?.cancel()
        guard let live else { return }
        let (s, c) = AsyncStream<Data>.makeStream()
        live.talkSink = c
        frames = Task { [weak self] in for await d in s { self?.frame(d) } }
    }

    /// Sends what the microphone has for the turn, once the Mac has said it's listening; and notices a stream that
    /// can't take the turn, so the voice note does.
    private func stream() {
        pcm.append(tap.take())
        if outgoing?.abandoned != nil {
            pcm = Data()
            settle()
        } else if let o = outgoing, let live {
            if o.turn != nil, !o.serverEnded {
                while !pcm.isEmpty {
                    let n = min(pcm.count, 3200)   // 100 ms
                    live.talkSend(["type": "talk.audio", "audio": pcm.prefix(n).base64EncodedString()])
                    pcm.removeFirst(n)
                }
            }
            // The socket dropped before the Mac wrote the turn down: a turn it hasn't written down is gone there.
            if !o.final && (live.connections != o.conn || !live.isLive) { return fallBack() }
            // No talk.ready: a Mac without the talk stream. Every turn after this one goes as a note.
            // No talk.ready. A Mac that has never said it (this talk) has no talk stream: this connection's turns go as
            // notes. One that has is on a slow link: only this turn does, and the next tries the stream again.
            if o.turn == nil && Date.now.timeIntervalSince(o.asked) > Self.readyWait {
                if !streamedOnce { streams = false; streamsConn = live.connections }
                return fallBack()
            }
            // The Mac said nothing more about it: sent again as a note. Long, as a slow transcriber isn't helped by a second
            // job (one took 20 s on a loaded Mac), and a transcriber that fails says so with talk.error.
            if let e = o.ended, !o.final, Date.now.timeIntervalSince(e) > 45 { return fallBack() }
        } else {
            pcm = Data()
        }
        if let r = reply, !r.done, let live, live.connections != r.conn || !live.isLive { reply?.dropped = true; replyDone(r.turn) }
        // Otto's words came and its voice hasn't: the phone's says them, and the Mac stops making it.
        if let r = reply, r.clips == 0, !r.phone, !hearing, saying == nil, Date.now.timeIntervalSince(r.came) > Self.voiceWait {
            if outgoing == nil { live?.talkSend(["type": "talk.cut"]) }
            phone(r)
        }
        if let r = reply, !r.held.isEmpty, Self.release(held: held(r), hold: r.hold, sentenceEnded: false, done: r.done, quiet: Date.now.timeIntervalSince(r.lastClip)) { release() }
        if let r = reply, r.clips > 0, saying == r.line {
            // ponytail: how far through its words Otto is, from the share of audio played against a speaking rate
            // until talk.done says how much audio there is; the clips carry no word timings.
            let total = r.done && !r.dropped ? r.queued : max(r.queued, Double(r.text.count) / 14 * r.rate)
            said = max(said, min(1, r.played / max(1, total)))
        }
    }

    /// The stream can't take this turn: it goes as a voice note instead, once you've paused and it's safe to. Never
    /// both: one the Mac wrote down (talk.final) never goes as a note.
    private func fallBack() {
        guard var o = outgoing, o.abandoned == nil else { return }
        if o.final { try? FileManager.default.removeItem(at: o.note); outgoing = nil; return }
        #if DEBUG
        NSLog("talk: turn goes as a voice note (%@)", o.turn ?? "never ready")
        #endif
        pcm = Data(); guessing = nil
        tap.unstream()
        // Stopped on the socket the turn is on, the Mac drops it. A dropped socket can't carry the stop, and the Mac
        // may not have noticed it go: it can still finish the turn, so `settle()` waits for its copy first.
        o.stopped = live?.connections == o.conn && live?.isLive == true && live?.talkSend(["type": "talk.stop"]) == true
        o.abandoned = .now
        outgoing = o
        settle()
    }

    /// How long a turn the Mac may still be finishing (its socket dropped) waits for the Mac's copy before its note goes.
    static let orphanWait: TimeInterval = 10

    /// Sends an abandoned turn's note when it's safe to, or drops it if the Mac's own copy of the turn turned up.
    /// `now`: send it whatever (a new turn or the end of the talk); under the turn's id, the Mac still keeps one copy if
    /// the stream's landed first.
    private func settle(now: Bool = false) {
        guard let o = outgoing, let gaveUp = o.abandoned, let said = o.ended else { return }
        if let t = o.turn, !o.stopped, !now {
            if store.messages.contains(where: { $0.wireID == t }) {
                #if DEBUG
                NSLog("talk: the Mac finished %@ after all, no note", t)
                #endif
                try? FileManager.default.removeItem(at: o.note)
                outgoing = nil
                return
            }
            guard Date.now.timeIntervalSince(max(gaveUp, said)) > Self.orphanWait else { return }
        }
        outgoing = nil
        if let t = o.turn, store.messages.contains(where: { $0.wireID == t }) { try? FileManager.default.removeItem(at: o.note); return }
        note(o.line, o.note, turn: o.turn)
    }

    private func frame(_ data: Data) {
        struct Frame: Decodable { let type: String; let turn: String?; let text: String?; let audio: String?; let error: String?; let sentenceToAudioMs: Double? }
        guard !ended, let f = try? JSONDecoder().decode(Frame.self, from: data) else { return }
        #if DEBUG
        if f.type != "talk.audio" || reply?.clips == 0 { NSLog("talk: %@ %@ %@", f.type, String((f.turn ?? "-").prefix(8)), f.text.map { "\($0.count) chars" } ?? f.error ?? "") }
        #endif
        switch f.type {
        case "talk.ready":
            guard var o = outgoing, o.turn == nil, o.abandoned == nil, let t = f.turn else { return }
            streams = true; streamsConn = live?.connections ?? 0; streamedOnce = true
            o.turn = t
            // The line takes the Mac's id for the turn: the thread's copy of it comes back under it.
            if let id = UUID(uuidString: t) { rebind(o.line, to: id); o.line = id }
            outgoing = o
            stream()
            if o.ended != nil { sendEnd() }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-talkDrop"), !dropped, Self.dropAt == "turn" {
                dropped = true
                Task { try? await Task.sleep(for: .seconds(1)); self.live?.dropSocket() }
            }
            #endif
        case "talk.partial":
            if let o = outgoing, o.turn == f.turn, o.abandoned == nil, !o.final, let text = f.text { words[o.line] = text }
        case "talk.ending":
            guard var o = outgoing, o.turn == f.turn, o.abandoned == nil else { return }
            o.serverEnded = true
            outgoing = o
            if hearing { _ = detector.close(); finishTurn(send: true) }
        case "talk.final":
            guard var o = outgoing, o.turn == f.turn else { return }
            // Written down after the stream gave up on it (the stop crossed it): the Mac has it, so no note.
            if o.abandoned != nil { try? FileManager.default.removeItem(at: o.note); outgoing = nil; return }
            if let text = f.text { words[o.line] = text }
            o.final = true
            outgoing = o
            guessing = nil
            answering = o.turn
        case "talk.accepted":
            guard let o = outgoing, o.turn == f.turn else { return }
            try? FileManager.default.removeItem(at: o.note)
            outgoing = nil
        case "talk.text":
            guard let t = f.turn, let text = f.text else { return }
            replies[t, default: ""] += text
            guard t == answering else { return }
            if var r = reply, r.turn == t { r.text += text; reply = r; words[r.line] = r.text; return }
            let id = UUID()
            words[id] = text
            reply = Reply(turn: t, line: id, text: text, conn: live?.connections ?? 0)
        case "talk.audio":
            if let t = f.turn, let a = f.audio { clip(t, a) }
        case "talk.done":
            if let t = f.turn { replyDone(t) }
        case "talk.timing":
            // A sentence's first clip is next: what's held of the last one goes, and the new one is held afresh.
            guard f.sentenceToAudioMs != nil, reply?.turn == f.turn else { return }
            release()
            reply?.fresh = true
        case "talk.error":
            failed(f.turn, f.error ?? "")
        default: break   // talk.cut, the other talk.timing
        }
    }

    private func failed(_ turn: String?, _ error: String) {
        #if DEBUG
        NSLog("talk: %@", error)
        #endif
        // A Mac that doesn't take your screen: Share goes off and the talk carries on. Before anything about the turn,
        // since the error carries the turn's id and would otherwise send it as a voice note.
        if error.contains("unknown talk frame") {
            screenRefused = true
            if sharing { stopSharing("Your Mac can’t see your screen yet, so sharing stopped.") }
            return
        }
        // About a turn already written down (Otto's speech), or one that carries on: talk.done follows, or the turn does.
        guard let o = outgoing, o.abandoned == nil, o.turn == nil || o.turn == turn else { return }
        if ["send talk.start before audio", "60 second turn limit", "audio must", "speech unavailable"].contains(where: error.hasPrefix) { return }
        if error.contains("could not hear") || error.contains("empty turn") {
            // The Mac heard nothing it could write down: a note would hear no more. Said, and dropped.
            outgoing = nil; pcm = Data(); guessing = nil
            try? FileManager.default.removeItem(at: o.note)
            lines.removeAll { $0.id == o.line }
            awaiting = false; missed = true
            return
        }
        // A turn left open on the Mac (or eight unanswered ones) refused the start: cleared, and tried once more.
        if o.turn == nil && !o.retried, let live {
            live.talkSend(["type": "talk.stop"]); live.talkSend(["type": "talk.start"])
            outgoing?.retried = true
            return
        }
        fallBack()
    }

    // MARK: Your screen

    /// Share screen can start: a Mac that streams talk and takes your screen, and a shared folder for the frames.
    /// In voice-note mode there's no turn on the socket to send them with.
    var canShare: Bool {
        #if DEBUG
        if Self.fixtureState != nil { return !screenRefused }
        #endif
        return live != nil && streams != false && !Self.notesOnly && !screenRefused && ScreenShare.dir != nil
    }

    /// Every tick: say the talk is still here (the extension stops without it), ask a new connection whether it takes
    /// your screen, notice a share that ended under us, and while you speak send the newest frame at most every 2 s.
    private func screen() {
        if Date.now.timeIntervalSince(stamped) >= 1 {
            stamped = .now
            ScreenShare.stamp(ScreenShare.appAlive)
            if shareNote != nil, Date.now.timeIntervalSince(shareNoteAt) > 6 { shareNote = nil }
            // Before you go through iOS's sheet: a Mac that doesn't know the frame answers "unknown talk frame".
            if let live, live.isLive, screenAsked != live.connections, !Self.notesOnly {
                screenAsked = live.connections; screenRefused = false
                live.talkSend(["type": "talk.screen", "off": true])
            }
            if sharing, !canShare { return stopSharing("Your Mac can’t see your screen yet, so sharing stopped.") }
            // The extension went without a word (out of memory): sharing is over.
            if sharing, Date.now.timeIntervalSince(shareSince) > ScreenShare.stale, (ScreenShare.age(ScreenShare.extensionAlive) ?? .infinity) > ScreenShare.stale { return stopSharing() }
        }
        guard sharing, hearing, let o = outgoing, o.turn != nil, o.abandoned == nil, !o.serverEnded, ScreenShare.due(screenSent),
              let at = ScreenShare.frameDate(), at != screenSentOf else { return }
        sendScreen()
    }

    /// The newest frame, to the Mac. Never read while sharing is off.
    private func sendScreen() {
        guard sharing, !screenRefused, let live, let f = ScreenShare.latest() else { return }
        live.talkSend(["type": "talk.screen", "image": f.jpeg.base64EncodedString(), "width": f.width, "height": f.height])
        screenSent = .now; screenSentOf = f.at
    }

    /// Your turn's end, with your screen as it is right then.
    private func sendEnd() {
        sendScreen()
        live?.talkSend(["type": "talk.end"])
    }

    /// Share screen, for VoiceOver and the DEBUG canned screen: a finger lands on the system's own picker instead.
    func share() {
        guard canShare, !sharing else { return }
        ScreenShare.stamp(ScreenShare.appAlive)
        #if DEBUG
        if Self.fakeScreen { return fakeSharing() }
        #endif
        BroadcastPicker.open()
    }

    /// The broadcast started: frames from here on, if this talk can take them; else it's finished at once.
    private func shareStarted() {
        guard !ended, canShare else { return stopSharing(nil) }
        sharing = true; shareNote = nil; shareSince = .now; screenSent = nil; screenSentOf = nil
    }

    /// The broadcast finished on its own: the system's red pill, Control Center, or the extension giving up.
    private func shareFinished() { if sharing { stopSharing() } }

    /// Sharing stops, whatever stopped it: the Mac is told, the frame goes, and the broadcast is finished.
    func stopSharing(_ note: String? = "Stopped sharing. Otto can’t see your screen.") {
        let was = sharing
        sharing = false
        #if DEBUG
        fakeShare?.cancel(); fakeShare = nil
        #endif
        ScreenShare.clear()
        DictationBridge.post(ScreenShare.stop)
        guard was else { return }
        if !screenRefused { live?.talkSend(["type": "talk.screen", "off": true]) }
        screenSent = nil; screenSentOf = nil
        if let note { shareNote = note; shareNoteAt = .now }
    }

    // MARK: Otto's voice

    /// How long a reply's own voice is waited for before its words go out in the phone's voice. A voice note's
    /// answer comes as text first and its clip after (the Mac's speech takes seconds, and when it's off the clip
    /// never comes); a streamed answer's words come a moment before its first clip.
    nonisolated static let clipWait: TimeInterval = 2
    /// How long a streamed answer's words wait for its first clip before the phone's voice says them. Measured on the
    /// Mac with its speech warm: 2.2 to 2.8 s from the words to the first clip; cold, about 13 s.
    static let voiceWait: TimeInterval = 6
    /// How long a turn waits for the Mac to say it's listening before it goes as a voice note.
    static let readyWait: TimeInterval = 2
    #if DEBUG
    /// `-talkNoStream`: every turn as a voice note, as on a Mac without the talk stream.
    static let notesOnly = ProcessInfo.processInfo.arguments.contains("-talkNoStream")
    #else
    static let notesOnly = false
    #endif
    #if DEBUG
    /// `-talkScreen [seconds]`: a canned screen stands in for the broadcast extension (which the simulator can't run),
    /// from the talk's start and on Share: written through the same pipeline and into the same file, and sent the same
    /// way. With seconds, sharing stops after that long, as the chip at the top stops it.
    static let fakeScreen = ProcessInfo.processInfo.arguments.contains("-talkScreen")
    #else
    static let fakeScreen = false
    #endif

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

    /// A message the talk stream already said (or is saying): the same answer, as the thread gets it, in one or more bubbles.
    nonisolated static func streamed(_ m: Message, in replies: some Sequence<String>) -> Bool {
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && replies.contains { $0.contains(t) }
    }

    /// Otto's next new message, said out loud, in the order they came.
    private func sayNext() {
        let since = started.addingTimeInterval(-30)   // history caught up after a reconnect is old news
        let now = Date.now
        for m in store.messages where m.from == .otto && !heard.contains(m.id) && m.date >= since {
            if let k = replies.first(where: { Self.streamed(m, in: [$0.value]) })?.key {
                // Said over the stream. Taken off what's kept, so a later "Done." isn't found in an older answer.
                if let r = replies[k]?.range(of: m.text.trimmingCharacters(in: .whitespacesAndNewlines)) { replies[k]?.removeSubrange(r) }
                heard.insert(m.id); continue
            }
            let first = seen[m.id] ?? now
            seen[m.id] = first
            // Its talk.text can be a moment behind it on another stream; a streamed answer is said from there.
            if streams == true && now.timeIntervalSince(first) < 0.5 { return }
            let say = Self.say(m, waited: now.timeIntervalSince(first))
            #if DEBUG
            if say != .wait { NSLog("talk: %@ after %.1f s", String(describing: say), now.timeIntervalSince(first)) }
            #endif
            switch say {
            case .skip: heard.insert(m.id)
            case .wait: return   // what Otto said after it waits behind it
            case .clip: heard.insert(m.id); awaiting = false; return sayClip(m, m.audio!)
            case .text: heard.insert(m.id); awaiting = false; return sayText(m.id, m.text)
            }
        }
    }

    private func sayClip(_ m: Message, _ clip: RemoteFile) {
        let g = begin(m.id)
        Task {
            let data = try? await store.backend.file(clip.id)
            guard g == gen else { return }
            let ext = (clip.name as NSString).pathExtension
            let url = URL.temporaryDirectory.appending(path: "talk-reply-\(UUID().uuidString).\(ext.isEmpty ? "m4a" : ext)")
            guard let data, (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url), let engine else {
                // The clip couldn't be had: its words, in the phone's voice.
                return m.text.isEmpty ? done(g) : sayText(m.id, m.text)
            }
            player.stop()
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack, completionHandler: Self.finished { [weak self] in self?.done(g) })
            play(frames: Double(file.length), gen: g)
        }
    }

    /// Words with no voice of their own: the phone's voice, rendered first so it plays through the same engine
    /// (and its echo cancelling) as everything else Otto says.
    private func sayText(_ id: Message.ID, _ text: String) {
        let g = saying == id ? gen : begin(id)
        let box = Rendered()
        rendering = Rendering(box: box, id: id, text: text, gen: g)
        synth.write(AVSpeechUtterance(string: text), toBufferCallback: Self.collect(box))
        // Nothing rendered in 3 s: the phone's voice straight out instead, so the words are never left unsaid.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, g == self.gen, self.saying == id, box.isEmpty else { return }
            self.synth.stopSpeaking(at: .immediate)
            self.rendering = nil
            self.sayAloud(id, text)
        }
    }

    /// The phone's voice played as it renders, a piece at a time, so a long answer doesn't wait for its last word.
    private func speakRendered() {
        guard var r = rendering else { return }
        guard r.gen == gen, let engine else { rendering = nil; return }
        let finished = r.box.finished
        for b in r.box.buffers.dropFirst(r.taken) {
            r.taken += 1
            guard let f = r.format ?? AVAudioFormat(standardFormatWithSampleRate: b.format.sampleRate, channels: b.format.channelCount),
                  let pcm = Self.float(b, f) else { continue }
            if r.format == nil {
                r.format = f
                player.stop()
                engine.connect(player, to: engine.mainMixerNode, format: f)
                play(frames: 0, gen: gen)
            }
            let n = Double(pcm.frameLength), g = gen
            r.queued += n
            player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack, completionHandler: Self.finished { [weak self] in
                if self?.gen == g { self?.rendering?.played += n }
            })
        }
        rendering = r
        if finished && r.queued == 0 { rendering = nil; return sayAloud(r.id, r.text) }
        guard r.queued > 0 else { return }
        let total = finished ? r.queued : max(r.queued, Double(r.text.count) / 14 * (r.format?.sampleRate ?? 22_050))
        said = max(said, min(1, r.played / total))
        if finished && r.played >= r.queued { rendering = nil; done(gen) }
    }

    /// The phone's voice spoken directly, for when rendering it gave nothing to play. It doesn't pass through the
    /// engine, so the echo cancelling may not take it out of the microphone; that beats words left unsaid.
    private func sayAloud(_ id: Message.ID, _ text: String) {
        gen += 1
        let g = gen
        saying = id; playing = nil
        let n = Double(max(1, (text as NSString).length))
        aloud.heard = { [weak self] range, over in
            guard let self, g == self.gen else { return }
            if over { self.done(g) } else { self.said = Double(range.upperBound) / n }
        }
        aloud.synth.speak(AVSpeechUtterance(string: text))
        #if DEBUG
        NSLog("talk: the phone's voice, straight out")
        if firstSpoke == nil { firstSpoke = .now }
        #endif
    }

    /// Seconds of Otto's voice held before it starts, or starts again after its clips ran out: the Mac makes them at
    /// about the speed they play, often slower when it's busy, so playing each the moment it lands leaves a gap at
    /// every seam. Grows by `holdStep` each time they run out mid-sentence, up to `holdMost`.
    nonisolated static let holdStart = 0.5, holdStep = 0.25, holdMost = 1.5
    #if DEBUG
    /// `-talkNoHold`: each clip plays the moment it lands, as before the hold, to compare the seams.
    static let noHold = ProcessInfo.processInfo.arguments.contains("-talkNoHold")
    #else
    static let noHold = false
    #endif

    /// Whether held clips go to the player now: enough of them, the end of a sentence or of the answer, or nothing more
    /// for a while (a sentence's end the clip lengths didn't show).
    nonisolated static func release(held: Double, hold: Double, sentenceEnded: Bool, done: Bool, quiet: Double) -> Bool {
        held > 0 && (held >= hold || sentenceEnded || done || quiet > 1)
    }

    /// A clip of a streamed answer. While the player still has some of Otto's voice ahead of it, the clip joins the
    /// queue at once, back to back on the one player; once it has run out (or before the first), clips are held until
    /// `release(...)` says there are enough to carry on without a gap.
    private func clip(_ turn: String, _ base64: String) {
        guard var r = reply, r.turn == turn, !r.phone, let data = Data(base64Encoded: base64), let b = TalkMic.wav(data) else { return }
        let frames = Double(b.frameLength)
        if r.clips == 0 { r.rate = b.format.sampleRate }
        r.clips += 1
        r.lastClip = .now
        let ends = r.longest > 0 && frames < r.longest * 0.9
        r.longest = max(r.longest, frames)
        r.held.append(b)
        reply = r
        if Self.noHold || (r.queued > r.played && !r.fresh) { release() }
        else if Self.release(held: held(r), hold: r.hold, sentenceEnded: ends, done: r.done, quiet: 0) { release() }
        if ends { reply?.fresh = true }
    }

    private func held(_ r: Reply) -> Double { r.held.reduce(0) { $0 + Double($1.frameLength) } / r.rate }

    /// Held clips to the player, back to back; the first of the answer starts Otto's voice (the one `play()`).
    private func release() {
        guard var r = reply, !r.held.isEmpty, let engine else { return }
        if r.queued == 0 {
            _ = begin(r.line)
            awaiting = false
            player.stop()
            engine.connect(player, to: engine.mainMixerNode, format: r.held[0].format)
            r.rate = r.held[0].format.sampleRate
            play(frames: 0, gen: gen)   // no total yet: `stream()` moves the words along instead
            #if DEBUG
            if Self.dropAt == "answer", !dropped { dropped = true; live?.dropSocket() }
            #endif
        }
        let g = gen
        for b in r.held {
            let frames = Double(b.frameLength)
            r.queued += frames
            player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack, completionHandler: Self.finished { [weak self] in self?.played(frames, gen: g) })
        }
        r.held = []
        r.fresh = false
        reply = r
    }

    private func played(_ frames: Double, gen g: Int) {
        guard g == gen, var r = reply else { return }
        r.played += frames
        // Ran out mid-sentence: the Mac is slower than the voice right now, so hold more before the next stretch.
        if r.played >= r.queued && r.held.isEmpty && !r.done && !r.fresh { r.hold = min(r.hold + Self.holdStep, Self.holdMost) }
        reply = r
        if r.done && r.held.isEmpty && r.played >= r.queued { finish(r) }
    }

    /// No more of this answer is coming (talk.done, or the socket went): said in the phone's voice if none of its
    /// own came, else finished once what came has played.
    private func replyDone(_ turn: String) {
        guard var r = reply, r.turn == turn else { return }
        r.done = true
        reply = r
        if r.phone { reply = nil; return }
        if r.clips == 0 { return phone(r) }
        release()
        if let r = reply, r.played >= r.queued { finish(r) }
    }

    private func finish(_ r: Reply) {
        reply = nil
        let reached = said
        done(gen)
        // The socket went mid-answer: what came has played, and the rest of its words go in the phone's voice.
        guard r.dropped, let i = lines.lastIndex(where: { $0.id == r.line }) else { return }
        let rest = r.text.dropFirst(Lit.head(r.text, reached).count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return }
        if hearing { lines[i].cut = reached; return }   // you're talking: kept as cut short, as a cut-in is
        let id = UUID()
        words[id] = rest
        sayText(id, rest)
    }

    private func phone(_ r: Reply) {
        #if DEBUG
        NSLog("talk: no voice for %@, the phone says it", r.turn)
        #endif
        reply?.phone = true
        awaiting = false
        sayText(r.line, r.text)
    }

    private func begin(_ id: Message.ID) -> Int {
        #if DEBUG
        NSLog("talk: Otto says: %@", String(text(id).prefix(48)))
        #endif
        gen += 1
        saying = id; said = 0; cutIn = false
        lines.append(Line(id: id, at: Date.now.timeIntervalSince(started), otto: true))
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
    /// The Mac stops making the rest of its voice.
    private func cut() {
        if reply != nil {
            // Before any talk.start: a cut reaches every turn on the socket, and a recording one would lose its voice.
            if outgoing == nil { live?.talkSend(["type": "talk.cut"]) }
            reply = nil
        }
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
        playing = nil; saying = nil; rendering = nil
    }

    private nonisolated static func finished(_ then: @escaping @MainActor () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { _ in Task { @MainActor in then() } }
    }

    /// The phone's voice as it renders, filled on the synthesizer's thread.
    final class Rendered: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [AVAudioPCMBuffer] = []
        private var over = false
        var buffers: [AVAudioPCMBuffer] { lock.withLock { all } }
        var isEmpty: Bool { lock.withLock { all.isEmpty } }
        var finished: Bool { lock.withLock { over } }
        func add(_ b: AVAudioPCMBuffer) { lock.withLock { all.append(b) } }
        func finish() { lock.withLock { over = true } }
    }
    private struct Rendering {
        let box: Rendered
        let id: Message.ID
        let text: String
        let gen: Int
        var taken = 0
        var format: AVAudioFormat?
        var queued = 0.0, played = 0.0
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

    private nonisolated static func collect(_ box: Rendered) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return box.finish() }
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
        // Sharing shows in the compact island as a phone, as the mockup has it; its stopping, in words.
        let inTalk = [.hearing, .speaking, .thinking, .working, .listening].contains(phase)
        if inTalk, !sharing, shareNote != nil, phase == .listening || phase == .thinking {
            return .init(title: "Stopped sharing", line: "Otto can’t see your screen any more.", symbol: "iphone.slash", started: started, muted: muted)
        }
        return .init(title: mute && phase == .listening ? "Muted" : title, line: line,
                     symbol: mute ? "mic.slash" : sharing && inTalk ? "iphone" : symbol, started: started, muted: muted, sharing: sharing)
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
        // The ring leans only while it hears a voice: `-talkLean` shots get a steady one.
        if ProcessInfo.processInfo.arguments.contains("-talkLean") { tap.fake(0.05) }
        func say(_ otto: Bool, _ at: TimeInterval, _ text: String, cut: Double? = nil) -> Message.ID {
            let id = UUID(); words[id] = text
            lines.append(Line(id: id, at: at, otto: otto, cut: cut)); return id
        }
        mic = .on
        let ask = say(false, 2, "Find me a train to Turin on Saturday, something before nine.")
        _ = ask
        let offer = "There’s a 7:52 from Milano Centrale that gets you in at 8:55, and an 8:10 that’s cheaper but slower. Want the 7:52?"
        switch state {
        case "listening": lines = []
        case "hearing":
            lines = []; hearing = true
            guessing = say(false, 2, "Find me a train to Turin on Saturday, something before nine")
        case "missed": lines = []; missed = true
        case "thinking": awaiting = true
        case "speaking": saying = say(true, 6, offer); said = 0.48
        case "cutin":
            _ = say(true, 6, offer, cut: 0.42)
            hearing = true; cutIn = true
            guessing = say(false, 9, "The 7:52, window seat please")
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
        case "share": saying = say(true, 6, offer); said = 0.48; sharing = true
        case "share-stopped": lines = []; shareNote = "Stopped sharing. Otto can’t see your screen."
        case "share-refused": lines = []; screenRefused = true
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

    /// The canned screen in place of the extension (`fakeScreen`).
    private func fakeSharing() {
        guard canShare, !sharing else { return }
        let context = CIContext(), canned = Self.cannedScreen()
        ScreenShare.stamp(ScreenShare.extensionAlive)
        shareStarted()
        let a = ProcessInfo.processInfo.arguments, since = Date.now
        let stopAfter = a.firstIndex(of: "-talkScreen").flatMap { a.indices.contains($0 + 1) ? TimeInterval(a[$0 + 1]) : nil }
        fakeShare = Task { [weak self] in
            var wrote: Date?
            while !Task.isCancelled, self?.sharing == true {
                if let stopAfter, Date.now.timeIntervalSince(since) > stopAfter { self?.stopSharing(); return }
                ScreenShare.stamp(ScreenShare.extensionAlive)
                if ScreenShare.due(wrote), let jpeg = ScreenShare.jpeg(canned, context: context) { ScreenShare.write(jpeg); wrote = .now }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A phone-sized screen (1206 × 2622 px) of a checkout form.
    static func cannedScreen() -> CIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1206, height: 2622), format: f).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1206, height: 2622))
            let big: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 84, weight: .bold), .foregroundColor: UIColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.darkGray]
            ("Checkout" as NSString).draw(at: CGPoint(x: 72, y: 220), withAttributes: big)
            for (i, label) in ["Name", "Street address", "Postcode", "City", "Card number"].enumerated() {
                (label as NSString).draw(at: CGPoint(x: 72, y: 420 + i * 260), withAttributes: body)
                UIColor.systemGray4.setStroke()
                UIBezierPath(roundedRect: CGRect(x: 72, y: 490 + i * 260, width: 1062, height: 130), cornerRadius: 24).stroke()
            }
            ("The address doesn’t match the postcode." as NSString).draw(at: CGPoint(x: 72, y: 1780), withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.systemRed])
        }
        return CIImage(image: image) ?? CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1206, height: 2622))
    }

    /// `-talkDrop turn|answer`: the socket cut a second into your first streamed turn, or as Otto's first answer starts.
    static let dropAt: String? = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-talkDrop").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
    }()

    /// `-talkFakeVoice <a.wav>,<b.wav>`: recorded speech where the simulator has no voice, fed in as the microphone
    /// at its own pace. The first is said 1 s in (a turn); the second 1.2 s into Otto's first answer (a cut-in).
    private func loadFake() {
        let a = ProcessInfo.processInfo.arguments
        guard fakeClips.isEmpty, let i = a.firstIndex(of: "-talkFakeVoice"), a.indices.contains(i + 1) else { return }
        fakeClips = a[i + 1].split(separator: ",").compactMap { path in
            guard let f = try? AVAudioFile(forReading: URL(filePath: String(path))),
                  let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)), (try? f.read(into: b)) != nil else { return nil }
            return b
        }
        fakeFed = fakeClips.map { _ in 0 }
    }

    private func feedFake() -> Float? {
        guard let f = fakeClips.first?.format else { return nil }
        let n = AVAudioFrameCount(f.sampleRate * 0.05)
        let t = Date.now.timeIntervalSince(started)
        // `-talkFakeAt 1,40`: each clip at that many seconds into the talk instead (a second turn, not a cut-in).
        let at = ProcessInfo.processInfo.arguments.firstIndex(of: "-talkFakeAt").map { i in ProcessInfo.processInfo.arguments[i + 1].split(separator: ",").compactMap { Double($0) } }
        let which = at.flatMap { at in fakeClips.indices.first { i in i < at.count && t >= at[i] && fakeFed[i] < fakeClips[i].frameLength } }
            ?? (at != nil ? nil
            : t >= 1 && fakeFed[0] < fakeClips[0].frameLength ? 0
            : fakeClips.count > 1 && firstSpoke.map { Date.now.timeIntervalSince($0) >= 1.2 } == true && fakeFed[1] < fakeClips[1].frameLength ? 1 : nil)
        guard let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n), let to = out.floatChannelData else { return nil }
        out.frameLength = n
        for c in 0..<Int(f.channelCount) { to[c].update(repeating: 0, count: Int(n)) }
        if let w = which, let from = fakeClips[w].floatChannelData {
            let k = min(n, fakeClips[w].frameLength - fakeFed[w])
            for c in 0..<Int(f.channelCount) { to[c].update(from: from[c] + Int(fakeFed[w]), count: Int(k)) }
            fakeFed[w] += k
        }
        tap.heard(out, fed: true)
        return TalkMic.rms(out)
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
    /// Reduce Motion: the ring holds still on its own (VoiceRingKit reads it) and doesn't lean; here, changes cross-fade instead of moving.
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
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Over the row, not in it: the row keeps its height as sharing comes and goes.
            .overlay(alignment: .trailing) { if session.sharing { sees } }
            .padding(.horizontal, 20).padding(.top, 12)

            Spacer(minLength: 12)
            VStack(spacing: 0) {
                ring
                words
                if working { work }
            }
            .animation(still ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0), value: working)
            Spacer(minLength: 12)

            controls
                .overlay(alignment: .top) {
                    // A zero-height frame on the controls' top edge, the note hanging up from it: never over the buttons.
                    if let note = session.shareNote { stopped(note).containerRelativeFrame(.horizontal).frame(height: 0, alignment: .bottom).offset(y: -20) }
                }
                .animation(.easeOut(duration: 0.2), value: session.shareNote)
                .padding(.bottom, 16)
        }
        .onChange(of: session.shareNote) { _, note in if let note { AccessibilityNotification.Announcement(note).post() } }
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
        return LeaningRing(state: state, source: .level { muted ? 0 : Double(min(1, (otto ? tap.playing : tap.level) * 8)) }, size: size)
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
            }
            // Your words as the Mac hears them, the newest in view; the last one is its guess until it settles.
            if let you = session.lines.last(where: { !$0.otto }), case let words = session.text(you.id), !words.isEmpty {
                Heard(text: words, settled: session.guessing != you.id).font(size: 20, relativeTo: .title3)
            } else if !session.cutIn {
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
            } else if session.missed {
                Text("Your Mac didn’t catch that. Say it again.").font(size: 20, relativeTo: .title3).foregroundStyle(.secondary)
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

    // MARK: Your screen

    /// While Otto sees your screen: says so at the top, and a tap stops it.
    private var sees: some View {
        Button { session.stopSharing() } label: {
            Label("Sees your screen", systemImage: "iphone")
                .font(size: 13, weight: .semibold, relativeTo: .footnote)
                .padding(.horizontal, 12).frame(height: 30)
                .background(.white.opacity(0.12), in: .capsule)
                .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.press)
        .accessibilityLabel("Otto sees your screen")
        .accessibilityHint("Stops sharing your screen.")
    }

    /// Why sharing just stopped, above the controls for a few seconds.
    private func stopped(_ note: String) -> some View {
        Label(note, systemImage: "iphone.slash")
            .font(size: 13, relativeTo: .footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .transition(.opacity)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 40) {
            let on = session.mic == .on
            TalkButton(symbol: session.muted ? "mic.slash.fill" : "mic.fill",
                       label: on ? (session.muted ? "Unmute" : "Mute") : "Mic off",
                       fill: session.muted ? .white : .white.opacity(0.16), tint: session.muted ? .black : .white) {
                session.muted.toggle()
            }
            .disabled(!on)
            .accessibilityAddTraits(session.muted ? .isSelected : [])
            let sharing = session.sharing, can = session.canShare
            TalkButton(symbol: "iphone", label: sharing ? "Sharing" : can ? "Share screen" : "Can’t share",
                       fill: sharing ? .white : .white.opacity(0.16), tint: sharing ? .black : .white) {
                if sharing { session.stopSharing() } else { session.share() }
            }
            .disabled(!sharing && !can)
            .accessibilityAddTraits(sharing ? .isSelected : [])
            .accessibilityHint(sharing ? "Stops sharing your screen." : can ? "Otto sees your screen while you talk." : "Your Mac can’t see your screen yet.")
            // The system's own picker over the circle, so a finger opens iOS's sheet with Otto picked.
            .overlay(alignment: .top) {
                if !sharing && can && !TalkSession.fakeScreen { BroadcastPicker().frame(width: 64, height: 64).accessibilityHidden(true) }
            }
            TalkButton(symbol: "xmark", label: "End", fill: .red, tint: .white) { session.end() }
        }
    }
}

/// The system's Start Broadcast button, preselected to Otto's extension, laid unseen over Share: iOS's sheet opens
/// for a touch on it or for its own button's action, not for an app's call.
/// How far the ring leans from how the phone has turned: the talk's start is the centre, and as the screen turns
/// away from you the ring leans back toward where you were. Pure, so `-approvalCheck` checks it.
enum RingLean {
    /// The turn that gives a clear lean (about three quarters of full); past it the lean saturates gently. Tune on a phone.
    static let reach = 20.0 * .pi / 180
    /// Seconds for the centre to catch up with how you hold the phone now (gyro drift, a shift in your seat). Tune on a phone.
    static let settle = 20.0
    /// How fast the ring travels to its lean and back, VoiceRingKit's `leanSpeed` (1 settles in about 2 s). Tune on a phone.
    static let speed = 2.5

    /// `turn` (radians about gravity, counter-clockwise from above: the screen facing more to your right) as the ring's
    /// direction, −1 left … 1 right. The ring leans the other way, back toward you.
    static func direction(_ turn: Double) -> Double { -tanh(turn / reach) }

    /// The turn from centre after `dt` seconds turning at `rate` rad/s, the centre easing toward the phone meanwhile.
    static func step(_ turn: Double, rate: Double, dt: Double) -> Double { (turn + rate * dt) * exp(-dt / settle) }
}

/// Talk's ring, leaning with the phone. Device motion runs only while the ring is on screen, the app is active and
/// Reduce Motion is off; it needs no permission. VoiceRingKit eases the lean itself (a critically damped spring), and
/// leans only while a voice is heard: in silence and while Otto thinks it drifts back to centre.
private struct LeaningRing: View {
    let state: VoiceState, source: VoiceSource, size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.scenePhase) private var scene
    @State private var tilt = Tilt()

    var body: some View {
        VoiceRing(.mono, state: state, source: source,
                  style: { var s = VoiceStyle(); s.theme = .dark; s.leanSpeed = RingLean.speed; return s }(),
                  direction: still ? nil : tilt.direction, size: size)
            .onAppear(perform: sync)
            .onDisappear { tilt.stop() }
            .onChange(of: scene) { sync() }
            .onChange(of: still) { sync() }
    }

    /// Back from the background, or Reduce Motion turned off: wherever the phone is now is the new centre.
    private func sync() { if scene == .active && !still { tilt.start() } else { tilt.stop() } }

    @MainActor @Observable final class Tilt {
        private(set) var direction = 0.0
        @ObservationIgnored private let motion = CMMotionManager()
        @ObservationIgnored private var turn = 0.0
        @ObservationIgnored private var last: TimeInterval?
        #if DEBUG
        @ObservationIgnored private var fake: Task<Void, Never>?
        #endif

        func start() {
            #if DEBUG
            if let degrees = Self.fakeTurn { return startFake(degrees) }
            #endif
            guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
            turn = 0; last = nil; direction = 0
            motion.deviceMotionUpdateInterval = 1.0 / 30
            motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
                guard let m else { return }
                MainActor.assumeIsolated { self?.read(m) }
            }
        }

        func stop() {
            motion.stopDeviceMotionUpdates()
            #if DEBUG
            fake?.cancel(); fake = nil
            #endif
        }

        /// The turn about gravity, from the gyro: the same whether the phone stands upright or lies flat, with none of
        /// Euler yaw's trouble when it stands upright. Tilting it sideways in your hand doesn't count.
        private func read(_ m: CMDeviceMotion) {
            let g = m.gravity, r = m.rotationRate, n = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
            let dt = last.map { min(0.1, max(0, m.timestamp - $0)) } ?? 0
            last = m.timestamp
            guard n > 0.1 else { return }
            turn = RingLean.step(turn, rate: -(r.x * g.x + r.y * g.y + r.z * g.z) / n, dt: dt)
            direction = RingLean.direction(turn)
        }

        #if DEBUG
        /// `-talkLean <degrees>|sweep`: the simulator has no gyro. A fixed turn (30 leans left, −30 right), or a slow
        /// sweep of ±30° every 8 s, fed in as the phone's turn.
        static let fakeTurn: Double? = {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-talkLean"), a.indices.contains(i + 1) else { return nil }
            return a[i + 1] == "sweep" ? .infinity : Double(a[i + 1])
        }()

        private func startFake(_ degrees: Double) {
            guard degrees.isFinite else {
                guard fake == nil else { return }
                let from = Date.now
                fake = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.direction = RingLean.direction(30 * .pi / 180 * sin(2 * .pi * Date.now.timeIntervalSince(from) / 8))
                        try? await Task.sleep(for: .milliseconds(33))
                    }
                }
                return
            }
            direction = RingLean.direction(degrees * .pi / 180)
        }
        #endif
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    @MainActor static weak var shown: RPSystemBroadcastPickerView?

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        p.preferredExtension = ScreenShare.extensionID
        p.showsMicrophoneButton = false
        p.alpha = 0.02   // unseen, and still touched: UIKit stops hit-testing a view below 0.01
        Self.shown = p
        return p
    }

    func updateUIView(_ p: RPSystemBroadcastPickerView, context: Context) {}

    /// Its button's action, for VoiceOver's activate and the label under the circle, which land on Share instead.
    @MainActor static func open() { for case let b as UIButton in shown?.subviews ?? [] { b.sendActions(for: .touchUpInside) } }
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

/// Your words while you talk: the newest in view (a long turn loses its first words here, never in the transcript),
/// the last one dimmed while it's still the Mac's guess.
private struct Heard: View {
    let text: String
    let settled: Bool
    var body: some View {
        let shown = Self.tail(text)
        let cut = settled ? shown.endIndex : (shown.lastIndex(of: " ").map { shown.index(after: $0) } ?? shown.startIndex)
        Text("\(Text(shown[..<cut]))\(Text(shown[cut...]).foregroundStyle(.secondary))")
            .lineLimit(4)
            .truncationMode(.head)   // at large type four lines hold less: what goes is the oldest words, never the newest
            .accessibilityLabel("You: \(text)")
    }

    /// The last ~160 characters, from a word's start.
    static func tail(_ text: String, _ n: Int = 160) -> String {
        guard text.count > n else { return text }
        let from = text.index(text.endIndex, offsetBy: -n)
        let start = text[from...].firstIndex(of: " ").map { text.index(after: $0) } ?? from
        return "…" + text[start...]
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
