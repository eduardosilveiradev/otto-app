#!/bin/bash
# Today's flight on the Lock Screen: when the Live Activity starts, updates and leaves (LockScreenStep in
# Gate.swift). Runs the decision as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^enum LockScreenStep/,/^}/p' Otto/Gate.swift
  cat <<'SWIFT'
let cal = Calendar.current
let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
let at = { (h: Double) in noon.addingTimeInterval(h * 3600) }
func next(_ d: Date, live: Bool = false, started: Bool = false, now: Date = noon) -> LockScreenStep {
    LockScreenStep.next(departs: d, live: live, started: started, now: now)
}
assert(next(at(3)) == .start)                                 // this afternoon
assert(next(at(3), started: true) == .none)                   // swiped away: stays away
assert(next(at(9)) == .none)                                  // more than 8 hours out: iOS would end it first
assert(next(at(-1)) == .none)                                 // already gone
assert(next(at(13), now: at(6)) == .none)                     // tomorrow 01:00 seen at 18:00: not today
assert(next(at(13), now: at(12.5)) == .start)                 // the same flight just after midnight
assert(next(at(3), live: true, started: true) == .update)     // a gate or a delay comes in
assert(next(at(3), live: true, started: true, now: at(3)) == .leave(at: at(4)))  // departed: gone an hour later
print("gate-check ok")
SWIFT
} > "$T"
swift "$T"
