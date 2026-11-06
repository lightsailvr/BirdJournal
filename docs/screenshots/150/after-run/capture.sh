#!/usr/bin/env bash
# Issue #150 slice 10's evidence: the recap, its share image, and the Live Activity's and the widget's own views drawn in the
# app (`-autoScreen glance`), at half size, in dark and light and at the largest text size. Needs a debug build and the test
# clip. Grants the simulator location (Griffith Park) and the microphone, and leaves its text size at `large`.
#
#   docs/screenshots/150/after-run/capture.sh <simulator UDID> <app path>
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/after-run"
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
    sips -s format jpeg -s formatOptions 80 --resampleWidth 603 "$out/$name.png" --out "$out/$name.jpg" >/dev/null
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
xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot recap-ax5 60 -autoScreen recap -autoRecapAdd YES -stitchInSeconds 0
xcrun simctl ui "$udid" content_size large
