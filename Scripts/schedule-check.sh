#!/bin/bash
# The pip schedule editor's cron round trip: what it can edit parses and writes back the same,
# and anything fancier is refused, so the editor leaves it alone. Runs the model code as a plain script.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^struct ScheduleWhen/,/^}/p' Otto/Pips.swift
  cat <<'SWIFT'
let w = ScheduleWhen(cron: "30 7 * * 1-5")!
assert(w.hour == 7 && w.minute == 30 && w.days == Set(1...5) && w.label == "Weekdays 7:30")
assert(ScheduleWhen(cron: w.cron) == w)
assert(ScheduleWhen(cron: "0 18 * * 7")!.days == [0])
assert(ScheduleWhen(cron: "0 9 * * 0,6")!.label == "Weekends 9:00")
assert(ScheduleWhen(cron: "5 9 * * *")!.cron == "5 9 * * *")
assert(ScheduleWhen(cron: "5 9 * * *")!.label == "Every day 9:05")
for bad in ["*/5 * * * *", "0 9 1 * *", "0 9 * * MON", "0 25 * * *", "0 9 * * 5-1", "0 9 * * 8", "0 9 * * 1-", "nonsense"] {
    assert(ScheduleWhen(cron: bad) == nil, bad)
}
print("schedule-check ok")
SWIFT
} > "$T"
swiftc -o "${T%.swift}" "$T" && "${T%.swift}"
