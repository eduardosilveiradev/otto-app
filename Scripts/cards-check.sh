#!/bin/bash
# Card decoding never loses a message: unknown block types, malformed blocks and a garbage
# "card" all decode, and a card survives the thread file's save. Runs the model code from
# Backend.swift and Cards.swift as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^struct ActionButton/,/^}/p' Otto/Backend.swift
  sed -n '/^struct Card: Codable/,/MARK: - Views/p' Otto/Cards.swift
  cat <<'SWIFT'
struct M: Decodable { let text: String; let card: Card? }
let j = #"""
[{"text":"a","card":{"title":"T","blocks":[{"type":"stat","value":"9"},{"type":"hologram","x":1},{"type":"list"},{"type":"bars","items":[{"label":"a","value":2}],"unit":"€"}],"actions":[{"label":"Go","data":"go"}]}},
 {"text":"b","card":"garbage"},
 {"text":"c","card":{"blocks":7}},
 {"text":"d"}]
"""#
let ms = try JSONDecoder().decode([M].self, from: Data(j.utf8))
assert(ms.count == 4)
let c = ms[0].card!
assert(c.title == "T" && c.blocks.count == 4 && c.shown.count == 2 && c.actions?.first?.data == "go")
if case .unknown = c.blocks[1] {} else { fatalError("hologram") }
if case .unknown = c.blocks[2] {} else { fatalError("bad list") }
assert(ms[1].card!.shown.isEmpty && ms[2].card!.shown.isEmpty && ms[3].card == nil)
// round trip, as the thread file saves it
let back = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(c))
assert(back.shown.count == 2)
if case .bars(let b) = back.shown[1] { assert(b.unit == "€" && b.items[0].value == 2) } else { fatalError("round trip") }
print("card decode ok")
SWIFT
} > "$T"
swift "$T"
