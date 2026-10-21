import Foundation
import Security

/// The share sheet's way in when there is no app group. A free Xcode team can't have one
/// (SideStore registers it, a direct install can't), but it can share a keychain group, so
/// the app leaves the server address and token there and the extension sends on its own:
/// text as one frame on a short-lived socket, a photo through /app/photo. Both go up marked
/// shared, exactly as the app would send them.
enum ShareDirect {
    private static let service = "dev.otto.share"

    /// App side: keep the extension's copy current. Idempotent; called whenever the app reads its config.
    static func save(serverURL: String, token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "config"]
        guard let data = try? JSONEncoder().encode([serverURL, token]) else { return }
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            // No access group named: the first group in keychain-access-groups is the default.
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Extension side: the server and token the app left, if any.
    static func load() -> (url: URL, token: String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "config", kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let pair = try? JSONDecoder().decode([String].self, from: data), pair.count == 2,
              let url = URL(string: pair[0]), url.host != nil, !pair[1].isEmpty else { return nil }
        return (url, pair[1])
    }

    /// Sends what was shared straight to Otto. True once the server has it.
    static func send(text: String, jpegs: [Data]) async -> Bool {
        guard let (base, token) = load() else { return false }
        if jpegs.isEmpty { return await sendText(text, base: base, token: token) }
        var ok = true
        // The words ride along with the first photo, as a caption.
        for (i, jpeg) in jpegs.enumerated() {
            var c = URLComponents(url: base.appending(path: "app/photo"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "id", value: UUID().uuidString), URLQueryItem(name: "shared", value: "1")]
                + (i == 0 && !text.isEmpty ? [URLQueryItem(name: "text", value: text)] : [])
            var req = URLRequest(url: c.url!, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            let status = (try? await URLSession.shared.upload(for: req, from: jpeg))?.1 as? HTTPURLResponse
            ok = ok && status.map { (200..<300).contains($0.statusCode) } == true
        }
        return ok
    }

    private static func sendText(_ text: String, base: URL, token: String) async -> Bool {
        var c = URLComponents(url: base.appending(path: "app"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        // URLSession only reads control frames while a receive is pending, and the server
        // speaks first on connect: without this the pong below waits behind that frame forever.
        drain(task)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let frame: [String: Any] = ["type": "message", "id": UUID().uuidString, "text": text, "shared": true]
        guard let json = try? JSONSerialization.data(withJSONObject: frame), let s = String(data: json, encoding: .utf8)
        else { return false }
        do {
            try await task.send(.string(s))
            // A pong means the server read everything before it, the frame included.
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                task.sendPing { e in if let e { k.resume(throwing: e) } else { k.resume() } }
            }
            return true
        } catch {
            return false
        }
    }

    private static func drain(_ task: URLSessionWebSocketTask) {
        task.receive { if case .success = $0 { drain(task) } }
    }
}
