#!/bin/bash
# Shoots Otto's iPhone screens and states from the DEBUG launch arguments, for a PR's review gallery
# (otto-core's otto/gallery.ts builds the page from <out-dir>).
#
#   Scripts/shoot.sh --list                  every screen-state name, nothing booted
#   Scripts/shoot.sh <out-dir> [regex]       the states whose "screen-state" matches (default: all)
#
# One simulator at a time, dark mode only (THEMES=light or "dark light" for more): two booted iOS 27
# simulators pushed the Mac's load past 300. A simulator someone already booted is reused and left
# running; one this script boots is shut down when it ends. APP=<Otto.app> skips the build.
set -uo pipefail
ID=dev.otto.app
THEMES=${THEMES:-dark}
LIST=0; [ "${1:-}" = --list ] && LIST=1
if [ $LIST = 0 ]; then
  OUT=${1:?usage: Scripts/shoot.sh <out-dir> [regex] | --list}
  FILTER="${2:-.}"
  mkdir -p "$OUT"
  TSV=$OUT/.manifest-${THEMES// /-}.tsv
  : > "$TSV.new"

  # One shooter at a time: a second run waits for the first rather than booting its own simulator.
  LOCK=${TMPDIR:-/tmp}/otto-shoot.lock
  until mkdir "$LOCK" 2>/dev/null; do
    kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null || { rm -rf "$LOCK"; continue; }
    echo "waiting for another shoot.sh ($(cat "$LOCK/pid"))" >&2; sleep 10
  done
  echo $$ > "$LOCK/pid"

  DEV=${DEV:-$(xcrun simctl list devices booted | grep -m1 -oE '\(([0-9A-F-]{36})\) \(Booted\)' | cut -c2-37)}
  BOOTED_HERE=0
  if [ -z "$DEV" ]; then
    # The newest iOS runtime's first iPhone.
    DEV=$(xcrun simctl list -j devices available | python3 -c '
import json, sys
d = json.load(sys.stdin)["devices"]
for rt in sorted((k for k in d if ".iOS-" in k), key=lambda k: [int(x) for x in k.rsplit(".iOS-", 1)[1].split("-")], reverse=True):
    phones = [x for x in d[rt] if x["name"].startswith("iPhone")]
    if phones: print(phones[0]["udid"]); break')
    [ -n "$DEV" ] || { echo "no iPhone simulator available" >&2; rm -rf "$LOCK"; exit 1; }
    xcrun simctl boot "$DEV" && BOOTED_HERE=1
    xcrun simctl bootstatus "$DEV" -b >/dev/null 2>&1
  fi
  done_() {
    xcrun simctl terminate "$DEV" $ID >/dev/null 2>&1
    [ $BOOTED_HERE = 1 ] && xcrun simctl shutdown "$DEV" >/dev/null 2>&1
    rm -rf "$LOCK"
  }
  trap done_ EXIT

  if [ -z "${APP:-}" ]; then
    DD=${DD:-$HOME/Library/Caches/otto-shoot/dd}
    (cd "$(dirname "$0")/.." && xcodebuild -project Otto.xcodeproj -scheme Otto -configuration Debug \
      -destination "platform=iOS Simulator,id=$DEV" -derivedDataPath "$DD" \
      -disableAutomaticPackageResolution -skipMacroValidation build -quiet) || { echo "build failed" >&2; exit 1; }
    APP=$DD/Build/Products/Debug-iphonesimulator/Otto.app
  fi
  # A fresh install is slow to open the first time: warm it up so the first shot is the app, not the home screen.
  xcrun simctl uninstall "$DEV" $ID >/dev/null 2>&1; xcrun simctl install "$DEV" "$APP"
  xcrun simctl launch "$DEV" $ID -onboarded YES -noNotificationPrompt >/dev/null; sleep 8; xcrun simctl terminate "$DEV" $ID >/dev/null 2>&1
  xcrun simctl status_bar "$DEV" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  xcrun simctl privacy "$DEV" grant microphone $ID 2>/dev/null || true
fi

clean() {
  local data; data=$(xcrun simctl get_app_container "$DEV" $ID data 2>/dev/null) || return 0
  rm -rf "$data/Library/Application Support/"* "$data/Library/Caches/"* 2>/dev/null
  xcrun simctl spawn "$DEV" defaults delete $ID >/dev/null 2>&1
  # the walkie hint pops on any launch more than two months after the last; only -walkieHint shows it
  xcrun simctl spawn "$DEV" defaults write $ID walkieHintAt -float "$(date +%s)" >/dev/null 2>&1
}

# shot <screen> <state> <wait> <note> [launch args...]
shot() {
  local screen=$1 state=$2 wait=$3 note=$4; shift 4
  [ $LIST = 1 ] && { echo "$screen-$state"; return 0; }
  [[ "$screen-$state" =~ $FILTER ]] || return 0
  for theme in $THEMES; do
    xcrun simctl ui "$DEV" appearance $theme
    xcrun simctl terminate "$DEV" $ID >/dev/null 2>&1
    sleep 0.5
    clean
    xcrun simctl launch "$DEV" $ID "$@" >/dev/null
    sleep "$wait"
    [[ " $* " == *" -pipsFixture "* ]] && sleep 1.5   # the list, then Otto's thread pushed over it
    local f="$screen-$state-$theme.png"
    xcrun simctl io "$DEV" screenshot "$OUT/$f" >/dev/null 2>&1 && printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$screen" "$state" "$theme" "$note" >> "$TSV.new"
    echo "$f"
  done
}

N=-noNotificationPrompt
B="-onboarded YES $N"
# Pips on, as in the real app: the conversations list at the root and Otto's thread pushed over it.
O="$B -pipsFixture -pipsScreen otto"
DEAD="-onboarded YES -serverURL http://127.0.0.1:9 -serverToken demo-token -pipsFixture -pipsScreen otto"

# --- First launch -----------------------------------------------------------------
shot onboarding hello 7 "Welcome page" -onboarding $N
shot onboarding connect 4 "Pair with the Mac (no camera in the simulator, so typing is the main button)" -onboarding -onboardingStep 1 $N
shot onboarding connect-manual 4 "Typed server address and token" -onboarding -onboardingStep 1 -connectManual $N
shot onboarding connect-error 4 "Pairing failed: Mac unreachable" -onboarding -onboardingStep 1 -connectManual -connectProblem $N
shot onboarding notify 4 "Notifications step" -onboarding -onboardingStep 2 $N
shot onboarding talk 4 "Talk / Siri step" -onboarding -onboardingStep 3 $N
shot onboarding share 4 "Share-sheet step" -onboarding -onboardingStep 4 $N
shot onboarding awake 4 "Stay-connected step" -onboarding -onboardingStep 5 $N
shot onboarding done 4 "All set" -onboarding -onboardingStep 6 $N
shot launch connecting 4 "Splash while the Mac is being reached" $DEAD $N -holdSplash

# --- Otto's thread -------------------------------------------------------------------
shot chat empty 6 "Fresh thread, nothing yet" $O -emptyThread
shot chat normal 6 "Everyday thread: brief, draft with buttons, voice notes" $O -demoThread
shot chat long-a 6 "Long thread, part 1: quote reply, draft buttons, voice both ways, photo with tapback, link, terminal line" $O -longThread a
shot chat long-b 6 "Long thread, part 2: card, schedule chip, recorded chips, file, code chip, failed and pending sends" $O -longThread b
shot chat actions 6 "Reply quote, long text, photo, voice note, link preview, tapbacks" $O -actionsLab
shot chat cards-all 6 "Every card type (bottom of the thread)" $O -cardThread
shot chat cards-mixed 6 "Mixed card: stat, bars, list, progress, actions" $O -cardThread mixed
shot chat cards-table-timeline 6 "Table and timeline cards" $O -cardThread table,timeline
shot chat cards-checklist-keyvalue 6 "Checklist and key-value cards" $O -cardThread checklist,keyvalue
shot chat cards-image-text 6 "Image and text cards" $O -cardThread image,text
shot chat schedule-recorded 6 "Schedule chip, recorded chips (money, loop, memory, place, calendar write), wallet passes" $O -scheduleThread
shot chat long-bubbles 6 "Long wrapping bubbles, links, terminal line" $O -seedThread
shot chat thinking 6 "Otto typing with its live status line" $O -demoThread -thinking
shot chat thinking-todos 6 "Typing bubble with a to-do list" $O -demoThread -thinking -todos
shot chat todos-none 6 "No open to-dos: nothing over the composer" $O -demoThread
shot chat todos-two 6 "Two open to-dos while Otto is idle: the pill over the composer" $O -demoThread -openTodos
shot chat todos-one 6 "A single open to-do" $O -demoThread -openTodos one
shot chat todos-many 6 "Worst case opened: 30 to-dos, a 120-character one in progress; six shown, the rest counted" $O -demoThread -openTodos many -todosOpen
shot chat todos-expanded 6 "To-do pill tapped open: the one in progress first" $O -demoThread -openTodos -todosOpen
shot chat todos-while-typing 6 "Otto working: the list is in the bubble, the pill steps aside" $O -demoThread -thinking -todos -openTodos
shot chat browser-tile 6 "Otto in Chrome: the live page tile over the thinking orb" $O -demoThread -thinking -browserTile
shot chat browser-tile-private 6 "Sign-in page: caption only, no picture" $O -demoThread -thinking -browserTile private
shot chat browser-tile-long 6 "Worst case: the server's 100-character caption, two lines kept" $O -demoThread -thinking -todos -browserTile long
shot chat browser-tile-idle 6 "Tile still up after the reply ended (done comes 20 s later)" $O -demoThread -browserTile
shot media browser-full 6 "Browser tile tapped: the page full screen" $O -demoThread -thinking -browserTile -browserOpen
shot chat offline 6 "Server unreachable: Otto asleep, reconnecting" $O -demoThread -offline
shot chat offline-pending 6 "Dead server with a send waiting: Will send when back online" $DEAD $N -longThread b
shot chat offline-empty 15 "Real dead server: empty thread, asleep" $DEAD $N -emptyThread
shot chat update-available 6 "Update button in the header" $O -demoThread -fakeUpdate
shot chat walkie-hint 7 "Hold-for-walkie-talkie hint" $O -demoThread -walkieHint
shot chat flight-banner 6 "Flight-day card under the header" $O -demoThread -mockGate
shot chat call-banner 7 "Live call banner under the header" $O -demoThread -mockCalls
shot composer focused 6 "Composer focused with text" $O -demoThread -kbdDemo "running 10 min late, start without me"
shot composer long-draft 6 "Composer grown by a long draft" $O -demoThread -seedDraft
shot composer attachments 6 "Two photos waiting in the composer" $O -demoThread -seedAttachments
shot composer recording 6 "Recording a voice note" $O -demoThread -recordDemo

# --- Sheets over the thread -----------------------------------------------------------
shot sheet otp-drawer 6 "One-time code drawer" $O -demoThread -otpDemo
shot sheet payment 6 "Payment approval" $O -demoThread -paymentDemo
shot sheet payment-receipt 6 "Payment approved: printed receipt" $O -demoThread -paymentDemo -receiptDemo
shot sheet change-approval 6 "Approve a change to Otto's core" $O -demoThread -approvalDemo
shot sheet boarding-pass 11 "Flight-day boarding pass" $O -demoThread -mockGate -openGate
shot sheet live-call 8 "A call Otto is placing, live transcript" $O -demoThread -mockCalls -openCall
shot media viewer 6 "Full-screen photo viewer" $O -mediaThread -media
shot walkie open 9 "Walkie-talkie" $O -demoThread -walkie
shot call web-call-failed 25 "Web call that couldn't connect" $O -demoThread -call -vapiPublicKey demo -vapiAssistantId demo -vapiHost 127.0.0.1

# --- Search ---------------------------------------------------------------------------
shot search pulled-open 6 "Search bar pulled down, keyboard up" $O -demoThread -searchFocus -search ""
shot search results 6 "Matches for a word" $O -demoThread -search tuesday
shot search results-typing 6 "Matches while typing" $O -demoThread -searchFocus -search boiler
shot search no-results 6 "Nothing matches" $O -demoThread -search unicorno
shot search jumped 9 "Tapped a match: thread scrolled to it, lit up" $O -actionsLab -farQuote -search boiler -searchJump

# --- Contact card (details) -------------------------------------------------------------
shot details card 6 "Contact card: today, sections, settings, server" $O -details
shot details snoozed 6 "Snoozed, with what's held" $O -details -snoozed
shot details server-check-failed 10 "Server check under the token: can't reach" $DEAD $N -details -checkServer
for s in Loops Schedules Calls Memory People Money Trips Passport Packages Status Devices Glasses Settings; do
  l=$(echo $s | tr A-Z a-z)
  extra=""; [ $s = Calls ] && extra=-mockCalls
  shot "$l" list 6 "$s screen" $O -details -screen $s $extra
done
for t in Unasked Changes Jobs Triggers; do
  shot activity "$(echo $t | tr A-Z a-z)" 6 "Activity, $t tab" $O -details -screen Activity -activityTab $t
done
for s in Loops Schedules Calls People Trips Packages; do
  shot "$(echo $s | tr A-Z a-z)" empty 6 "$s with nothing in it" $O -details -screen $s -emptyDash
done
shot activity jobs-empty 6 "No background jobs" $O -details -screen Activity -activityTab Jobs -emptyDash
shot calls error 6 "Can't reach your Mac (no callbot)" $O -details -screen Calls
shot loops error 12 "Can't reach your Mac (dead server)" $DEAD $N -details -screen Loops

# --- Pips and groups ---------------------------------------------------------------------
P="$B -pipsFixture -pipsScreen"
shot pips conversations 6 "Conversations list" $P conversations
shot pips otto-only 6 "Only Otto: the empty conversations hint" $P otto-only
shot pips otto-thread 7 "Otto's thread with pips: handoff lines" $P otto
shot pips otto-started-group 7 "Otto starts a group: group link bubble" $P otto-group
shot pips pip-thread 8 "A pip's own thread (Code, needs you)" $P conversations -pipsOpen code
shot pips group-thread 7 "Group thread with @mention draft and activity" $P group
shot pips new-group 7 "A group Otto just made" $P new-group
shot pips search-jump 8 "Search hit opened deep in a group" $P jump
shot pips handoff 8 "Handoff sheet: Otto asked Code" $P handoff
shot pips handoff-you 8 "Handoff sheet: you asked School" $P handoff-you
shot pips handoff-you-failed 8 "Handoff sheet: your ask failed" $P handoff-you-failed
shot pips handoff-failed 8 "Handoff sheet: School didn't wake" $P failed
shot pips pip-details 8 "Pip details sheet" $P details
shot pips pip-edit 8 "Editing a pip" $P edit-pip
shot pips pip-edit-schedule 9 "Editing a pip's schedule" $P edit-schedule
shot pips pip-delete-confirm 8 "Delete pip confirmation" $P pip-confirm
shot pips create-pip 9 "New pip sheet" $P create-pip
shot pips create-pip-failed 9 "New pip: server refused" $P create-fail
shot pips create-group 7 "New group sheet" $P create-group
shot pips group-card 8 "Group details sheet" $P group-card
shot pips group-changed 9 "Group renamed, member added and removed" $P group-changed
shot pips group-delete-confirm 8 "Delete group confirmation" $P group-confirm
shot pips group-rename-failed 9 "Group rename on a server without the routes" $P group-fail
shot pips faces 6 "Every face in every pose" $P faces

# --- System prompts ---------------------------------------------------------------------
if [ $LIST = 1 ]; then echo permissions-notifications
elif [[ "permissions-notifications" =~ $FILTER ]]; then
  for theme in $THEMES; do
    xcrun simctl ui "$DEV" appearance $theme
    xcrun simctl uninstall "$DEV" $ID; xcrun simctl install "$DEV" "$APP"
    xcrun simctl launch "$DEV" $ID -onboarded YES -demoThread -pipsFixture -pipsScreen otto >/dev/null
    sleep 14
    f=permissions-notifications-$theme.png
    xcrun simctl io "$DEV" screenshot "$OUT/$f" >/dev/null 2>&1 && printf '%s\t%s\t%s\t%s\t%s\n' "$f" permissions notifications $theme "System notification permission alert on first launch" >> "$TSV.new"
    echo $f
  done
fi

[ $LIST = 1 ] && exit 0
[ -f "$TSV" ] && grep -v -F -f <(cut -f1 "$TSV.new") "$TSV" >> "$TSV.new"
mv "$TSV.new" "$TSV"
echo "$(grep -c . "$TSV") shots in $OUT"
