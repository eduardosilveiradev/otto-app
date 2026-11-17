#if DEBUG
import SwiftUI

/// Scripts/shoot.sh's fast path: the app launches once, then each review state is swapped in place. The script
/// writes the state's launch arguments, one per line, to tmp/review-args in the app's container and posts the
/// Darwin notification dev.otto.review; this makes them the process's arguments, wipes what a state left behind
/// and rebuilds the store and the screens, as a fresh launch with those arguments would. Debug builds only.
@MainActor @Observable final class ReviewSwitch {
    static let shared = ReviewSwitch()
    /// OttoApp's root is keyed on it: a new value is a new screen tree.
    private(set) var generation = 0

    /// At launch: ProcessInfo's arguments follow CommandLine's (both are read for review flags), and the script is heard.
    /// On the instance's own class: Foundation's processInfo is a private subclass with its own `arguments`.
    static func install() {
        if let cls = object_getClass(ProcessInfo.processInfo), let m = class_getInstanceMethod(cls, #selector(getter: ProcessInfo.arguments)) {
            let args: @convention(block) (AnyObject) -> [String] = { _ in CommandLine.arguments }
            method_setImplementation(m, imp_implementationWithBlock(args))
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in ReviewSwitch.shared.apply() }
        }, "dev.otto.review" as CFString, nil, .deliverImmediately)
    }

    private func apply() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "review-args")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        var a = text.components(separatedBy: "\n")
        if a.last == "" { a.removeLast() }

        // Whatever is up comes down, keyboard included.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows { w.rootViewController?.dismiss(animated: false) }
        }
        // A fresh install's state, as shoot.sh's clean and -wipeDefaults leave it: no settings, nothing saved.
        let d = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
        let fm = FileManager.default
        for dir in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            guard let u = fm.urls(for: dir, in: .userDomainMask).first else { continue }
            for item in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: item) }
        }

        // The new arguments, and the "-key value" pairs UserDefaults reads from them.
        CommandLine.arguments = [CommandLine.arguments[0]] + a
        var domain: [String: Any] = [:]
        var i = 0
        while i < a.count {
            if a[i].hasPrefix("-"), i + 1 < a.count, !a[i + 1].hasPrefix("-") { domain[String(a[i].dropFirst())] = a[i + 1]; i += 2 } else { i += 1 }
        }
        d.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        d.set(Date().timeIntervalSince1970, forKey: "walkieHintAt")   // the hint shows only for -walkieHint
        d.set(!a.contains("-onboarding") && d.bool(forKey: "onboarded"), forKey: "onboarded")   // written, so @AppStorage hears it

        // What launch set from the arguments outside the store.
        WalkieLauncher.shared.open = a.contains("-walkie")
        MediaViewer.shared.start = a.contains("-media") ? "" : nil
        CallLauncher.shared.open = a.contains("-call")
        CallLauncher.shared.explain = false
        PairInbox.shared.link = nil
        OttoStore.shared = OttoStore(backend: LiveBackend.fromDefaults() ?? MockBackend())
        generation += 1
    }
}
#endif
