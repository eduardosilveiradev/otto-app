#!/bin/bash
# Thread search: one matching rule for finding and lighting up, case- and diacritic-insensitive,
# for accented Latin, Japanese and emoji. Runs ThreadSearch from ThreadSearch.swift as a plain script.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^enum ThreadSearch/,/^}/p' Otto/ThreadSearch.swift
  cat <<'SWIFT'
typealias S = ThreadSearch
assert(S.matches("Perché il treno è in ritardo?", "perche"))
assert(S.matches("O coração da cidade", "CORACAO"))
assert(S.matches("駅の近くのカフェ", "駅"))
assert(S.matches("Pizza tonight? 🍕", "🍕"))
assert(!S.matches("Pizza tonight?", "unicorno"))
// every occurrence lights up, each as it's written
let t = "Perché? perché sì. PERCHÉ no."
assert(S.ranges(of: "perche", in: t).map { String(t[$0]) } == ["Perché", "perché", "PERCHÉ"])
assert(S.ranges(of: "🍕", in: "🍕 and 🍕").count == 2)
// a match far into a long message is still in the excerpt, a short one is left whole
let long = String(repeating: "filler words here ", count: 20) + "the boiler check is on the 18th"
let e = S.excerpt(long, "boiler")
assert(e.hasPrefix("…") && e.contains("boiler") && e.count < long.count)
assert(S.excerpt("Perché no?", "perche") == "Perché no?")
print("search ok")
SWIFT
} > "$T"
swift "$T"
