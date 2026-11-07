#!/usr/bin/env bash
# Issue #150 slice 10's evidence: the recap, its share image, and the Live Activity's and the widget's own views drawn in the
# app (`-autoScreen glance`), at half size, in dark and light and at the largest text size. Needs a debug build and the test
# clip. Grants the simulator location (Griffith Park) and the microphone, and leaves its text size at `large`.
#
#   docs/screenshots/150/after-run/capture.sh <simulator UDID> <app path>
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
#
# The real Island, Lock Screen and Home Screen widget come from a test that drives the system's own UI, run first:
#
#   TEST_RUNNER_BIRDJOURNAL_CAPTURE_DIR=<folder> BIRDJOURNAL_SIMULATOR=<name> scripts/build-and-test.sh -only-testing:BirdJournalUITests/GlanceCaptureUITests
#   docs/screenshots/150/after-run/capture.sh --real <folder>
#
# and the sheet of them all with `--sheets`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/after-run"
half() {  # png, name
    sips -s format jpeg -s formatOptions 80 --resampleWidth 603 "$1" --out "$out/$2.jpg" >/dev/null
}

if [[ "${1:-}" == "--real" ]]; then
    for name in activity-island-compact activity-island-expanded activity-lock-screen activity-recap-after-lock-stop widget-home widget-opened; do
        half "${2:?give the folder}/$name.png" "real-$name"
    done
    exit 0
fi

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
    }
    sheet recap 4 recap-dark.jpg recap-light.jpg recap-empty-dark.jpg recap-ax5.jpg
    sheet share-image 2 share-image-dark.jpg share-image-light.jpg
    sheet real 4 real-activity-island-compact.jpg real-activity-island-expanded.jpg real-activity-lock-screen.jpg real-activity-recap-after-lock-stop.jpg real-widget-home.jpg real-widget-opened.jpg
    sheet glance 4 activity-dark.jpg activity-light.jpg widgets-dark.jpg widgets-light.jpg
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl launch "$udid" "$bundle" -inMemoryAlbum YES -collectionIntroShown YES -autoLocation griffith -autoPhoneListening "$clip" "$@" >/dev/null
    sleep $((wait + slow))
    xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
    half "$out/$name.png" "$name"
    rm "$out/$name.png"
}

xcrun simctl ui "$udid" content_size large
for appearance in dark light; do
    xcrun simctl ui "$udid" appearance "$appearance"
    shot "recap-empty-$appearance" 60 -autoScreen recap
    shot "recap-$appearance" 60 -autoScreen recap -autoRecapAdd YES -stitchInSeconds 0 -saveRecapImage YES
    sips -s format jpeg -s formatOptions 80 --resampleWidth 810 "$(xcrun simctl get_app_container "$udid" "$bundle" data)/tmp/recap-share.png" --out "$out/share-image-$appearance.jpg" >/dev/null
    shot "activity-$appearance" 8 -autoScreen glance
    shot "widgets-$appearance" 12 -autoScreen glance -glancePage widgets -seedBoard YES
done
xcrun simctl ui "$udid" content_size accessibility-medium
shot widgets-large-text 12 -autoScreen glance -glancePage widgets -seedBoard YES
shot activity-large-text 8 -autoScreen glance
xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot recap-ax5 60 -autoScreen recap -autoRecapAdd YES -stitchInSeconds 0
xcrun simctl ui "$udid" content_size large
