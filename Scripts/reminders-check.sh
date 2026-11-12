#!/bin/bash
# Reminders scheduled on the phone (Reminders.swift): what a set adds, removes and acks.
# Runs the pure planning code as a plain Swift script (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
{ echo 'import Foundation'
  sed -n '/^struct ReminderItem/,/^}/p' Otto/Reminders.swift
  sed -n '/^enum ReminderPlan/,/^}/p' Otto/Reminders.swift
  cat <<'SWIFT'
let now = Date(timeIntervalSince1970: 1_800_000_000)
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
func at(_ s: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(s)) }
let date: (String) -> Date? = { iso.date(from: $0) }
let p = ReminderPlan.prefix

// A set: future ones are scheduled under our prefix, a past one is skipped.
let items = [ReminderItem(id: "a", at: at(3600), text: "call the dentist"),
             ReminderItem(id: "b", at: at(-5), text: "already gone"),
             ReminderItem(id: "c", at: "not a date", text: "x")]
var plan = ReminderPlan.plan(items, pending: [:], now: now, date: date)
assert(plan.add.map(\.id) == [p + "a"] && plan.add[0].text == "call the dentist" && plan.add[0].date == now.addingTimeInterval(3600))
assert(plan.remove.isEmpty)

// Pending ones that left the set go; one about to fire stays; others' notifications are never touched.
let pending: [String: Date] = [p + "a": now.addingTimeInterval(3600), p + "old": now.addingTimeInterval(7200),
                               p + "due": now.addingTimeInterval(30), "otto-message-id": now.addingTimeInterval(9000)]
plan = ReminderPlan.plan(items, pending: pending, now: now, date: date)
assert(plan.remove == [p + "old"], "\(plan.remove)")

// An empty set clears every reminder of ours not about to fire.
plan = ReminderPlan.plan([], pending: pending, now: now, date: date)
assert(plan.add.isEmpty && plan.remove == [p + "a", p + "old"])

// Acks: only what iOS really has pending, at that exact time.
let acked = ReminderPlan.acks([ReminderItem(id: "a", at: at(3600), text: ""), ReminderItem(id: "moved", at: at(60), text: ""),
                               ReminderItem(id: "missing", at: at(60), text: "")],
                              pending: [p + "a": now.addingTimeInterval(3600), p + "moved": now.addingTimeInterval(120)], date: date)
assert(acked.map(\.id) == ["a"])
print("reminders-check ok")
SWIFT
} > "$T"
swiftc -o "${T%.swift}" "$T" && "${T%.swift}"
