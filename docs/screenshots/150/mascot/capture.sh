#!/usr/bin/env bash
# Issue #150 slice 11's evidence, from the running app, at the size the other slices keep, at the default text size (`large`) and
# the largest (ax5): the launch screen, the splash and the pages the finch is on, the icons on the home screen and the finch at
# true pixels. ICON_SHOTS is a folder for the full-size pictures the icon sheets are made from. Leaves the simulator's text size at
# `large` and its appearance dark. Needs uv and ffmpeg.
#
#   ICON_SHOTS=<folder> docs/screenshots/150/mascot/capture.sh <simulator UDID> <before app> before-
#   ICON_SHOTS=<folder> docs/screenshots/150/mascot/capture.sh <simulator UDID> <app>
#   TEST_RUNNER_BIRDJOURNAL_ICON_SHOTS=<folder> BIRDJOURNAL_SIMULATOR=<name> scripts/build-and-test.sh -only-testing:BirdJournalUITests/AppIconHomeScreenUITests
#   ICON_SHOTS=<folder> docs/screenshots/150/mascot/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/mascot"
icon_shots="${ICON_SHOTS:?give ICON_SHOTS, a folder for the full-size pictures}"
mkdir -p "$icon_shots"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
    }
    for picture in "$icon_shots"/home-*.png; do
        sips -Z 800 -s format jpeg -s formatOptions 78 "$picture" --out "$out/$(basename "${picture%.png}").jpg" >/dev/null
    done
    ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
    for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
        "$ictool" "$repo_root/BirdJournal/MyBirdJournal-HouseFinch.icon" --export-image --output-file "$icon_shots/r-$rendition.png" \
            --platform iOS --rendition "$rendition" --width 180 --height 180 --scale 1 --tint-color 0.25 --tint-strength 0.75 >/dev/null
    done
    uv run -q "$out/icon-sheets.py" "$icon_shots" "$out" "$repo_root/art/mascot/icons" "$repo_root/BirdJournal/BirdJournal/Assets.xcassets/AppIconPreview"
    sheet before-after-launch 4 before-launch-dark.jpg launch-dark.jpg before-splash-dark.jpg splash-dark.jpg before-launch-light.jpg launch-light.jpg before-splash-light.jpg splash-light.jpg
    sheet before-after-states 4 before-empty-dark.jpg empty-dark.jpg before-account-dark.jpg account-dark.jpg before-empty-light.jpg empty-light.jpg before-account-light.jpg account-light.jpg
    sheet before-after-ax5 6 before-splash-ax5.jpg splash-ax5.jpg before-empty-ax5.jpg empty-ax5.jpg before-account-ax5.jpg account-ax5.jpg
    sheet settings-icons 3 icons-dark.jpg icons-light.jpg icons-ax5.jpg
    sheet home-screen 3 home-red-tailed-hawk.jpg home-blue-bird.jpg home-great-egret.jpg home-house-finch.jpg home-prothonotary-warbler.jpg home-stellers-jay.jpg
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
prefix="${3:-}"
bundle="com.matthewcelia.mybirdjournal"
slow="${CAPTURE_SLOW:-0}"

trap 'xcrun simctl ui "$udid" content_size large; xcrun simctl ui "$udid" appearance dark; xcrun simctl status_bar "$udid" clear 2>/dev/null || true' EXIT

# Installed over another build, the launch screen draws from the last build's asset catalog until the simulator restarts: a
# picture under a new name comes up blank. So restart it after the install, with the app in place.
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl shutdown "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

screenshot() {  # name
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$prefix$1.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$prefix$1.jpg" >/dev/null
    echo "$prefix$1"
}

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
    screenshot "$name"
}

# A launch that waits for a debugger stays on the launch screen, so it can be photographed.
launch_screen() {  # name
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch --wait-for-debugger "$udid" "$bundle" >/dev/null
    sleep $((4 + slow))
    screenshot "$1"
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
}

# The splash lasts about a second and a half: a recording of the launch, and a frame from when its title has come in.
splash() {  # name
    local movie
    movie="$(mktemp -d)/launch.mp4"
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl io "$udid" recordVideo --codec=h264 --force "$movie" >/dev/null 2>&1 &
    local recorder=$!
    sleep 2
    xcrun simctl launch "$udid" "$bundle" -inMemoryAlbum YES >/dev/null
    sleep $((5 + slow))
    kill -INT "$recorder"
    wait "$recorder" || true
    "$out/pick-splash-frame.sh" "$movie" "$out/$prefix$1.jpg"
    sips -Z 800 -s formatOptions 78 "$out/$prefix$1.jpg" >/dev/null
    echo "$prefix$1"
}

# The finch at the simulator's true pixels, cropped round it, so the glasses are seen as a phone shows them.
finch() {  # name, crop as width height x y
    xcrun simctl io "$udid" screenshot --type=png "$icon_shots/$1.png" >/dev/null 2>&1
    sips -c "$3" "$2" --cropOffset "$5" "$4" -s format jpeg -s formatOptions 88 "$icon_shots/$1.png" --out "$out/$1.jpg" >/dev/null
    echo "$1"
}

empty=(-inMemoryAlbum YES)

xcrun simctl ui "$udid" content_size large
for appearance in dark light; do
    xcrun simctl ui "$udid" appearance "$appearance"
    launch_screen "launch-$appearance"
    splash "splash-$appearance"
    shot "empty-$appearance" 9 "${empty[@]}" -autoScreen journal
    if [[ -z "$prefix" && "$appearance" == dark ]]; then finch finch-true-pixels-large 720 600 300 500; fi
    shot "account-$appearance" 8 "${empty[@]}" -fakeAccount signedOut -autoScreen account
    if [[ -z "$prefix" ]]; then shot "icons-$appearance" 8 "${empty[@]}" -autoScreen app-icon; fi
done

xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
splash splash-ax5
shot empty-ax5 9 "${empty[@]}" -autoScreen journal
if [[ -z "$prefix" ]]; then finch finch-true-pixels-ax5 920 900 200 500; fi
shot account-ax5 8 "${empty[@]}" -fakeAccount signedOut -autoScreen account
if [[ -z "$prefix" ]]; then shot icons-ax5 8 "${empty[@]}" -autoScreen app-icon; fi

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true

# The build's icon on the home screen, for the sheet that has the new ones beside it.
if [[ -n "$prefix" ]]; then
    sleep 3
    xcrun simctl io "$udid" screenshot --type=png "$icon_shots/before-home.png" >/dev/null 2>&1
fi
