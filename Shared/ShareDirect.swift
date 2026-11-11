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

    /// Sends what was shared straight to Otto. Returns once the server has it, or throws why not.
    /// `ids`: one per item (the text, or each photo), the same on every attempt and the same the
    /// outbox used, so a retry, or a fallback after some items were queued, is deduped by the server.
    static func send(text: String, jpegs: [Data], ids: [UUID]) async throws(ServerProblem) {
        guard let (base, token) = load(), let first = ids.first else { throw .notSetUp }
        if jpegs.isEmpty { return try await sendText(text, id: first.uuidString, base: base, token: token) }
        // The words ride along with the first photo, as a caption.
        for (i, jpeg) in jpegs.enumerated() {
            var c = URLComponents(url: base.appending(path: "app/photo"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "id", value: (i < ids.count ? ids[i] : UUID()).uuidString), URLQueryItem(name: "shared", value: "1")]
                + (i == 0 && !text.isEmpty ? [URLQueryItem(name: "text", value: text)] : [])
            var req = URLRequest(url: c.url!, timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            // Stops at the first that fails: a retry resends them all under the same ids, and the server dedupes.
            var res: URLResponse?, err: (any Error)?
            do { res = try await URLSession.shared.upload(for: req, from: jpeg).1 } catch { err = error }
            if let problem = ServerProblem(status: (res as? HTTPURLResponse)?.statusCode, error: err) { throw problem }
        }
    }

    private static func sendText(_ text: String, id: String, base: URL, token: String) async throws(ServerProblem) {
        var c = URLComponents(url: base.appending(path: "app"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        // A one-shot socket: the server mustn't hand it what's waiting for the app, or count it as the app open.
        c.queryItems = [URLQueryItem(name: "share", value: "1")]
        var req = URLRequest(url: c.url!, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        // URLSession only reads control frames while a receive is pending, and the server
        // speaks first on connect: without this the pong below waits behind that frame forever.
        // It also watches for the server's hello (it acks) and the ack for this message.
        let seen = Seen()
        drain(task, seen)
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let frame: [String: Any] = ["type": "message", "id": id, "text": text, "shared": true]
        guard let json = try? JSONSerialization.data(withJSONObject: frame), let s = String(data: json, encoding: .utf8)
        else { throw .unreachable }
        do {
            try await task.send(.string(s))
            // A pong means the server read everything before it, the frame included. Bounded: a network
            // switch can strand the pong handler, and the sheet would sit on Sending for good.
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let once = Seen()
                let finish: @Sendable (Error?) -> Void = { e in
                    guard once.claim("done") else { return }
                    if let e { k.resume(throwing: e) } else { k.resume() }
                }
                task.sendPing { finish($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15) { finish(URLError(.timedOut)) }
            }
            // An older server stops there. One that acks only does so once the message is written down.
            guard seen.has("hello") else { return }
            for _ in 0..<100 where !seen.has(id) { try await Task.sleep(for: .milliseconds(100)) }
            if !seen.has(id) { throw URLError(.timedOut) }
        } catch {
            // A handshake the server turned down (401, 500) fails here too; its status says which.
            throw ServerProblem(status: (task.response as? HTTPURLResponse)?.statusCode, error: error) ?? .unreachable
        }
    }

    /// What the share socket has heard: "hello", and the ids it acked.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var got: Set<String> = []
        func add(_ s: String) { lock.withLock { _ = got.insert(s) } }
        func has(_ s: String) -> Bool { lock.withLock { got.contains(s) } }
        /// True for the first caller only.
        func claim(_ s: String) -> Bool { lock.withLock { got.insert(s).inserted } }
    }

    private static func drain(_ task: URLSessionWebSocketTask, _ seen: Seen) {
        task.receive {
            guard case .success(let m) = $0 else { return }
            if case .string(let s) = m, let f = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                if f["type"] as? String == "hello" { seen.add("hello") }
                if f["type"] as? String == "ack", let id = f["id"] as? String { seen.add(id) }
            }
            drain(task, seen)
        }
    }
}
