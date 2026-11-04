#!/bin/bash
# Screenshots every main screen on a booted simulator, mock data, dark + light.
# Usage: design/shots.sh <out-dir> [device-id]
set -euo pipefail
OUT="$1"; DEV="${2:-1A22C70F-011C-4D46-8DD0-E6F23E432780}"
APP="${APP:-$HOME/Library/Caches/otto-design/dd/Build/Products/Debug-iphonesimulator/Otto.app}"
ID=dev.otto.app
mkdir -p "$OUT"
xcrun simctl install "$DEV" "$APP"
xcrun simctl status_bar "$DEV" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3

shot() {  # name, wait, launch args...
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$DEV" $ID 2>/dev/null || true
  xcrun simctl launch "$DEV" $ID -noNotificationPrompt "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$DEV" screenshot "$OUT/$name.png" >/dev/null 2>&1
}

for mode in dark light; do
  xcrun simctl ui "$DEV" appearance $mode
  shot "$mode-onboarding" 3 -onboarding
  shot "$mode-onboarding-connect" 3 -onboarding -onboardingStep 1
  shot "$mode-chat" 5 -onboarded YES -demoThread
  shot "$mode-details" 5 -onboarded YES -details
  for s in Loops Schedules Memory People Money Trips Activity Status; do
    shot "$mode-$(echo $s | tr A-Z a-z)" 5 -onboarded YES -details -screen $s
  done
done
