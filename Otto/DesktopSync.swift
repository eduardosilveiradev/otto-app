import Foundation

/// A durable journal: history may arrive after these frames, or omit their source entirely.
final class DesktopSync: @unchecked Sendable {
    struct Tap: Codable, Equatable {
        let id: String
        let op: String
        let data: String
        let label: String
        let ts: String
    }
    struct State: Codable {
        var read: Set<String> = []
        var taps: [String: Tap] = [:]

        func notificationIDs(in messages: [Message]) -> [String] {
            Array(read.union(messages.filter { read.contains($0.wireID) }.map { $0.id.uuidString }))
        }

        func apply(to messages: inout [Message]) {
            let answered = Set(taps.values.map(\.id))
            for i in messages.indices where answered.contains(messages[i].wireID) {
                messages[i].buttons = []
                messages[i].card?.actions = []
            }
            for tap in taps.values {
                if let i = messages.firstIndex(where: { $0.wireID == tap.op }) {
                    messages[i].text = tap.label
                    messages[i].pending = nil
                    messages[i].failed = nil
                } else {
                    let m = Message(id: UUID(uuidString: tap.op) ?? UUID(), from: .me, text: tap.label,
                                    date: LiveBackend.date(tap.ts) ?? .distantPast, serverID: tap.op)
                    messages.insert(m, at: messages.lastIndex { $0.date <= m.date }.map { $0 + 1 } ?? 0)
                }
            }
        }
    }

    let updates: AsyncStream<Void>
    private let out: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let key: String
    private var state: State
    var snapshot: State { lock.withLock { state } }

    init(key: String) {
        self.key = key
        state = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        // Newest only: a burst of new frames is one pass over the thread, not one per frame.
        (updates, out) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    @discardableResult func receive(_ data: Data) -> Bool {
        struct Frame: Decodable { let type: String; let ids: [String]? }
        guard let frame = try? JSONDecoder().decode(Frame.self, from: data) else { return false }
        guard frame.type == "notifications_read" || frame.type == "button_tapped" else { return false }
        // The server replays its whole journal on every connect (thousands of frames): one already
        // applied changes nothing, so it isn't saved again or handed to the thread.
        let changed = lock.withLock { () -> Bool in
            if frame.type == "notifications_read", let ids = frame.ids {
                guard !state.read.isSuperset(of: ids) else { return false }
                state.read.formUnion(ids)
            } else if frame.type == "button_tapped", let tap = try? JSONDecoder().decode(Tap.self, from: data),
                      !tap.id.isEmpty, !tap.op.isEmpty, LiveBackend.date(tap.ts) != nil {
                guard state.taps[tap.op] != tap else { return false }
                state.taps[tap.op] = tap
            } else { return false }
            if let saved = try? JSONEncoder().encode(state) { UserDefaults.standard.set(saved, forKey: key) }
            return true
        }
        if changed { out.yield(()) }
        return true
    }

    static func tapFrame(_ button: ActionButton, op: String, source: String?) -> [String: String] {
        var frame = ["type": "tap", "op": op, "data": button.data ?? "", "label": button.label]
        if let source { frame["id"] = source }
        return frame
    }
}
