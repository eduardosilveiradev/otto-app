#!/bin/bash
# What one person puts into iPhone Search (Otto/PeopleSearch.swift), built on the Mac: the name, and who they are
# to you in one line from relationship, organisation and city, with no stray separators when some are missing.
# The item is built from those four fields alone, so a note can't reach it. Also: the Mac's people answer
# (otto-core's GET /app/dash/people) decodes, with the fields it leaves out.
set -euo pipefail
cd "$(dirname "$0")/.."
D=$(mktemp -d)
{ echo 'import Foundation'
  sed -n '/^struct PersonCard/,/^}/p' Otto/Dash.swift
  echo 'struct People: Decodable { let cards: [PersonCard] }'
  cat Otto/PeopleSearch.swift
  cat <<'SWIFT'
func about(_ i: CSSearchableItem) -> String? { i.attributeSet.contentDescription }
let odalys = PeopleSearch.item("Odalys Fenwright", "landlord’s contact", "Casa Lettings", "Lisbon")
assert(odalys.uniqueIdentifier == "Odalys Fenwright" && odalys.domainIdentifier == "people")
assert(odalys.attributeSet.title == "Odalys Fenwright" && about(odalys) == "landlord’s contact · Casa Lettings · Lisbon")
assert(abs(odalys.expirationDate.timeIntervalSinceNow - 365 * 24 * 3600) < 60, "a year, not the default month")
assert(about(PeopleSearch.item("Wren", nil, nil, nil)) == nil, "a name alone: no second line")
assert(about(PeopleSearch.item("Wren", "", nil, "")) == nil, "empty fields count as missing")
assert(about(PeopleSearch.item("Bruno", "climbing partner", nil, "Porto")) == "climbing partner · Porto")
assert(about(PeopleSearch.item("Ana", nil, "Casa Lettings", nil)) == "Casa Lettings")
let long = String(repeating: "Bartholomew-", count: 12) + "Okonkwo"
assert(PeopleSearch.item(long, nil, nil, nil).attributeSet.title == long && PeopleSearch.item("王小明", "同事", nil, nil).attributeSet.title == "王小明")
let wire = #"""
{"cards":[{"name":"Odalys Fenwright","relationship":"landlord’s contact","city":"Lisbon","org":"Casa Lettings","inbound":4,"outbound":2,
           "lastContact":"2026-11-20T18:00:00Z","mentions":[3],"notes":[{"at":"2026-11-02","text":"Wants the deposit back by December."}]},
          {"name":"Wren","inbound":0,"outbound":0,"mentions":[],"notes":[]}]}
"""#
let p = try! JSONDecoder().decode(People.self, from: Data(wire.utf8))
assert(p.cards.map(\.name) == ["Odalys Fenwright", "Wren"] && p.cards[1].relationship == nil)
print("people search ok")
SWIFT
} > "$D/check.swift"
swiftc -o "$D/check" "$D/check.swift" 2>&1 | grep -v warning || true
"$D/check"
