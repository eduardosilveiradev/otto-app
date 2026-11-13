#!/bin/bash
# The money screen's combined total: every currency into the main one at ECB rates, or nothing at all
# when a rate is missing. Runs ECB.combined from Dash.swift as a plain script.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^struct DashMoney/,/^}/p; /^enum ECB/,/^}/p' Otto/Dash.swift
  cat <<'SWIFT'
typealias T = DashMoney.Total
let totals = [T(currency: "EUR", total: 1477.30, count: 42), T(currency: "USD", total: 412.00, count: 1), T(currency: "BRL", total: 100, count: 2)]
let r = ECB.Rates(base: "EUR", date: "2026-11-12", rates: ["USD": 1.1081, "BRL": 6.2])
let all = ECB.combined(totals, in: r)!
assert(abs(all - (1477.30 + 412 / 1.1081 + 100 / 6.2)) < 0.005, "\(all)")
// a missing, zero or broken rate leaves the line out rather than guessing
assert(ECB.combined(totals, in: ECB.Rates(base: "EUR", date: "2026-11-12", rates: ["USD": 1.1081])) == nil)
assert(ECB.combined(totals, in: ECB.Rates(base: "EUR", date: "2026-11-12", rates: ["USD": 1.1081, "BRL": 0])) == nil)
assert(ECB.combined(totals, in: ECB.Rates(base: "EUR", date: "2026-11-12", rates: ["USD": .nan, "BRL": 6.2])) == nil)
// the wire answer decodes as frankfurter.dev sends it
let wire = #"{"amount":1.0,"base":"USD","date":"2026-11-12","rates":{"BRL":5.6169,"EUR":0.90245}}"#
let w = try! JSONDecoder().decode(ECB.Rates.self, from: Data(wire.utf8))
assert(w.base == "USD" && w.rates["EUR"] == 0.90245)
print("money ok")
SWIFT
} > "$T"
swift "$T"
