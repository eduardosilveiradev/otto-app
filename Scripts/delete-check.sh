#!/bin/bash
# Otto deleting a message it sent: the bubble and what it carried leave the thread, a reply to it is
# marked for its "Message deleted" quote, and an id that isn't here changes nothing. Runs the real
# models from Backend.swift as a plain script.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
{
  echo 'import Foundation'
  sed -n '/^enum Sender:/,/^struct CalEvent:/p' Otto/Backend.swift | sed '$d'
  sed -n '/^struct Card: Codable/,/MARK: - Views/p' Otto/Cards.swift
  cat <<'SWIFT'
struct DashTrigger: Codable {}
struct RecordedCard: Codable {}
struct OTPCode: Codable {}
struct GroupLink: Codable {}
enum ImageStore { static func data(_ id: UUID) -> Data? { nil } }
let buttons = [ActionButton(label: "Send", data: "send")]
var thread = [
    Message(from: .otto, text: "stale status", buttons: buttons, serverID: "a", card: Card(blocks: [], actions: buttons), jobs: ["job-1"]),
    Message(from: .me, text: "thanks", replyTo: "a"),
    Message(from: .otto, text: "still here", serverID: "b"),
    Message(from: .me, text: "ok", replyTo: "b"),
]
let mine = thread[1].wireID
// An id that isn't here: nothing changes.
assert(!thread.drop(["nope"]) && thread.count == 4 && thread.allSatisfy { $0.replyGone == nil })
// The message goes, with its card, buttons and job card; only the reply to it is marked.
assert(thread.drop(["a"]))
assert(thread.map(\.wireID) == [mine, "b", thread[2].wireID])
assert(thread[0].replyGone == true && thread[0].replyTo == "a" && thread[2].replyGone == nil)
// Again (history repeats what the live frame said): nothing left to do.
assert(!thread.drop(["a"]))
// The mark is saved with the thread, and a thread saved before it existed still opens.
let saved = try JSONEncoder().encode(thread)
let reopened = try JSONDecoder().decode([Message].self, from: saved)
assert(reopened[0].replyGone == true)
let old = try JSONDecoder().decode([Message].self, from: Data(#"[{"id":"7E0C9F0A-6B1D-4C55-9B0E-3C1D2A4F5B6C","from":"me","text":"hi","date":0,"buttons":[],"isVoice":false,"replyTo":"a"}]"#.utf8))
assert(old[0].replyGone == nil)
print("delete checks passed")
SWIFT
} > "$T/check.swift"
swift "$T/check.swift"
