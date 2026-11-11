#!/bin/bash
# Run the real sync journal and message models without an app/test host.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
{
  echo 'import Foundation'
  sed -n '/^enum Sender:/,/^struct CalEvent:/p' Otto/Backend.swift | sed '$d'
  sed -n '/^struct Card: Codable/,/MARK: - Views/p' Otto/Cards.swift
  sed -n '/^    static func date(_ s: String?)/,$p' Otto/LiveBackend.swift | sed '$d' | { echo 'enum LiveBackend {'; cat; echo '}'; }
  cat Otto/DesktopSync.swift
  cat <<'SWIFT'
struct DashTrigger: Codable {}
struct RecordedCard: Codable {}
struct OTPCode: Codable {}
struct GroupLink: Codable {}
enum ImageStore { static func data(_ id: UUID) -> Data? { nil } }
let key = "desktop-sync-check-" + UUID().uuidString
UserDefaults.standard.removeObject(forKey: key)
defer { UserDefaults.standard.removeObject(forKey: key) }
let sync = DesktopSync(key: key)
let local = UUID()
let source = "source-wire-id"
let op = UUID().uuidString.lowercased()
let read = Data(#"{"type":"notifications_read","ids":["source-wire-id"]}"#.utf8)
let tap = try JSONSerialization.data(withJSONObject: ["type": "button_tapped", "id": source, "op": op, "data": "choose", "label": "Chosen", "ts": "2026-01-01T12:00:00.000Z"])
assert(sync.receive(read) && sync.receive(tap))
// Persist before history exists, then replay after restart.
let restored = DesktopSync(key: key)
assert(restored.snapshot.read.contains(source))
var messages: [Message] = []
restored.snapshot.apply(to: &messages)
assert(messages.count == 1 && messages[0].wireID == op && messages[0].pending != true)
messages.append(Message(id: local, from: .otto, text: "Pick", buttons: [ActionButton(label: "Choose", data: "choose")], serverID: source, card: Card(blocks: [], actions: [ActionButton(label: "Choose", data: "choose")])))
restored.snapshot.apply(to: &messages)
assert(messages.last!.buttons.isEmpty && messages.last!.card!.actions!.isEmpty)
let ids = Set(restored.snapshot.notificationIDs(in: messages))
assert(ids == [source, local.uuidString])
assert(!ids.contains("unrelated"))
// The server replays its whole journal on every connect: what's already applied wakes nothing, a new read does.
func woke(_ s: DesktopSync) async -> Bool {
    await withTaskGroup(of: Bool.self) { g in
        g.addTask { var it = s.updates.makeAsyncIterator(); return await it.next() != nil }
        g.addTask { try? await Task.sleep(for: .milliseconds(200)); return false }
        let first = await g.next()!
        g.cancelAll()
        return first
    }
}
assert(restored.receive(tap) && restored.receive(read))
let replayWoke = await woke(restored)
assert(!replayWoke)
let next = DesktopSync(key: key)
assert(next.receive(Data(#"{"type":"notifications_read","ids":["newer-wire-id"]}"#.utf8)))
let newWoke = await woke(next)
assert(newWoke)
restored.snapshot.apply(to: &messages)
assert(messages.count == 2 && messages.filter { $0.wireID == op }.count == 1)
// History-first ordering also upserts the same lowercase UUID op.
var history = [Message(id: UUID(uuidString: op)!, from: .me, text: "Chosen", serverID: op)]
restored.snapshot.apply(to: &history)
assert(history.count == 1 && history[0].wireID == op)
// A history row with the tap op merges and clears pending without changing its local id.
messages[0].pending = true
messages[0].failed = true
restored.snapshot.apply(to: &messages)
assert(messages[0].pending == nil && messages[0].failed == nil)
let pending = Message(from: .me, text: "Chosen", pending: true, tap: "choose", tapOf: source)
let retried = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(pending))
let frame = DesktopSync.tapFrame(ActionButton(label: retried.text, data: retried.tap), op: retried.wireID, source: retried.tapOf)
assert(frame["id"] == source && frame["op"] == pending.wireID)
assert(frame["label"] == "Chosen" && frame["data"] == "choose")
assert(!restored.receive(Data(#"{"type":"read","ids":["other"]}"#.utf8)))
print("desktop sync checks passed")
SWIFT
} > "$T/check.swift"
swift "$T/check.swift"
