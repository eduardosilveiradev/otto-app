#!/bin/bash
# Records Otto's motion for the review page: one short clip per interaction, so a glitch can be
# watched at a quarter speed. Launch arguments set each scene up, as in shoot.sh; agent-device taps.
#
#   Scripts/record.sh <out-dir> [regex]      the clips whose name matches (default: all)
#
# Reuses the booted iPhone simulator (Scripts/shoot.sh's), or boots none: boot one first. APP=<Otto.app>
# installs that build (a DEBUG one: the scenes are DEBUG launch arguments). THEME=light for light mode.
# Out: <name>.mp4, H.264, 390 px wide, 60 fps, no sound.
set -uo pipefail
OUT=${1:?usage: Scripts/record.sh <out-dir> [regex]}
FILTER=${2:-.}
ID=dev.otto.app
AD=(npx -y agent-device@0.21.37)
# A booted iPhone, not another job's named check device (e.g. "drawer-check") booted alongside it.
DEV=${DEV:-$(xcrun simctl list devices booted | grep -E '^ +iPhone' | grep -m1 -oE '\(([0-9A-F-]{36})\) \(Booted\)' | cut -c2-37)}
[ -n "$DEV" ] || { echo "no booted simulator: boot one, or run Scripts/shoot.sh first" >&2; exit 1; }
mkdir -p "$OUT"
[ -n "${APP:-}" ] && xcrun simctl install "$DEV" "$APP"
xcrun simctl ui "$DEV" appearance "${THEME:-dark}"
xcrun simctl status_bar "$DEV" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3 --dataNetwork wifi

now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
# The clip starts just before the first tap lands, which is near the end of the first agent-device call
# (it reads the screen first). Clips without taps start when recording does, or at FROM seconds.
TAP=
ad() { "${AD[@]}" "$@" >/dev/null 2>&1 || "${AD[@]}" "$@" >/dev/null 2>&1; [ -n "$TAP" ] || TAP=$(now); }   # once more on a failure: a busy Mac drops the odd call
clean() {
  local data; data=$(xcrun simctl get_app_container "$DEV" $ID data 2>/dev/null) || return 0
  rm -rf "$data/Library/Application Support/"* "$data/Library/Caches/"* 2>/dev/null
  xcrun simctl spawn "$DEV" defaults delete $ID >/dev/null 2>&1
  xcrun simctl spawn "$DEV" defaults write $ID walkieHintAt -float "$(date +%s)" >/dev/null 2>&1
}

# clip <name> <seconds> <launch args...>: launches the scene, attaches agent-device, records while
# play_<name> runs, then keeps <seconds> from just before the first tap.
clip() {
  local name=$1 secs=$2; shift 2
  [[ $name =~ $FILTER ]] || return 0
  xcrun simctl terminate "$DEV" $ID >/dev/null 2>&1; sleep 0.5; clean
  if [ "$name" != launch ]; then   # launch starts on camera
    xcrun simctl launch "$DEV" $ID -wipeDefaults "$@" >/dev/null
    sleep 6
    # Attaches to the running app (launch arguments survive); clips that only watch skip it.
    [[ $name =~ ^(thinking|job-update|keyboard-todos)$ ]] || ad open $ID --foreground --platform ios
  fi
  local raw="$OUT/.$name.mov"
  xcrun simctl io "$DEV" recordVideo --codec=h264 --force "$raw" >/dev/null 2>&1 &
  local rec=$!
  sleep 1   # recordVideo writes its first frame a moment after it starts
  local t0; t0=$(now); TAP=
  "play_$name" "$@"
  sleep 0.5
  kill -INT $rec; wait $rec 2>/dev/null
  local from=${FROM:-0}; [ -n "$TAP" ] && from=$(awk -v a="$TAP" -v b="$t0" 'BEGIN { s = a - b - 1.2; print (s < 0 ? 0 : s) }')
  ad close
  ffmpeg -y -loglevel error -ss "$from" -i "$raw" -t "$secs" -vf "scale=390:-2,fps=60" \
    -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -movflags +faststart -an "$OUT/$name.mp4"
  rm -f "$raw"
  echo "$name.mp4 $(( $(stat -f%z "$OUT/$name.mp4") / 1024 )) KB"
}

B="-onboarded YES -noNotificationPrompt"
O="$B -pipsFixture -pipsScreen otto"
# Face ID enrolled, so the payment can be approved on camera.
xcrun simctl spawn "$DEV" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn "$DEV" notifyutil -p com.apple.BiometricKit.enrollmentChanged

play_launch() { xcrun simctl launch "$DEV" $ID -wipeDefaults "$@" >/dev/null; sleep 6; }
clip launch 6 $O -demoThread

# The composer focuses itself 5 s after the store starts (-focusAfter), early in this recording: no tap to miss.
play_keyboard-todos() { sleep 6; }
FROM=0 clip keyboard-todos 5 $O -demoThread -openTodos -todosOpen -focusAfter 5

play_send-reply() { ad fill 'editable=true' "on my way"; ad press 'label="Send"'; sleep 3; }
clip send-reply 6 $O -seedThread -quickReply

play_switch-threads() { ad press 'label="Code, 8:12 AM, Merge or hold PR #214?"'; sleep 0.5; ad back; sleep 1.5; }
clip switch-threads 6 $B -pipsFixture -pipsScreen conversations

play_scroll-long() { ad gesture pan 201 250 0 450 350; ad gesture pan 201 250 0 450 350; ad gesture pan 201 700 0 -500 350; sleep 1; }
clip scroll-long 6 $O -longThread a

play_details() { ad press 'role=button label="Otto"'; sleep 1.5; ad press 'label="Back"'; sleep 1.5; }
clip details 6 $O -demoThread

# Pulled from near the top of the contact card: what a thumb does.
play_pull-card() { ad gesture pan 201 260 0 320 700; sleep 2; }
clip pull-card 4 $O -details

play_pull-refresh() { ad gesture pan 201 200 0 320 700; sleep 2; }
clip pull-refresh 4 $O -details -screen Loops

play_search-pull() { ad gesture pan 201 240 0 260 600; sleep 2; }
clip search-pull 4 $O -demoThread

play_sheet-job() { ad press 'label="Compare three flat insurance quotes"'; sleep 1.5; ad press 'label="Close"'; sleep 1.5; }
clip sheet-job 6 $O -jobsThread

play_sheet-recorded() { ad press 'label="Spending: €49.80 · E-MOTION Roma"'; sleep 1.5; ad press 'label="Done"'; sleep 1.5; }
clip sheet-recorded 6 $O -scheduleThread

play_approval-later() { ad press 'label="Later"'; sleep 2.5; }
clip approval-later 4 $O -demoThread -approvalDemo

# Face ID answers twice: the prompt can come up late on a busy Mac.
play_payment() {
  ad press 'label="Pay €17.00" role=button'
  for _ in 1 2; do sleep 1.2; xcrun simctl spawn "$DEV" notifyutil -p com.apple.BiometricKit_Sim.pearl.match; done
  sleep 2.5
}
clip payment 6 $O -demoThread -paymentDemo

# -jobsTick: the running job goes up for review and back every three seconds.
play_job-update() { sleep 6.5; }
clip job-update 6 $O -jobsThread -jobsTick

play_thinking() { sleep 4; }
clip thinking 4 $O -demoThread -thinking -todos
