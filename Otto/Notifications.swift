import AVFoundation
import BackgroundTasks
import UIKit
import UserNotifications

/// Notifications without APNs (free Apple IDs can't have the push entitlement).
/// Two paths, the same ones Ghost uses:
///  - the app posts a local notification itself when a reply lands while it's in
///    the background but iOS hasn't suspended it yet (the ~30s grace period);
///  - background app refresh: iOS wakes the app every so often (its timing, not
///    ours) and it pulls anything newer from the server's /app/history.
/// So "usually within a while", never real-time once fully suspended.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let refreshTask = "dev.otto.app.refresh"
    private static let category = "OTTO_MESSAGE"
    private static let replyAction = "OTTO_REPLY"

    /// Before launch finishes: notification delegate + reply action, background task handler.
    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message Otto")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [reply],
                                                                 intentIdentifiers: [], options: [])])

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTask, using: nil) { task in
            Self.scheduleRefresh()   // chain the next wake-up first
            let work = Task { @MainActor in
                await OttoStore.shared.backgroundSync()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Ask iOS to wake the app again. 15 minutes is the floor we ask for; iOS decides.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func post(_ m: Message) {
        let content = UNMutableNotificationContent()
        content.title = "Otto"
        content.body = m.text
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = "otto"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: m.id.uuidString, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Inline reply from the notification goes out like any typed message.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if response.actionIdentifier == Self.replyAction,
           let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            Task { @MainActor in OttoStore.shared.send(text); done() }
            return
        }
        done()
    }

    /// The chat is already on screen when the app is in front; no banner needed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([])
    }
}

/// Leaving the app normally gets it suspended within seconds, so a reply to what
/// you just sent would land on a frozen socket. Asking iOS for background time
/// keeps it running for roughly 30s more: long enough for that reply to arrive and
/// become a banner. iOS ends it early whenever it likes; expiry just suspends us.
@MainActor
enum Grace {
    private static var task: UIBackgroundTaskIdentifier = .invalid

    static func update(background: Bool) {
        if background, task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "otto-grace") { end() }
        } else if !background {
            end()
        }
    }

    private static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

/// Background liveness without push: iOS keeps an app running while it plays audio,
/// so a silent loop (mixed with whatever else is playing) keeps the websocket open
/// and replies become banners within a second. Sideloaded only — App Review would
/// reject this. Costs some battery; Settings has an off switch ("stayAwake").
/// Never runs during a web call, whose audio session belongs to the call.
@MainActor
enum Keepalive {
    private static var player: AVAudioPlayer?

    static var enabled: Bool { UserDefaults.standard.object(forKey: "stayAwake") as? Bool ?? true }

    static func update(background: Bool) {
        if background && enabled && !CallManager.active { start() } else { stop() }
    }

    private static func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: silentWAV())
        player?.numberOfLoops = -1
        player?.volume = 0
        player?.play()
        // A phone call or Siri interrupts playback; pick it back up afterwards.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { MainActor.assumeIsolated { player?.play() } }
        }
    }

    private static func stop() {
        guard let p = player else { return }
        p.stop()
        player = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One second of 8 kHz mono 16-bit silence.
    private static func silentWAV() -> Data {
        let rate: UInt32 = 8000, samples = rate, bytes = samples * 2
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)            // PCM, mono
        put(rate.littleEndian); put((rate * 2).littleEndian)                 // sample rate, byte rate
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)           // block align, bits
        d.append(contentsOf: Array("data".utf8)); put(bytes.littleEndian)
        d.append(Data(count: Int(bytes)))
        return d
    }
}
