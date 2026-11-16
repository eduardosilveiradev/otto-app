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
    # -wipeDefaults: the app's own saved settings live in its container, where `defaults delete` above doesn't
    # reach; without it a draft or a pasted pairing link from one state shows up in the next.
    xcrun simctl launch "$DEV" $ID -wipeDefaults "$@" >/dev/null
    sleep "$wait"
    [[ " $* " == *" -pipsFixture "* ]] && sleep 1.5   # the list, then Otto's thread pushed over it
    local f="$screen-$state-$theme.png"
    xcrun simctl io "$DEV" screenshot "$OUT/$f" >/dev/null 2>&1
    # A launch that hadn't drawn yet is a black frame of about 72 KB (the sparest real screen is 100): wait as long again and retake it.
    [ "$(stat -f%z "$OUT/$f" 2>/dev/null || echo 0)" -lt 85000 ] && { sleep "$wait"; xcrun simctl io "$DEV" screenshot "$OUT/$f" >/dev/null 2>&1; }
    [ -f "$OUT/$f" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$screen" "$state" "$theme" "$note" >> "$TSV.new"
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
shot chat deleted-quote 6 "Otto deleted the message a reply quotes: its bubble is gone and the quote reads Message deleted" $O -deleteDemo
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
shot chat spinner-think 6 "Thinking mark, think (Wobble): a plain Thinking step" $O -demoThread -thinking -thinkingStatus Thinking
shot chat spinner-look 6 "Thinking mark, look (Mull): reading a file" $O -demoThread -thinking -thinkingStatus "Reading ChatView.swift"
shot chat spinner-away 6 "Thinking mark, away (Pip): waiting on the web" $O -demoThread -thinking -thinkingStatus "Searching the web for tangerine"
shot chat spinner-do 6 "Thinking mark, do (Hop): running a command" $O -demoThread -thinking -thinkingStatus "Running tests"
shot chat spinner-idle 6 "Thinking mark held on idle: the still face" $O -demoThread -thinking -spinnerKind idle
shot chat spinner-done 6 "Thinking mark held on done: settled, after its squash and blink" $O -demoThread -thinking -spinnerKind done
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
shot media browser-take-over 6 "A page the Mac will hand over: Take over, behind Face ID" $O -demoThread -thinking -browserTile control -browserOpen
shot media browser-holding 6 "The page in your hands: taps go to it, with typing, keys and Hand back" $O -demoThread -thinking -browserTile control -browserOpen -browserHold
shot chat voice-speed 6 "A voice reply paused part-way: the speed button (1x, 1.5x, 2x) beside its length" $O -demoThread -voicePaused
shot chat draft-unnamed 6 "A draft the Mac sent without saying who it goes to: the card says so above Send" $O -demoThread -draftBare
shot chat offline 6 "Server unreachable: Otto asleep, reconnecting" $O -demoThread -offline
shot chat no-network 6 "This phone has no network at all: the header says so, not that the Mac is out of reach" $O -demoThread -offline -noNetwork
shot chat offline-pending 13 "Dead server with a send waiting: Will send when back online" $DEAD $N -longThread b
shot chat offline-empty 15 "Real dead server: empty thread, asleep" $DEAD $N -emptyThread
shot chat update-available 6 "Update button in the header" $O -demoThread -fakeUpdate
shot chat walkie-hint 7 "Hold-for-walkie-talkie hint" $O -demoThread -walkieHint
shot chat call-row 6 "A call with Otto that just ended: its line in the thread, with how long it ran" $O -demoThread -callRow
shot sheet call-transcript 7 "The call's line tapped: what was said" $O -demoThread -callRow -callTranscript
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
shot sheet change-approval-detail 6 "A change whose detail is its lines, not a git stat (the memory clean-up)" $O -demoThread -approvalDemo diet
shot sheet approval-scopes 6 "An ask the Mac will take a wider yes for: just this once is picked" $O -demoThread -approvalDemo scopes
shot sheet approval-out-of-reach 6 "An ask while the Mac is out of reach: the buttons are off and a line says nothing can be sent yet" $O -demoThread -approvalDemo scopes -offline
shot sheet schedule 7 "A schedule's page from its chip: when it runs, what Otto will do, and Change or Stop (asked for in the chat)" $O -scheduleThread -scheduleOpen
shot sheet approval-over-card 8 "An approval raised while the contact card is up: its sheet shows over the card, not behind it" $O -details -approvalDemo scopes
shot sheet approval-scopes-always 6 "Always picked: what it means in words, before Face ID" $O -demoThread -approvalDemo scopes -approvalScope always
shot sheet approval-scopes-worst 6 "Worst case: the longest rule a server might name, at an accessibility text size" $O -demoThread -approvalDemo scopes-worst -approvalScope always -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL
shot sheet approval-draft 6 "An email Otto wants to send in your name: every recipient and every word" $O -demoThread -approvalDemo draft
shot sheet approval-draft-worst 6 "Worst case: fourteen recipients, an unbreakable address, no subject, a channel this build can't name" $O -demoThread -approvalDemo draft-worst
shot chat approval-waiting 6 "A payment put off with Later: waiting over the composer, with its time left" $O -demoThread -paymentDemo -approvalLater
shot chat approval-waiting-todos 6 "A change put off with Later takes the to-dos' place until it's answered" $O -demoThread -approvalDemo -approvalLater -openTodos
shot chat approval-waiting-worst 6 "Worst case: a long payee and a five-figure total, at an accessibility text size" $O -demoThread -approvalWorst -approvalLater -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL
shot chat approval-waiting-two 6 "Two put off with Later: the pill shows the newest and says two are waiting" $O -demoThread -paymentDemo -approvalDemo -approvalLater
shot pips approval-in-chats 7 "An approval raised while the Chats list is up: its sheet over the list" $B -pipsFixture -pipsScreen conversations -approvalDemo
shot pips otto-needs-you 7 "Chats with an approval put off: Otto's row says it needs you" $B -pipsFixture -pipsScreen conversations -approvalDemo -approvalLater
shot chat approval-lapsed 6 "It lapsed on the Mac before an answer: the pill says Expired until tapped away" $O -demoThread -paymentDemo -approvalLapsed
shot sheet boarding-pass 11 "Flight-day boarding pass" $O -demoThread -mockGate -openGate
shot sheet live-call 8 "A call Otto is placing, live transcript" $O -demoThread -mockCalls -openCall
shot media viewer 6 "Full-screen photo viewer" $O -mediaThread -media
shot study bubble 6 "Study set Otto sent, in the thread" $O -studyThread
shot study cards 7 "Study set open on its cards" $O -studyThread -studyOpen cards
shot study flipped 7 "A card turned over: Again or Knew it" $O -studyThread -studyOpen flipped
shot study quiz 7 "Quiz with a wrong answer picked" $O -studyThread -studyOpen quiz
shot chat jobs 6 "Coding jobs under Otto's messages: one at work, one waiting on an answer" $O -jobsThread
shot sheet job 7 "Job detail sheet: a job up for review, with its pull request" $O -jobsThread -jobOpen demo-review
shot chat jobs-worst 6 "Worst case: a long title and question with five answers, a state this build doesn't know, a job the Mac no longer lists" $O -jobsThread worst
shot sheet job-worst 7 "Worst case opened: a failure with a long error, thirty steps and a pull request in the thousands" $O -jobsThread worst -jobOpen worst-failed
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
shot details pair-link-pasted 16 "A pairing link pasted into the address: both fields filled and checked at once; the call keys it carried wait for a Mac that answers" $O -details -pasteLink 'otto://pair?server=http://127.0.0.1:9&token=demo-token&vapiKey=pk_demo&vapiAssistant=asst_demo'
shot details notifications-off 9 "Notifications refused on this phone: the card says so beside its settings, with the way to turn them on" $O -details -notificationsOff
shot details server-check-failed 13 "Server check under the token: can't reach" $DEAD $N -details -checkServer
for s in Loops Schedules Calls Memory People Money Trips Passport Packages Status Devices Rules Glasses Settings; do
  l=$(echo $s | tr A-Z a-z)
  extra=""; [ $s = Calls ] && extra=-mockCalls
  shot "$l" list 6 "$s screen" $O -details -screen $s $extra
done
for t in Unasked Changes Jobs Triggers; do
  shot activity "$(echo $t | tr A-Z a-z)" 6 "Activity, $t tab" $O -details -screen Activity -activityTab $t
done
for s in Loops Schedules Calls Memory People Trips Packages Rules; do
  shot "$(echo $s | tr A-Z a-z)" empty 6 "$s with nothing in it" $O -details -screen $s -emptyDash
done
shot rules worst 6 "Worst case: the longest rule, one used once, one used 1,284 times, one with no dates" $O -details -screen Rules -rulesWorst
shot activity jobs-empty 6 "No background jobs" $O -details -screen Activity -activityTab Jobs -emptyDash
shot calls error 6 "Can't reach your Mac (no callbot)" $O -details -screen Calls
shot loops stale 6 "A refresh that failed: the page keeps what it had and says how old it is" $O -details -screen Loops -staleDash
shot settings error 13 "Settings when the Mac doesn't answer" $DEAD $N -details -screen Settings
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
    xcrun simctl io "$DEV" screenshot "$OUT/$f" >/dev/null 2>&1 && printf '%s\t%s\t%s\t%s\t%s\n' "$f" permissions notifications $theme "A fresh install opened straight into the thread: no system alert here, notifications are asked for in onboarding" >> "$TSV.new"
    echo $f
  done
fi

[ $LIST = 1 ] && exit 0
[ -f "$TSV" ] && grep -v -F -f <(cut -f1 "$TSV.new") "$TSV" >> "$TSV.new"
mv "$TSV.new" "$TSV"
echo "$(grep -c . "$TSV") shots in $OUT"
