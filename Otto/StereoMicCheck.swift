#if DEBUG
import AVFoundation
import AudioToolbox
import SwiftUI

/// Runs on its own launch screen so there is no Talk session, store, or server connection.
@MainActor
struct StereoMicCheck: View {
    static let requested = CommandLine.arguments.contains("-stereoMicCheck")

    @State private var check = MicExperiment()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Keep the iPhone upright, facing you, with headphones disconnected. Set speaker volume near halfway and leave it there.")
                    Text(check.instruction)
                        .font(.headline)
                    Button(check.buttonTitle) { check.advance() }
                        .disabled(check.busy)
                    if check.hasEngine {
                        Button("Stop current test", role: .cancel) { check.stop() }
                    }
                } header: {
                    Text(check.test?.title ?? "Measurement complete")
                }
                if !check.live.isEmpty {
                    Section("Live input") {
                        Text(check.live).monospacedDigit()
                            .accessibilityHidden(check.busy)
                    }
                }
                if !check.report.isEmpty {
                    Section("Results") {
                        ShareLink(item: check.export) { Label("Share text report", systemImage: "square.and.arrow.up") }
                        Button("Copy text report") { UIPasteboard.general.string = check.export }
                        Text(check.report)
                            .font(.footnote.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Microphone check")
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { check.stop() }
        }
        .task {
            #if targetEnvironment(simulator)
            if CommandLine.arguments.contains("-runStereoMicCheck") {
                MicReading.selfCheck()
                while check.test != nil && !Task.isCancelled {
                    await check.step()
                }
                if check.test == nil { FileHandle.standardError.write(Data("StereoMicCheck: simulator run complete\n".utf8)) }
            }
            #endif
        }
    }
}

@MainActor
@Observable private final class MicExperiment {
    enum Test: String, CaseIterable {
        case talk = "Talk baseline"
        case stereoVoice = "Talk with stereo requested"
        case bypass = "Voice I/O with bypass and stereo requested"
        case stereo = "Stereo without echo cancellation"
        case echo = "Stereo with session echo cancellation"
        case parallel = "Talk plus a second input engine"
        case parallelStereo = "Talk plus a second engine with stereo requested"

        var title: String { rawValue }
        var usesVoiceIO: Bool { self != .stereo && self != .echo }
        var asksForStereo: Bool { self != .talk && self != .parallel && self != .parallelStereo }
    }

    enum Phase: String, CaseIterable {
        case quiet = "Quiet"
        case speaker = "Speaker only"
        case left = "Voice left"
        case right = "Voice right"

        var instruction: String {
            switch self {
            case .quiet: "Stay silent. The speaker will be quiet."
            case .speaker: "Stay silent while the speaker plays."
            case .left: "Speak from the left, about 30 cm away, until the next prompt appears."
            case .right: "Repeat the same words from the right at the same distance until the next prompt appears."
            }
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var second: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var stereoSource: AVAudioSessionDataSourceDescription?
    private var requestedChannels = false
    private var task: Task<Void, Never>?
    private var run = UUID()
    private var testIndex = 0
    private var phaseIndex = 0
    private var primary = MicStats()
    private var secondary = MicStats()
    private var measuring = false
    private var details: [String] = []

    private(set) var report = ""
    private(set) var live = ""
    private(set) var busy = false
    var hasEngine: Bool { engine != nil }
    var test: Test? { Test.allCases.indices.contains(testIndex) ? Test.allCases[testIndex] : nil }
    private var phase: Phase { Phase.allCases[phaseIndex] }
    var instruction: String {
        guard test != nil else { return "Copy or share the report." }
        return hasEngine ? phase.instruction : "Start this configuration, then follow the four recording prompts."
    }
    var buttonTitle: String {
        if busy { return "Measuring…" }
        if test == nil { return "Start over" }
        return hasEngine ? "Record \(phase.rawValue.lowercased())" : "Start configuration"
    }
    var export: String {
        var info = utsname()
        uname(&info)
        let hardware = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware
        return "Otto microphone check · \(model) · iOS \(UIDevice.current.systemVersion) · \(Date.now.formatted())\nSpeaker signal: 701 Hz + 1237 Hz, −18.9 dBFS RMS\n\n" + report
    }

    func advance() {
        if test == nil {
            report = ""
            live = ""
            testIndex = 0
            return
        }
        busy = true
        task = Task { await step() }
    }

    func step() async {
        guard let test else { return }
        busy = true
        let token = run
        defer { if run == token { busy = false } }
        do {
            if engine == nil {
                let allowed = await AVAudioApplication.requestRecordPermission()
                guard run == token else { return }
                guard allowed else { throw Failure("Microphone permission denied") }
                try await start(test)
                return
            }
            let current = phase
            let tone = current != .quiet
            if tone, engine?.isRunning == true, let player, !player.isPlaying { play(on: player) }
            if tone {
                // Give the engine and echo canceller time to settle before measuring.
                try await Task.sleep(for: .seconds(1))
            }
            primary = MicStats()
            secondary = MicStats()
            measuring = true
            try await Task.sleep(for: .seconds(3))
            measuring = false
            let output = engine?.isRunning == true && player?.isPlaying == true
            var result = "\(current.rawValue) · primary \(primary.summary)"
            result += " · \(primary.wireFrames) frames converted to 16 kHz mono"
            if second != nil { result += "\n  Second input · \(secondary.summary)" }
            if tone { result += "\n  Speaker playback running: \(output)" }
            result += "\n  Route: \(route)"
            if test == .echo { result += " · session echo enabled: \(session.isEchoCancelledInputEnabled)" }
            add(result)
            phaseIndex += 1
            if phaseIndex == Phase.allCases.count { finish() }
        } catch is CancellationError {
            return
        } catch {
            add("\(test.title) · refused · \(describe(error))\n\(details.joined(separator: "\n"))")
            finish()
        }
    }

    func stop() {
        guard engine != nil || busy else { return }
        task?.cancel()
        add("Stopped before completing \(test?.title ?? "the test").")
        finish()
    }

    private func finish() {
        measuring = false
        run = UUID()
        player?.stop()
        second?.stop()
        engine?.stop()
        player = nil
        second = nil
        engine = nil
        if let stereoSource {
            try? stereoSource.setPreferredPolarPattern(nil)
            try? session.currentRoute.inputs.first?.setPreferredDataSource(nil)
            self.stereoSource = nil
        }
        if requestedChannels {
            try? session.setPreferredInputNumberOfChannels(1)
            requestedChannels = false
        }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        details = []
        phaseIndex = 0
        testIndex += 1
        busy = false
        live = ""
    }

    private func start(_ test: Test) async throws {
        // Clear the session-scoped preference in a mode that supports it.
        try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
        if session.prefersEchoCancelledInput { try session.setPrefersEchoCancelledInput(false) }
        if test.usesVoiceIO {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        } else if test == .echo {
            attempt("Session echo cancellation preference") {
                guard session.isEchoCancelledInputAvailable else { throw Failure("Unavailable for this device or configuration") }
                try session.setPrefersEchoCancelledInput(true)
            }
        }
        try session.setActive(true)
        if test == .bypass { details.append(Self.voiceIOFormats(sessionRate: session.sampleRate)) }
        let e = AVAudioEngine()
        engine = e
        if test.usesVoiceIO { try e.inputNode.setVoiceProcessingEnabled(true) }
        if test == .bypass { e.inputNode.isVoiceProcessingBypassed = true }
        if test.asksForStereo { askForStereo() }

        let speaker = AVAudioPlayerNode()
        player = speaker
        e.attach(speaker)
        e.connect(speaker, to: e.mainMixerNode, format: Self.toneFormat)
        var initial = try startInput(e, isSecond: false)
        // The initial route negotiation can stop the engine. Settle it before starting a contender.
        let token = run
        try await Task.sleep(for: .milliseconds(350))
        guard token == run else { throw CancellationError() }
        if !e.isRunning {
            details.append("Primary stopped during initial route setup. Retrying once.")
            e.inputNode.removeTap(onBus: 0)
            initial = try startInput(e, isSecond: false)
            try await Task.sleep(for: .milliseconds(350))
            guard token == run else { throw CancellationError() }
        }
        guard e.isRunning else { throw Failure("Primary stopped after route setup and retry") }
        details.append("Primary started · \(Self.describe(initial)) · voice I/O \(e.inputNode.isVoiceProcessingEnabled), bypass \(e.inputNode.isVoiceProcessingBypassed)")
        if test == .echo {
            details.append("Session echo available: \(session.isEchoCancelledInputAvailable) · enabled: \(session.isEchoCancelledInputEnabled)")
        }
        if test == .parallel || test == .parallelStereo {
            if test == .parallelStereo {
                askForStereo()
                try await Task.sleep(for: .milliseconds(350))
                guard token == run else { throw CancellationError() }
                details.append("After stereo request, before second start · primary running \(e.isRunning) · \(Self.describe(e.inputNode.outputFormat(forBus: 0)))")
            }
            attempt("Second engine") {
                let extra = AVAudioEngine()
                second = extra
                let format = try startInput(extra, isSecond: true)
                details.append("Second started · \(Self.describe(format)) · voice I/O \(extra.inputNode.isVoiceProcessingEnabled)")
            }
            try await Task.sleep(for: .milliseconds(350))
            guard token == run else { throw CancellationError() }
            details.append("After second start · primary running \(e.isRunning) · \(Self.describe(e.inputNode.outputFormat(forBus: 0))) · second running \(second?.isRunning == true)")
        }
        let input = session.currentRoute.inputs.first
        details.append("Route: \(route) · \(session.inputNumberOfChannels)/\(session.maximumInputNumberOfChannels) input channels · \(session.sampleRate) Hz")
        details.append("Data source: \(input?.selectedDataSource?.dataSourceName ?? "none") · pattern: \(input?.selectedDataSource?.selectedPolarPattern?.rawValue ?? "none") · orientation: \(session.inputOrientation.rawValue)")
        add("\(test.title) · engine accepted\n\(details.joined(separator: "\n"))")
    }

    private static func voiceIOFormats(sessionRate: Double) -> String {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return "VoiceProcessingIO unavailable" }
        var instance: AudioUnit?
        let created = AudioComponentInstanceNew(component, &instance)
        guard let unit = instance else { return "VoiceProcessingIO creation OSStatus \(created)" }
        defer { AudioComponentInstanceDispose(unit) }
        var enabled: UInt32 = 1
        let enableStatus = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                               1, &enabled, UInt32(MemoryLayout<UInt32>.size))
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let hardware = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size)
        let hardwareDescription = "\(format.mChannelsPerFrame) ch / \(format.mSampleRate) Hz (OSStatus \(hardware))"
        let client = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &size)
        let clientDescription = "\(format.mChannelsPerFrame) ch / \(format.mSampleRate) Hz (OSStatus \(client))"
        let rate = format.mSampleRate > 0 ? format.mSampleRate : sessionRate
        guard enableStatus == noErr, client == noErr, rate > 0,
              let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        else { return "VoiceProcessingIO input enable OSStatus \(enableStatus) · hardware \(hardwareDescription) · client \(clientDescription)" }
        var stereoFormat = stereo.streamDescription.pointee
        let set = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &stereoFormat, size)
        let initialize = set == noErr ? AudioUnitInitialize(unit) : set
        var result = "VoiceProcessingIO · hardware \(hardwareDescription) · client \(clientDescription) · stereo client at \(Int(rate)) Hz set OSStatus \(set) · initialize \(set == noErr ? String(initialize) : "skipped")"
        if initialize == noErr {
            let readback = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &size)
            result += " · initialized client \(format.mChannelsPerFrame) ch / \(format.mSampleRate) Hz (OSStatus \(readback))"
            AudioUnitUninitialize(unit)
        }
        return result
    }

    private func askForStereo() {
        attempt("Built-in stereo polar pattern") {
            guard let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                throw Failure("No built-in mic on this route")
            }
            try session.setPreferredInput(mic)
            let sources = mic.dataSources?.filter { $0.supportedPolarPatterns?.contains(.stereo) == true } ?? []
            guard let source = sources.first(where: { $0.orientation == .front }) ?? sources.first else {
                throw Failure("No data source advertises stereo")
            }
            try source.setPreferredPolarPattern(.stereo)
            stereoSource = source
            try mic.setPreferredDataSource(source)
            try session.setPreferredInputOrientation(.portrait)
        }
        attempt("Two input channels") {
            try session.setPreferredInputNumberOfChannels(2)
            requestedChannels = true
        }
    }

    private func startInput(_ e: AVAudioEngine, isSecond: Bool) throws -> AVAudioFormat {
        let node = e.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure("Invalid input format \(format)") }
        let token = run
        // Match Talk's first-channel PCM conversion, entirely in memory.
        let converter = !isSecond ? AVAudioConverter(from: format, to: TalkMic.wire) : nil
        converter?.channelMap = [0]
        node.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap(converter) { [weak self] reading, wireFrames in
            guard let self, self.run == token else { return }
            if isSecond {
                if self.measuring { self.secondary.add(reading) }
            } else {
                if self.measuring {
                    self.primary.add(reading)
                    self.primary.wireFrames += wireFrames
                }
                self.live = reading.live
            }
        })
        e.prepare()
        try e.start()
        return node.outputFormat(forBus: 0)
    }

    private nonisolated static func tap(
        _ converter: AVAudioConverter?,
        _ receive: @escaping @MainActor (MicReading, Int) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let reading = MicReading(buffer) else { return }
            var wireFrames = 0
            if let converter,
               let converted = AVAudioPCMBuffer(pcmFormat: TalkMic.wire, frameCapacity: AVAudioFrameCount(Double(reading.frames) * 16000 / reading.rate) + 64) {
                var supplied = false
                let status = converter.convert(to: converted, error: nil) { _, inputStatus in
                    inputStatus.pointee = supplied ? .noDataNow : .haveData
                    if supplied { return nil }
                    supplied = true
                    return buffer
                }
                if status != .error { wireFrames = Int(converted.frameLength) }
            }
            let outputCount = wireFrames
            Task { @MainActor in receive(reading, outputCount) }
        }
    }

    private static let toneFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    private func play(on player: AVAudioPlayerNode) {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.toneFormat, frameCapacity: 48000)!
        buffer.frameLength = 48000
        let samples = buffer.floatChannelData![0]
        for i in 0..<48000 {
            let time = 2 * Double.pi * Double(i) / 48000
            samples[i] = Float(0.1135 * (sin(701 * time) + sin(1237 * time)))
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
    }

    private var route: String {
        let route = session.currentRoute
        return "\(route.inputs.map(\.portType.rawValue).joined(separator: ", ")) → \(route.outputs.map(\.portType.rawValue).joined(separator: ", ")) · volume \(Int(session.outputVolume * 100))%"
    }

    private func attempt(_ name: String, _ operation: () throws -> Void) {
        do {
            try operation()
            details.append("\(name) · accepted")
        } catch {
            details.append("\(name) · refused · \(describe(error))")
        }
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(format.channelCount) ch @ \(Int(format.sampleRate)) Hz · \(format.commonFormat == .pcmFormatFloat32 ? "Float32" : "PCM format \(format.commonFormat.rawValue)") · \(format.isInterleaved ? "interleaved" : "noninterleaved")"
    }

    private func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        let error = error as NSError
        return "\(error.domain) \(error.code) · \(error.localizedDescription)"
    }

    private func add(_ line: String) {
        FileHandle.standardError.write(Data("StereoMicCheck: \(line)\n".utf8))
        report += report.isEmpty ? line : "\n\n" + line
    }

    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}

private struct MicReading: Sendable {
    let channels: Int
    let rate: Double
    let frames: Int
    let left: Double
    let right: Double
    let tone: Double
    let lag: Double?

    init?(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        channels = Int(buffer.format.channelCount)
        rate = buffer.format.sampleRate
        frames = Int(buffer.frameLength)
        let stride = buffer.stride
        let l = data[0]
        let r = data[channels > 1 ? 1 : 0]
        var powerL = 0.0, powerR = 0.0
        for i in 0..<frames {
            let a = Double(l[i * stride]), b = Double(r[i * stride])
            powerL += a * a
            powerR += b * b
        }
        left = powerL / Double(frames)
        right = powerR / Double(frames)
        tone = max(Self.tonePower(l, stride, frames, rate), Self.tonePower(r, stride, frames, rate))

        // ponytail: integer-sample cross-correlation near zero estimates delay. Refine only if device
        // tests show a useful stereo signal with arrival differences smaller than one sample.
        let limit = Int(rate * 0.0007)
        if channels > 1, min(left, right) > 1e-7, frames > 2 * limit + 16 {
            var best = -Double.infinity
            var delay = 0
            for delta in -limit...limit {
                var dot = 0.0, p = 0.0, q = 0.0
                for i in Swift.stride(from: limit, to: frames - limit, by: 4) {
                    let a = Double(l[i * stride] - l[(i - 1) * stride])
                    let j = i + delta
                    guard j > 0 else { continue }
                    let b = Double(r[j * stride] - r[(j - 1) * stride])
                    dot += a * b
                    p += a * a
                    q += b * b
                }
                let correlation = dot / max(sqrt(p * q), 1e-12)
                if correlation > best || (correlation == best && abs(delta) < abs(delay)) {
                    best = correlation
                    delay = delta
                }
            }
            lag = best >= 0.55 ? Double(delay) * 1000 / rate : nil
        } else {
            lag = nil
        }
    }

    private static func tonePower(_ samples: UnsafePointer<Float>, _ stride: Int, _ frames: Int, _ rate: Double) -> Double {
        // Goertzel at the two emitted frequencies. Report the stronger input channel.
        [701.0, 1237.0].reduce(0) { sum, frequency in
            let coefficient = 2 * cos(2 * .pi * frequency / rate)
            var previous = 0.0, older = 0.0
            for i in 0..<frames {
                let next = Double(samples[i * stride]) + coefficient * previous - older
                older = previous
                previous = next
            }
            return sum + 2 * max(previous * previous + older * older - coefficient * previous * older, 0)
                / (Double(frames) * Double(frames))
        }
    }

    #if targetEnvironment(simulator)
    static func selfCheck() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        let data = buffer.floatChannelData!
        for i in 0..<4800 {
            let t = 2 * Double.pi * Double(i) / 48000
            data[0][i] = Float(0.1135 * (sin(701 * t) + sin(1237 * t)))
        }
        for i in 0..<4800 { data[1][i] = i >= 8 ? data[0][i - 8] / 2 : 0 }
        let reading = MicReading(buffer)!
        assert(abs(db(reading.left) - db(reading.right) - 6) < 0.2)
        assert(abs(db(reading.tone) + 18.9) < 0.3)
        assert(abs((reading.lag ?? 0) - 1.0 / 6) < 0.001)
        print("StereoMicCheck: measurement self-check passed")
    }
    #endif

    var live: String {
        let difference = channels > 1 ? " · L−R \(String(format: "%+.1f", db(left) - db(right))) dB" : ""
        return "\(channels) ch · \(Int(rate)) Hz\(difference)\nSpeaker frequencies \(String(format: "%.1f", db(tone))) dBFS"
    }
}

private struct MicStats {
    var wireFrames = 0
    private var formats: Set<String> = []
    private var frames = 0
    private var seconds = 0.0
    private var left = 0.0
    private var right = 0.0
    private var tone = 0.0
    private var stereoFrames = 0
    private var delays: [Double] = []

    mutating func add(_ reading: MicReading) {
        formats.insert("\(reading.channels) ch @ \(Int(reading.rate)) Hz")
        frames += reading.frames
        seconds += Double(reading.frames) / reading.rate
        left += reading.left * Double(reading.frames)
        right += reading.right * Double(reading.frames)
        tone += reading.tone * Double(reading.frames)
        if reading.channels > 1 { stereoFrames += reading.frames }
        if let lag = reading.lag { delays.append(lag) }
    }

    var summary: String {
        guard frames > 0 else { return "no input buffers" }
        let count = Double(frames)
        let louder = db(max(left, right) / count)
        let leak = db(tone / count)
        var text = String(format: "%@ · %.2f s of buffers · input %.1f dBFS RMS · speaker frequencies %.1f dBFS",
                          formats.sorted().joined(separator: ", "), seconds, louder, leak)
        if stereoFrames == frames {
            text += String(format: " · L−R %+.1f dB", db(left / count) - db(right / count))
            let sorted = delays.sorted()
            if sorted.isEmpty {
                text += " · delay unavailable"
            } else {
                text += String(format: " · right delay %+.3f ms (%d correlated buffers)", sorted[sorted.count / 2], sorted.count)
            }
        }
        return text
    }
}

private func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-12)) }
#endif
