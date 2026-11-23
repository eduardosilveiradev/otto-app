#!/bin/bash
# Keyboard dictation gives the audio session back (music must come back as it was). Runs
# DictationBridge.shouldEnd as a plain Swift script (no simulator), and checks Otto/Dictation.swift
# takes and releases the session in exactly one place each, record-only.
set -euo pipefail
cd "$(dirname "$0")/.."
D=Otto/Dictation.swift
count() { grep -c -- "$1" "$D" || true; }
[ "$(count 'setActive(true)')" = 1 ] || { echo "setActive(true) must appear once, in begin()"; exit 1; }
[ "$(count 'setActive(false, options: .notifyOthersOnDeactivation)')" = 1 ] || { echo "setActive(false, .notifyOthersOnDeactivation) must appear once, in end()"; exit 1; }
[ "$(count 'setActive(')" = 2 ] || { echo "no other setActive in $D"; exit 1; }
[ "$(count 'setCategory(.record, mode: .default, options: \[.allowBluetoothHFP\])')" = 1 ] || { echo "dictation's session must be record-only"; exit 1; }
! grep -q 'playAndRecord\|defaultToSpeaker\|duckOthers\|voiceChat\|measurement\|VoiceProcessing' "$D" || { echo "$D must not change routing, gain or other audio"; exit 1; }
# Every way a dictation finishes goes through end(), and end() runs before anything slow.
for f in stop cancel; do
  awk "/private func $f\\(\\) \\{/{getline; print; exit}" "$D" | grep -q 'end()' || { echo "$f() must call end() first"; exit 1; }
done
awk '/} catch \{/{getline; print}' "$D" | grep -q 'end()' || { echo "start()'s catch must call end()"; exit 1; }

T=$(mktemp -d)/check.swift
{ cat Shared/DictationBridge.swift
  cat <<'SWIFT'
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
func expect(_ got: Bool, _ want: Bool, _ why: String) { precondition(got == want, "\(why): got \(got), want \(want)") }
let u = DictationBridge.unseen, l = DictationBridge.longest
expect(DictationBridge.shouldEnd(now: at(5), started: t0, seen: at(4), micRunning: true), false, "recording, keyboard answering")
expect(DictationBridge.shouldEnd(now: at(5), started: t0, seen: at(4), micRunning: false), true, "the mic stopped under it (call, Siri, route change)")
expect(DictationBridge.shouldEnd(now: at(u - 1), started: t0, seen: t0, micRunning: true), false, "a moment unseen: going back to the app they type in")
expect(DictationBridge.shouldEnd(now: at(u + 1), started: t0, seen: t0, micRunning: true), true, "unseen too long: keyboard gone or killed")
expect(DictationBridge.shouldEnd(now: at(l - 1), started: t0, seen: at(l - 2), micRunning: true), false, "a long dictation, still attended")
expect(DictationBridge.shouldEnd(now: at(l + 1), started: t0, seen: at(l), micRunning: true), true, "past the cap")
print("dictation session: ok")
SWIFT
} > "$T"
swift "$T"
