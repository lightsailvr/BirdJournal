#!/usr/bin/env bash
# Issue #150 slice 3's evidence: the set's name as a menu, the modes, the reveal, the peek and frames of the Lift, from the running
# app, at half size, at the default text size (`large`) and the largest (ax5). Needs the test clip (`scripts/download-clips.sh`), uv
# and ffmpeg. Leaves the simulator's text size at `large`.
#
#   docs/screenshots/150/feel/capture.sh <simulator name>
#   docs/screenshots/150/feel/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait. The Lift's frames are picked by
# hand from the recordings: CAPTURE_RAW=<folder> keeps them, LIFT_ONLY=1 does only the recordings.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/feel"
references="${FG_REFERENCES:-/Users/matthewcelia/Documents/repos/BirdJournal/output/ux-audit/reference}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "$@"
    }
    in_out() { local s; for s in "$@"; do printf '%s\n' "$out/$s.jpg"; done; }
    collect() { local line; while IFS= read -r line; do shots+=("$line"); done; }
    shots=("$references/2-listening-run.png"); collect < <(in_out listening-dark stop-toast-ax5 reveal-undo-dark); sheet reference-outlined 4 "${shots[@]}"
    shots=(); collect < <(in_out board-dark menu-dark board-scrolled-dark search-dark mode-fade-dark sightings-dark board-light board-ax5); sheet set-menu-and-modes 8 "${shots[@]}"
    shots=(); collect < <(in_out reveal-dark reveal-shared-dark reveal-undo-dark reveal-light reveal-ax5 sewing-dark); sheet reveal 6 "${shots[@]}"
    shots=(); collect < <(in_out lift-1 lift-2 lift-3 lift-4 lift-5 lift-6); sheet lift 6 "${shots[@]}"
    shots=(); collect < <(in_out lift-reduced-1 lift-reduced-2 lift-reduced-3 lift-reduced-4 lift-reduced-5 lift-reduced-6); sheet lift-reduce-motion 6 "${shots[@]}"
    shots=(); collect < <(in_out modes-1 modes-2 modes-3 modes-4 modes-5 modes-6); sheet modes-from-a-scrolled-board 6 "${shots[@]}"
    shots=(); collect < <(in_out foot-1 foot-2 foot-3 foot-4 foot-5 foot-6); sheet foot-of-the-board 6 "${shots[@]}"
    shots=(); collect < <(in_out sheet-1 sheet-2 sheet-3 sheet-4); sheet plain-push-in-a-sheet 4 "${shots[@]}"
    shots=(); collect < <(in_out peek-dark board-contrast splash-dark); sheet peek-contrast-splash 3 "${shots[@]}"
    exit 0
fi

name="${1:?give the simulator name}"
udid="$(xcrun simctl list devices | sed -n "s/^ *$name (\([0-9A-F-]*\)).*/\1/p" | sed -n 1p)"
[[ -n "$udid" ]] || { echo "no simulator named $name" >&2; exit 1; }
bundle="com.matthewcelia.mybirdjournal"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
slow="${CAPTURE_SLOW:-0}"
raw="${CAPTURE_RAW:-$(mktemp -d)}"

# Whatever stops this, the simulator goes back to its defaults: left at ax5, it fails UI tests that have nothing to do with it.
restore() {
    xcrun simctl ui "$udid" content_size large
    xcrun simctl ui "$udid" appearance dark
    xcrun simctl ui "$udid" increase_contrast disabled 2>/dev/null || true
    xcrun simctl status_bar "$udid" clear 2>/dev/null || true
    [[ -n "${CAPTURE_RAW:-}" ]] || rm -rf "$raw"
}
trap restore EXIT

half() {  # from, name
    sips -s format jpeg -s formatOptions 78 -Z 800 "$1" --out "$out/$2.jpg" >/dev/null
    echo "$2"
}

# What takes a finger, through the UI tests. They build and install the app, so this comes first.
if [[ -z "${LIFT_ONLY:-}" ]]; then
    BIRDJOURNAL_SIMULATOR="$name" TEST_RUNNER_BIRDJOURNAL_FEEL_SHOTS="$raw" BIRDJOURNAL_QUIET_MINUTES=10 \
        "$repo_root/scripts/build-and-test.sh" \
        -only-testing:BirdJournalUITests/FeelCaptureUITests/testTheSetsMenuAndThePeek \
        -only-testing:BirdJournalUITests/FeelCaptureUITests/testAModePartWayThroughItsFade \
        -only-testing:BirdJournalUITests/FeelCaptureUITests/testTheRevealWithUndoOpen \
        -only-testing:BirdJournalUITests/FeelCaptureUITests/testAScrolledBoard \
        -only-testing:BirdJournalUITests/FeelUITests/testStopWrapsAndWorksUnderAToastAtTheLargestText
    [[ -f "$raw/stop-toast-ax5.png" ]] && half "$raw/stop-toast-ax5.png" stop-toast-ax5
    for shot in menu peek mode-fade reveal-undo board-scrolled search; do
        [[ -f "$raw/$shot.png" ]] && half "$raw/$shot.png" "$shot-dark"
    done
fi
xcrun simctl boot "$udid" 2>/dev/null || true

# Recordings, each to frames in a folder of its own, picked from by hand. The motion only shows there.
record() {  # name, test
    local folder="$raw/$1"
    mkdir -p "$folder"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl io "$udid" recordVideo --codec=h264 --force "$folder/$1.mp4" & local recording=$!
    BIRDJOURNAL_SIMULATOR="$name" TEST_RUNNER_BIRDJOURNAL_FEEL_SHOTS="$raw" "$repo_root/scripts/build-and-test.sh" "-only-testing:BirdJournalUITests/FeelCaptureUITests/$2" || true
    kill -INT "$recording" 2>/dev/null || true
    wait "$recording" 2>/dev/null || true
    [[ -f "$folder/$1.mp4" ]] && ffmpeg -loglevel error -y -i "$folder/$1.mp4" -vf "fps=20,scale=402:-1" "$folder/frame-%04d.jpg"
}
record lift testTheLift
record modes testRecordAModeChange
record foot testRecordTheFoot
record sheet testRecordInASheet
xcrun simctl boot "$udid" 2>/dev/null || true

[[ -z "${LIFT_ONLY:-}" ]] || exit 0

xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
    xcrun simctl io "$udid" screenshot --type=png "$raw/$name.png" >/dev/null 2>&1
    half "$raw/$name.png" "$name"
}

seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
phoebe=(-autoCardSpecies "Sayornis nigricans")
reveal=(-reduceMotion YES "${phoebe[@]}" -autoScreen reveal)

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
shot board-dark      10 "${seeded[@]}" -autoScreen cards
shot sightings-dark   9 "${seeded[@]}" -autoScreen sightings
shot reveal-dark     10 "${seeded[@]}" "${reveal[@]}"
shot reveal-shared-dark 10 "${seeded[@]}" -fakeAccount signedIn -fakeCircles some "${reveal[@]}"
shot sewing-dark      5 "${seeded[@]}" "${phoebe[@]}" -autoScreen reveal -stitchInSeconds 60
shot listening-dark  45 -inMemoryAlbum YES -collectionIntroShown YES -autoPhoneListening "$clip" -autoLocation griffith -autoScreen listening
shot splash-dark      3 -inMemoryAlbum YES -resetLaunchSplash YES -launchSplashSeconds 30

xcrun simctl ui "$udid" appearance light
shot board-light     10 "${seeded[@]}" -autoScreen cards
shot reveal-light    10 "${seeded[@]}" "${reveal[@]}"

xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" increase_contrast enabled
shot board-contrast  10 "${seeded[@]}" -autoScreen cards
xcrun simctl ui "$udid" increase_contrast disabled

xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot board-ax5       10 "${seeded[@]}" -autoScreen cards
shot reveal-ax5      10 "${seeded[@]}" "${reveal[@]}"

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
