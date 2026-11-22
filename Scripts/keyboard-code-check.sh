#!/bin/bash
# The login code the app hands the keyboard: it lasts two minutes from when the server sent it, an
# expired one is removed when read, clearing by code leaves a newer code alone, and the newest wins.
# Runs Shared/KeyboardCode.swift as a plain Swift script against a throwaway defaults suite (no simulator).
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)/check.swift
trap 'defaults delete keyboard-code-check >/dev/null 2>&1 || true' EXIT
{ cat Shared/KeyboardCode.swift
  echo 'enum DictationBridge { static var posts = 0; static func post(_: String) { posts += 1 } }'
  cat <<'SWIFT'
KeyboardCode.store = UserDefaults(suiteName: "keyboard-code-check")
let t0 = Date(timeIntervalSince1970: 1_000_000)
func raw() -> Data? { KeyboardCode.store?.data(forKey: "keyboardCode") }

// Offered on arrival: live for two minutes, told to an open keyboard.
KeyboardCode.offer("123456", sender: "Northside Bank", sent: t0, now: t0)
precondition(KeyboardCode.current(now: t0)?.code == "123456")
precondition(KeyboardCode.current(now: t0)?.sender == "Northside Bank")
precondition(KeyboardCode.current(now: t0 + 119)?.code == "123456", "still live just before two minutes")
precondition(DictationBridge.posts == 1)

// Expired: not shown, and removed from disk by the read.
precondition(KeyboardCode.current(now: t0 + 120) == nil, "gone at two minutes")
precondition(raw() == nil, "an expired code is removed, not left in the plist")

// A held copy flushed on reconnect counts from when the server sent it.
KeyboardCode.offer("123456", sender: nil, sent: t0, now: t0 + 90)
precondition(KeyboardCode.current(now: t0 + 90)?.expires == t0 + 120)
precondition(KeyboardCode.current(now: t0 + 121) == nil)
KeyboardCode.offer("123456", sender: nil, sent: t0, now: t0 + 600)
precondition(raw() == nil, "one already past its two minutes isn't offered")
// A server clock ahead of the phone's doesn't stretch it.
KeyboardCode.offer("123456", sender: nil, sent: t0 + 30, now: t0)
precondition(KeyboardCode.current(now: t0)?.expires == t0 + 120)

// Two codes close together: the newest wins, and masking the older one leaves it.
KeyboardCode.offer("111111", sender: "Northside Bank", sent: t0, now: t0)
KeyboardCode.offer("222222", sender: "Example Mail", sent: t0 + 5, now: t0 + 5)
precondition(KeyboardCode.current(now: t0 + 6)?.code == "222222")
KeyboardCode.clear("111111")
precondition(KeyboardCode.current(now: t0 + 6)?.code == "222222", "masking an older code never takes the newer one")

// Inserted (or masked): gone for both sides.
let before = DictationBridge.posts
KeyboardCode.clear("222222")
precondition(KeyboardCode.current(now: t0 + 6) == nil && raw() == nil)
precondition(DictationBridge.posts == before + 1)
KeyboardCode.clear()
precondition(DictationBridge.posts == before + 1, "clearing nothing tells no one")

// Clear with no code takes whatever is there.
KeyboardCode.offer("333333", sender: nil, sent: t0, now: t0)
KeyboardCode.clear()
precondition(raw() == nil)
print("keyboard code ok")
SWIFT
} > "$T"
swift "$T"
