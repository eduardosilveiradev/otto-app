import AVFoundation
import Speech
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The microphone half of the Otto keyboard's dictation (the keyboard can't record; see
/// Shared/DictationBridge.swift). The keyboard opens `otto://dictate`, the app starts
/// listening, and they go back to where they were typing. The microphone and the audio
/// session are held only while a dictation records: `begin()` takes them, `end()` gives
/// them back, and every way a dictation finishes goes through `end()`.
///
/// Cleanup is Gaithano Speak's on the Mac (`/app/dictate`); when the Mac can't answer, the
/// phone's own recognizer and Apple Intelligence do it with the same prompt.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()
    static var active: Bool { shared.engine.isRunning }

    @Published var phase: DictationBridge.State.Phase = .idle
    @Published var showListening = false
    @Published var level: Float = 0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var request: DictationBridge.Request?
    private var heartbeat: Timer?
    /// The session as it was before `begin()`; non-nil exactly while dictation holds it.
    private var prior: (category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions)?
    private var started = Date.distantPast
    /// Last time the keyboard (or Otto's own listening screen) was in front of someone.
    private var seen = Date.distantPast

    func setUp() {
        DictationBridge.observe(DictationBridge.toApp) { [weak self] in self?.handleRequest() }
        DictationBridge.observe(DictationBridge.seen) { [weak self] in self?.seen = Date() }
    }

    /// `otto://dictate`: the keyboard opened this app to start listening.
    func openedFromKeyboard() {
        showListening = true
        handleRequest()
    }

    private func handleRequest() {
        // Nothing to act on: the listening screen (openedFromKeyboard puts it up first) mustn't be left with no way out.
        guard let r = DictationBridge.readRequest() else { showListening = false; return }
        switch r.action {
        case .start: start(r)
        case .stop: stop()
        case .cancel: cancel()
        }
    }

    // MARK: recording

    private func start(_ r: DictationBridge.Request) {
        guard file == nil else { return }
        request = r
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { return publish(.failed, text: "Otto needs the microphone.") }
            do {
                try begin()
                let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(r.id).m4a")
                let input = engine.inputNode.outputFormat(forBus: 0)
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.sampleRate,
                    AVNumberOfChannelsKey: input.channelCount, AVEncoderBitRateKey: 48_000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                fileURL = url
                publish(.listening)
            } catch {
                end()
                publish(.failed, text: "Couldn’t start the microphone.")
            }
        }
    }

    /// The only place dictation takes the audio session and the microphone.
    private func begin() throws {
        guard prior == nil else { return }
        let s = AVAudioSession.sharedInstance()
        prior = (s.category, s.mode, s.categoryOptions)
        // Record only: with no output side, Otto changes nothing about where other audio plays or how loud.
        // Other audio pauses while the mic is on; `end()` tells it to resume. HFP so AirPods' mics work.
        try s.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try s.setActive(true)
        started = Date()
        seen = started
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 2048, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            let peak = (0..<Int(buf.frameLength)).reduce(Float(0)) { max($0, abs(buf.floatChannelData![0][$1])) }
            DispatchQueue.main.async {
                guard let self, let f = self.file else { return }
                try? f.write(from: buf)
                self.level = min(1, peak * 3)
            }
        }
        try engine.start()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        beat()
    }

    /// The only place dictation gives the session and the microphone back. Safe to call twice.
    private func end() {
        guard let prior else { return }
        self.prior = nil
        heartbeat?.invalidate()
        heartbeat = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()   // before deactivating: a session with I/O still running won't let go
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        try? s.setCategory(prior.category, mode: prior.mode, options: prior.options)
        Keepalive.update(background: UIApplication.shared.applicationState == .background)
    }

    /// Feeds the keyboard's level meter, and finishes a recording nobody is attending to.
    private func beat() {
        let now = Date()
        if UIApplication.shared.applicationState != .background { seen = now }
        if DictationBridge.shouldEnd(now: now, started: started, seen: seen, micRunning: engine.isRunning) { return stop() }
        var s = DictationBridge.readState()
        s.level = level
        DictationBridge.write(s)
        DictationBridge.post(DictationBridge.toKeyboard)
    }

    private func stop() {
        end()
        guard let url = fileURL, let r = request else { showListening = false; return }   // nothing was recording: the screen goes all the same
        file = nil            // closes the file
        fileURL = nil
        publish(.working)
        Task {
            let text = await Self.transcribe(url, preceding: r.preceding, langs: r.langs)
            try? FileManager.default.removeItem(at: url)
            if let text, !text.isEmpty { publish(.done, text: text) } else { publish(.failed, text: "Didn’t catch that.") }
            showListening = false
        }
    }

    private func cancel() {
        end()
        file = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        publish(.idle)
        showListening = false
    }

    /// The listening screen's own way out, whatever state the recording is in.
    func close() { cancel() }

    private func publish(_ p: DictationBridge.State.Phase, text: String? = nil) {
        phase = p
        if p == .failed { showListening = false }   // the microphone refused or wouldn't start: no screen to be stuck on
        DictationBridge.write(.init(phase: p, id: request?.id, text: text, level: level))
        DictationBridge.post(DictationBridge.toKeyboard)
    }

    // MARK: text

    /// Gaithano Speak on the Mac first; this phone's recognizer and model when that fails.
    static func transcribe(_ url: URL, preceding: String, langs: [String]) async -> String? {
        if let t = await viaMac(url, preceding: preceding) { return t }
        guard let raw = await onDevice(url, lang: langs.first ?? "en"), !raw.isEmpty else { return nil }
        return await cleanUp(raw, preceding: preceding) ?? raw
    }

    private static func viaMac(_ url: URL, preceding: String) async -> String? {
        guard let (base, token) = ShareDirect.load(), let audio = try? Data(contentsOf: url) else { return nil }
        var c = URLComponents(url: base.appending(path: "app/dictate"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "preceding", value: String(preceding.suffix(200)))]
        var req = URLRequest(url: c.url!, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        guard let (data, resp) = try? await URLSession.shared.upload(for: req, from: audio),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["text"] as? String
    }

    private static func onDevice(_ url: URL, lang: String) async -> String? {
        let locale = Locale(identifier: ["en": "en-US", "it": "it-IT", "pt": "pt-BR"][lang] ?? "en-US")
        guard await withCheckedContinuation({ k in SFSpeechRecognizer.requestAuthorization { k.resume(returning: $0 == .authorized) } }),
              let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.addsPunctuation = true
        return await withCheckedContinuation { k in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal { done = true; k.resume(returning: result.bestTranscription.formattedString) }
                else if error != nil { done = true; k.resume(returning: nil) }
            }
        }
    }

    private static func cleanUp(_ raw: String, preceding: String) async -> String? {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: DictationPrompt.instructions)
        let out = try? await session.respond(to: DictationPrompt.prompt(for: raw, preceding: preceding)).content
        return out?.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return nil
        #endif
    }
}

/// Puts the listening screen up while the keyboard's dictation needs the app in front.
struct DictationCover: ViewModifier {
    @ObservedObject var d = Dictation.shared
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $d.showListening) { DictationListeningView() }
    }
}

/// Shown when the keyboard opened the app to start listening: say so, and send them back.
struct DictationListeningView: View {
    @ObservedObject var d = Dictation.shared

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            OttoAvatar(size: 96, thinking: d.phase == .working)
            Text(d.phase == .working ? "Cleaning it up…" : "Listening").font(.title2.weight(.semibold))
            HStack(spacing: 4) {
                ForEach(0..<14, id: \.self) { i in
                    Capsule().fill(Color.primary)
                        .frame(width: 5, height: 8 + CGFloat(d.level) * 46 * CGFloat(0.4 + 0.6 * abs(sin(Double(i) * 0.9))))
                }
            }
            .frame(height: 56)
            .animation(.easeOut(duration: 0.12), value: d.level)
            Text("Go back to where you were typing and keep talking. Tap the keyboard’s mic to finish.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
            Button {
                DictationBridge.write(.init(action: .stop, id: DictationBridge.readRequest()?.id ?? ""))
                DictationBridge.post(DictationBridge.toApp)
            } label: {
                Text("Stop")
            }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            Button("Close") { d.close() }.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}
