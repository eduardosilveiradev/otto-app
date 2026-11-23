import Foundation

/// A login code the app hands the Otto keyboard, which offers it as its first suggestion. Through the app
/// group, for two minutes from when the server sent it. Whoever inserts it clears it for both sides, and
/// the app clears it when Otto masks the code. Never logged, and never put in the keyboard's clip history.
struct KeyboardCode: Codable, Equatable {
    let code: String
    let sender: String?
    let expires: Date

    static let lifetime: TimeInterval = 120
    /// Darwin notification: the code changed, so an open keyboard looks again.
    static let changed = "dev.otto.keyboardCode"
    static var store = UserDefaults(suiteName: "group.dev.otto.app")
    private static let key = "keyboardCode"

    /// The live code, or nil. An expired one is removed on the way, so it isn't left on disk.
    static func current(now: Date = .now) -> KeyboardCode? {
        guard let data = store?.data(forKey: key), let c = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        guard c.expires > now else { store?.removeObject(forKey: key); return nil }
        return c
    }

    /// The newest code wins. `sent` is the server's time: a held copy flushed on reconnect doesn't get a fresh two minutes.
    static func offer(_ code: String, sender: String?, sent: Date, now: Date = .now) {
        let expires = min(sent, now).addingTimeInterval(lifetime)
        guard expires > now, let data = try? JSONEncoder().encode(Self(code: code, sender: sender, expires: expires)) else { return }
        store?.set(data, forKey: key)
        DictationBridge.post(changed)
    }

    /// Clears it, or only if it is still `code`: masking an older message never takes a newer code.
    static func clear(_ code: String? = nil) {
        guard let data = store?.data(forKey: key) else { return }
        if let code, (try? JSONDecoder().decode(Self.self, from: data))?.code != code { return }
        store?.removeObject(forKey: key)
        DictationBridge.post(changed)
    }
}
