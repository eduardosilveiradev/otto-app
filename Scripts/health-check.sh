#!/bin/bash
# The Health screens' wire model against the mock backend's sample and worst-case answers (from the mockup's
# health.sample.json and health.worst.json): both decode, and a null reading stays nil, never a zero.
set -euo pipefail
cd "$(dirname "$0")/.."
D=$(mktemp -d)
{ echo 'import Foundation'
  echo 'enum ECB { struct Rates { let base: String; let date: String; let rates: [String: Double] } }'
  sed -n '/^struct DashHealth/,/^}/p' Otto/Dash.swift
  sed '1d' Otto/MockDash.swift
  cat <<'SWIFT'
// The contact card's probe: no watch, and show-off mode's veil, both mean no row.
let off = try! JSONDecoder().decode(DashHealth.Probe.self, from: Data(#"{"connected":false}"#.utf8))
let veiled = try! JSONDecoder().decode(DashHealth.Probe.self, from: Data(#"{"connected":false,"hidden":true}"#.utf8))
assert(!off.connected && off.hidden == nil && veiled.hidden == true)
let worst = CommandLine.arguments.contains("-healthWorst")
let h = try! JSONDecoder().decode(DashHealth.self, from: MockDash.data("health")!)
assert(h.days.count == 14)
if worst {
    assert(h.stale && h.today.sleep == nil && h.today.bodyBattery == nil && h.today.restingHr == nil)
    assert(h.today.steps == 0, "no steps yet is a zero, not a gap")
    assert(h.days[1].sleepHours == nil && h.days[13].sleepHours == nil && h.days[13].steps == 0)
    assert(h.activity[0].label.count > 40)
} else {
    let s = h.today.sleep!
    assert(!h.stale && s.minutes == s.stages.deep + s.stages.light + s.stages.rem)
    assert(h.days.allSatisfy { $0.sleepHours != nil && $0.steps != nil } && h.days.last!.date == h.day)
}
print("health ok\(worst ? " (worst)" : "")")
SWIFT
} > "$D/check.swift"
swiftc -D DEBUG -o "$D/check" "$D/check.swift" 2>&1 | grep -v warning || true
"$D/check"; "$D/check" -healthWorst
