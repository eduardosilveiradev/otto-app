import AVFoundation
import Speech
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The microphone half of the Otto keyboard's dictation (the keyboard can't record; see
/// Shared/DictationBridge.swift). The keyboard opens `otto://dictate` the first time, the
/// app starts listening, and they go back to where they were typing. The app stays warm
/// for `warmFor` afterwards, so the next dictations start without leaving the keyboard.
///
/// Cleanup is Gaithano Speak's on the Mac (`/app/dictate`); when the Mac can't answer, the
/// phone's own recognizer and Apple Intelligence do it with the same prompt.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()
    static var active: Bool { shared.engine.isRunning }
    // ponytail: one fixed warm window; the orange mic dot stays on for it, so keep it short.
    static let warmFor: TimeInterval = 180

    @Published var phase: DictationBridge.State.Phase = .idle
    @Published var showListening = false
    @Published var level: Float = 0

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var request: DictationBridge.Request?
    private var warmUntil = Date.distantPast
    private var heartbeat: Timer?

    func setUp() {
        DictationBridge.observe(DictationBridge.toApp) { [weak self] in self?.handleRequest() }
    }

    /// `otto://dictate`: the keyboard couldn't reach a warm app, so it opened this one.
    func openedFromKeyboard() {
        showListening = true
        handleRequest()
    }

    private func handleRequest() {
        guard let r = DictationBridge.readRequest() else { return }
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
                try warmUp()
                let url = FileManager.default.temporaryDirectory.appending(path: "dictation-\(r.id).m4a")
                let input = engine.inputNode.outputFormat(forBus: 0)
                file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.sampleRate,
                    AVNumberOfChannelsKey: input.channelCount, AVEncoderBitRateKey: 48_000,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                fileURL = url
                publish(.listening)
            } catch {
                publish(.failed, text: "Couldn't start the microphone.")
            }
        }
    }

    private func warmUp() throws {
        warmUntil = Date().addingTimeInterval(Self.warmFor)
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
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

    /// Tells the keyboard the app can start without being opened, and cools down when idle long enough.
    private func beat() {
        if file == nil, Date() > warmUntil { return coolDown() }
        var s = DictationBridge.readState()
        s.alive = Date().timeIntervalSince1970
        s.level = level
        DictationBridge.write(s)
        if file != nil { DictationBridge.post(DictationBridge.toKeyboard) }
    }

    private func coolDown() {
        heartbeat?.invalidate()
        heartbeat = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        var s = DictationBridge.readState()
        s.alive = 0
        DictationBridge.write(s)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Keepalive.update(background: UIApplication.shared.applicationState != .active)
    }

    private func stop() {
        guard let url = fileURL, let r = request else { return }
        file = nil            // closes the file
        fileURL = nil
        warmUntil = Date().addingTimeInterval(Self.warmFor)
        publish(.working)
        Task {
            let text = await Self.transcribe(url, preceding: r.preceding, langs: r.langs)
            try? FileManager.default.removeItem(at: url)
            if let text, !text.isEmpty { publish(.done, text: text) } else { publish(.failed, text: "Didn't catch that.") }
            showListening = false
        }
    }

    private func cancel() {
        file = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        publish(.idle)
        showListening = false
    }

    private func publish(_ p: DictationBridge.State.Phase, text: String? = nil) {
        phase = p
        DictationBridge.write(.init(phase: p, id: request?.id, text: text, level: level,
                                    alive: engine.isRunning ? Date().timeIntervalSince1970 : 0))
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
                    Capsule().fill(Color.orange)
                        .frame(width: 5, height: 8 + CGFloat(d.level) * 46 * CGFloat(0.4 + 0.6 * abs(sin(Double(i) * 0.9))))
                }
            }
            .frame(height: 56)
            .animation(.easeOut(duration: 0.12), value: d.level)
            Text("Go back to where you were typing and keep talking. Tap the keyboard's mic to finish.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
            Button("Stop") {
                DictationBridge.write(.init(action: .stop, id: DictationBridge.readRequest()?.id ?? ""))
                DictationBridge.post(DictationBridge.toApp)
            }
            .buttonStyle(.borderedProminent).tint(.orange).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }
}
