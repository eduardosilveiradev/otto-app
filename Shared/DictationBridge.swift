import Foundation
import Security

/// Dictation between the Otto keyboard and the app. A keyboard can't use the microphone,
/// so the app records. There is no app group on a free team, so state goes through the
/// shared keychain group (the one ShareDirect uses), and a Darwin notification tells the
/// other side to look. The keyboard writes a request and posts `toApp`; the app writes
/// its state and posts `toKeyboard`.
enum DictationBridge {
    struct Request: Codable {
        enum Action: String, Codable { case start, stop, cancel }
        var action: Action
        var id: String
        var preceding = ""
        var langs: [String] = ["en"]
    }

    struct State: Codable {
        enum Phase: String, Codable { case idle, listening, working, done, failed }
        var phase: Phase = .idle
        var id: String?
        var text: String?
        var level: Float = 0
        /// Epoch seconds the app last said it was listening-ready. Stale means the
        /// keyboard has to open the app to start, because iOS won't let a backgrounded
        /// app turn the microphone on.
        var alive: Double = 0

        var appIsWarm: Bool { Date().timeIntervalSince1970 - alive < 4 }
    }

    static let toApp = "dev.otto.dictate.request"
    static let toKeyboard = "dev.otto.dictate.state"
    static let openURL = URL(string: "otto://dictate")!

    static func write(_ r: Request) { put("request", r) }
    static func readRequest() -> Request? { get("request") }
    static func write(_ s: State) { put("state", s) }
    static func readState() -> State { get("state") ?? State() }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    private static var handlers: [String: () -> Void] = [:]

    /// One handler per name, called on the main queue.
    static func observe(_ name: String, _ handler: @escaping () -> Void) {
        let first = handlers[name] == nil
        handlers[name] = handler
        guard first else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let n = name?.rawValue as String? else { return }
            DispatchQueue.main.async { DictationBridge.handlers[n]?() }
        }, name as CFString, nil, .deliverImmediately)
    }

    // MARK: keychain

    private static let service = "dev.otto.dictate"

    private static func put<T: Encodable>(_ account: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func get<T: Decodable>(_ account: String) -> T? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
