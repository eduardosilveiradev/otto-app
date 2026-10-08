import Foundation

/// The hand-off between the share extension and the app. The extension can't talk to the
/// server itself (the token and the open socket live in the app), so it leaves what was
/// shared in the app group's container and pings the app, which sends it as if typed.
enum ShareOutbox {
    /// Extension → app: something is waiting. App → extension: it's been taken.
    static let ping = "dev.otto.app.share"
    static let ack = "dev.otto.app.share.ack"

    private struct Item: Codable { var text: String; var image: String? }

    /// SideStore registers app groups under its own team and writes the real id into
    /// ALTAppGroups; the plain id is what Xcode builds and the simulator use.
    static var dir: URL? {
        let group = (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])?.first ?? "group.dev.otto.app"
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let d = c.appending(path: "outbox", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// False when there's no shared container to write to.
    static func put(text: String, jpeg: Data?) -> Bool {
        guard let dir else { return false }
        // The name sorts by time, so the app sends them in the order they were shared.
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        var item = Item(text: text)
        if let jpeg {
            guard (try? jpeg.write(to: dir.appending(path: name + ".jpg"))) != nil else { return false }
            item.image = name + ".jpg"
        }
        guard let data = try? JSONEncoder().encode(item) else { return false }
        return (try? data.write(to: dir.appending(path: name + ".json"), options: .atomic)) != nil
    }

    /// Hands over everything waiting, oldest first, removing each as it goes. Returns the count.
    @discardableResult
    static func drain(_ handle: (_ text: String, _ jpeg: Data?) -> Void) -> Int {
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return 0 }
        var n = 0
        for json in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? FileManager.default.removeItem(at: json) }
            guard let data = try? Data(contentsOf: json), let item = try? JSONDecoder().decode(Item.self, from: data) else { continue }
            let image = item.image.map { dir.appending(path: $0) }
            handle(item.text, image.flatMap { try? Data(contentsOf: $0) })
            if let image { try? FileManager.default.removeItem(at: image) }
            n += 1
        }
        return n
    }

    // MARK: Darwin notifications — the one channel between two processes that needs no entitlement.

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    nonisolated(unsafe) private static var handlers: [String: () -> Void] = [:]

    /// Calls `handler` on the main queue each time `name` is posted, by any process.
    static func observe(_ name: String, _ handler: @escaping () -> Void) {
        handlers[name] = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let key = name?.rawValue as String?, let h = ShareOutbox.handlers[key] else { return }
            DispatchQueue.main.async(execute: h)
        }, name as CFString, nil, .deliverImmediately)
    }
}
