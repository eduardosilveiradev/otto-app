#!/bin/bash
# Pinned messages (Otto/Pins.swift): the Mac's pins answer and socket frame decode into pins whose message is the
# same message history gives (yours and Otto's, with a card and files), one pin that doesn't read is left out
# without losing the rest, and a frame that doesn't read is nil, never "none pinned". The rows are shaped as
# otto-core's otto/tests/pins.test.ts stores them. Runs LiveBackend's own decoding as a plain script.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
L=Otto/LiveBackend.swift
{
  echo 'import Foundation'
  sed -n '/^enum Sender:/,/^struct CalEvent:/p' Otto/Backend.swift | sed '$d'
  sed -n '/^struct Card: Codable/,/MARK: - Views/p' Otto/Cards.swift
  echo 'enum LiveBackend {'
  sed -n '/One \/app\/history row as a message/,/pins.compactMap/p' $L; echo '    }'
  sed -n '/private static func terminal(/,/^    }/p' $L
  sed -n '/private struct WireButton:/p' $L
  sed -n '/private struct WireHistory:/,/^    }/p' $L
  sed -n '/static func date(_ s: String?)/,/^    }/p' $L
  echo '}'
  cat <<'SWIFT'
struct DashTrigger: Codable {}
struct RecordedCard: Codable {}
struct OTPCode: Codable {}
struct GroupLink: Codable {}
struct CallRecord: Codable {}
enum ImageStore { static func data(_ id: UUID) -> Data? { nil } }

let frame = #"""
{"type":"pins","pins":[
 {"id":"PIN-1","pinnedAt":"2026-11-26T10:00:00.000Z","message":{"id":"PIN-1","dir":"in","text":"the study set","ts":"2026-11-26T09:59:00.000Z"}},
 {"id":"broken","message":{"id":"broken","dir":"out","text":"no pinnedAt","ts":"2026-11-26T09:00:00.000Z"}},
 {"id":"a1b2c3","pinnedAt":"2026-11-26T10:05:00.000Z","message":{"id":"a1b2c3","dir":"out","text":"your study set","ts":"2026-11-26T10:04:00.000Z",
   "files":[{"id":"f9","name":"study.txt","kind":"file"}],"card":{"title":"Study","blocks":[{"type":"progress","value":0.4,"label":"2 of 5"}]},
   "buttons":[{"label":"Quiz me","data":"quiz study"}]}}
]}
"""#
let pins = LiveBackend.pins(from: Data(frame.utf8))!
assert(pins.map(\.id) == ["PIN-1", "a1b2c3"], "the one without pinnedAt is left out, the others kept in order")
let mine = pins[0].message, otto = pins[1].message
assert(mine.from == .me && mine.wireID == "PIN-1" && mine.text == "the study set")
assert(otto.from == .otto && otto.wireID == "a1b2c3", "matched to the thread by wireID, as history's row is")
assert(otto.files?.first?.id == "f9" && otto.card?.title == "Study" && otto.card?.shown.count == 1 && otto.buttons.first?.label == "Quiz me")
assert(pins[1].pinnedAt == LiveBackend.date("2026-11-26T10:05:00.000Z") && otto.date == LiveBackend.date("2026-11-26T10:04:00.000Z"))
// Empty is a real answer: nothing pinned, or show-off mode (`hidden`).
assert(LiveBackend.pins(from: Data(#"{"type":"pins","pins":[]}"#.utf8))?.isEmpty == true)
assert(LiveBackend.pins(from: Data(#"{"pins":[],"hidden":true}"#.utf8))?.isEmpty == true)
// A frame that doesn't read says nothing, so the strip keeps what it has.
assert(LiveBackend.pins(from: Data(#"{"type":"pins","pins":3}"#.utf8)) == nil)
assert(LiveBackend.pins(from: Data("not json".utf8)) == nil)
print("pins checks passed")
SWIFT
} > "$T/check.swift"
swift "$T/check.swift"
