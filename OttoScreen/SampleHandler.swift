import CoreImage
import ReplayKit

/// Your screen for Otto, while a talk runs: the system broadcast's frames, of which only the newest is kept, at
/// most one every 2 s (ScreenShare has the size and the file). ReplayKit sends a frame when the screen changes,
/// not on a clock, so the newest one waits in a single slot for the next write rather than being dropped: the
/// screen you stopped scrolling on is the one Otto gets. The extension has about 50 MB, so there's no queue of
/// frames, and one image context does every encode.
///
/// It finishes the broadcast itself when the app asks, and when the app stops saying it's there (killed mid-talk,
/// or a broadcast started from Control Center with no talk): frames are never kept without a talk to send them.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "dev.otto.screen")
    private let context = CIContext(options: [.cacheIntermediates: false])
    // On `queue`.
    private var pending: CMSampleBuffer?
    private var wrote: Date?
    private var timer: DispatchSourceTimer?
    private var over = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard (ScreenShare.age(ScreenShare.appAlive) ?? .infinity) < ScreenShare.stale else {
            return queue.async { self.finish("Start a talk with Otto first, then share your screen.") }
        }
        DictationBridge.observe(ScreenShare.stop) { [weak self] in self?.queue.async { self?.finish("Otto can’t see your screen any more.") } }
        ScreenShare.stamp(ScreenShare.extensionAlive)   // before the first tick, which stops if it's gone
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        queue.sync { timer = t }
        t.resume()
        DictationBridge.post(ScreenShare.started)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        queue.async { if !self.over { self.pending = sampleBuffer } }
    }

    /// Stopped from the system's red pill or Control Center.
    override func broadcastFinished() {
        queue.sync { over = true; timer?.cancel(); pending = nil; ScreenShare.clear() }
        DictationBridge.post(ScreenShare.finished)
    }

    /// Every second: stop if the app cleared the folder (its stop, even if the notification went missing) or has gone
    /// quiet, else say it's still here and write the newest frame when one is due.
    private func tick() {
        guard !over else { return }
        guard ScreenShare.age(ScreenShare.extensionAlive) != nil,
              (ScreenShare.age(ScreenShare.appAlive) ?? .infinity) < ScreenShare.stale else { return finish("Otto can’t see your screen any more.") }
        ScreenShare.stamp(ScreenShare.extensionAlive)
        guard let b = pending, ScreenShare.due(wrote), let pixels = CMSampleBufferGetImageBuffer(b) else { return }
        pending = nil
        wrote = .now
        autoreleasepool {
            var image = CIImage(cvPixelBuffer: pixels)
            // The screen turned sideways: the frame says so, rather than coming turned.
            if let o = CMGetAttachment(b, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
               let orientation = CGImagePropertyOrientation(rawValue: o.uint32Value) {
                image = image.oriented(orientation)
            }
            if let jpeg = ScreenShare.jpeg(image, context: context) { ScreenShare.write(jpeg) }
        }
    }

    /// On `queue`: no frame left behind, the app told, and the broadcast ended with a word for iOS's alert.
    private func finish(_ why: String) {
        guard !over else { return }
        over = true
        timer?.cancel()
        pending = nil
        ScreenShare.clear()
        DictationBridge.post(ScreenShare.finished)
        finishBroadcastWithError(NSError(domain: "dev.otto.screen", code: 1, userInfo: [NSLocalizedDescriptionKey: why, NSLocalizedFailureReasonErrorKey: why]))
    }
}
