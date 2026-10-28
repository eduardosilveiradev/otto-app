import CoreMedia
import MWDATCamera
import MWDATCore
import SwiftUI

/// The Ray-Ban Meta camera, live: a preview here, and each frame the network can take POSTed as a
/// JPEG to `glassesReceiver` + /frame on the Mac, with its capture time on the glasses' clock in
/// X-Capture-Time (seconds). A frame that arrives while
/// the last one is still uploading is dropped, so a slow link lowers the rate instead of lagging.
@MainActor @Observable
final class Glasses {
    static let shared = Glasses()
    var registration: RegistrationState = Wearables.shared.registrationState
    var stream: StreamState = .stopped
    var frame: UIImage?
    var sent = 0
    var error: String?
    private(set) var session: DeviceSession?
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var posting = false
    @ObservationIgnored private let tokens = ListenerTokenBag()

    private init() {
        Task { for await r in Wearables.shared.registrationStateStream() { registration = r } }
    }

    /// Hands over to the Meta AI app, which comes back through otto://…?metaWearablesAction=….
    func register() async {
        do { try await Wearables.shared.startRegistration() } catch { self.error = error.localizedDescription }
    }

    func start() async {
        guard session == nil else { return }
        error = nil
        do {
            let s = try Wearables.shared.createSession(deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))
            session = s
            s.statePublisher.listen { [weak self] st in Task { @MainActor in if st == .stopped { self?.ended() } } }.store(in: tokens)
            s.errorPublisher.listen { [weak self] e in Task { @MainActor in self?.error = e.localizedDescription } }.store(in: tokens)
            try s.start()
            for await st in s.stateStream() where st == .started || st == .stopped { break }
            guard s.state == .started else { return ended() }
            // Asked only once a device is connected; the first time this opens Meta AI.
            if try await Wearables.shared.checkPermissionStatus(.camera) != .granted,
               try await Wearables.shared.requestPermission(.camera) != .granted {
                error = "Camera access was refused in Meta AI."
                return stop()
            }
            // .low is 360×640, already the size the Mac wants, so frames go out unscaled.
            guard let cam = try s.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 15)) else {
                error = "The glasses didn't offer a camera."
                return stop()
            }
            camera = cam
            cam.stream.statePublisher.listen { [weak self] st in Task { @MainActor in self?.stream = st } }.store(in: tokens)
            cam.stream.errorPublisher.listen { [weak self] e in Task { @MainActor in self?.error = e.localizedDescription } }.store(in: tokens)
            cam.stream.videoFramePublisher.listen { [weak self] f in
                guard let image = f.makeUIImage() else { return }
                let at = CMSampleBufferGetPresentationTimeStamp(f.sampleBuffer).seconds
                Task { @MainActor in self?.show(image, at: at) }
            }.store(in: tokens)
            cam.stream.start()
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    /// Stopping the session stops the camera with it; `ended` tidies up when it reports .stopped.
    func stop() {
        guard let session else { return ended() }
        session.stop()
    }

    private func ended() {
        tokens.clear()
        camera = nil
        session = nil
        stream = .stopped
        frame = nil
    }

    private func show(_ image: UIImage, at: Double) {
        frame = image
        guard !posting, let base = UserDefaults.standard.string(forKey: "glassesReceiver"), !base.isEmpty,
              let url = URL(string: base.trimmingCharacters(in: .whitespaces) + "/frame") else { return }
        posting = true
        Task.detached(priority: .userInitiated) {
            var ok = false
            if let jpeg = image.jpegData(compressionQuality: 0.6) {
                var req = URLRequest(url: url, timeoutInterval: 2)
                req.httpMethod = "POST"
                req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                if at.isFinite { req.setValue(String(at), forHTTPHeaderField: "X-Capture-Time") }
                ok = (try? await URLSession.shared.upload(for: req, from: jpeg)) != nil
            }
            await MainActor.run { [weak self] in
                self?.posting = false
                if ok { self?.sent += 1 }
            }
        }
    }
}

struct GlassesScreen: View {
    private let g = Glasses.shared
    @AppStorage("glassesReceiver") private var receiver = ""

    var body: some View {
        List {
            Section {
                ZStack {
                    Color.black
                    if let f = g.frame { Image(uiImage: f).resizable().scaledToFit() }
                    else if g.session != nil { ProgressView().tint(.white) }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .listRowInsets(EdgeInsets())
            } footer: {
                if g.stream == .streaming { Text(receiver.isEmpty ? "Preview only" : "\(g.sent) frames sent") }
            }
            Section {
                if g.registration != .registered {
                    Button("Connect glasses") { Task { await g.register() } }
                        .disabled(g.registration == .registering)
                } else if g.session == nil {
                    Button("Start streaming") { Task { await g.start() } }
                } else {
                    Button("Stop", role: .destructive) { g.stop() }
                }
            }
            Section {
                TextField("http://your-mac.local:8787", text: $receiver)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } header: { Text("Send frames to") } footer: {
                Text("The Mac's receiver. Empty keeps it on the phone.")
            }
            if let e = g.error { Section { Text(e).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Glasses")
    }
}
