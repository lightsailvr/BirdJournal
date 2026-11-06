#!/usr/bin/env bash
# Issue #150 slice 11's evidence: the launch screen, the splash and the pages the finch is on, from the running app, at half
# size, at the default text size (`large`) and the largest (ax5). Give it a build, and the prefix `before-` for one from before
# the mascot. Leaves the simulator's text size at `large` and its appearance dark. The icons on the home screen come from a UI
# test, which also takes the Settings page (`AppIconHomeScreenUITests`, `TEST_RUNNER_BIRDJOURNAL_ICON_SHOTS=<folder>`), and
# `icon-sheets.py` sets them side by side at true pixels.
#
#   docs/screenshots/150/mascot/capture.sh <simulator UDID> <app path> [before-]
#   docs/screenshots/150/mascot/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/mascot"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
    }
    sheet before-after-launch 4 before-launch-dark.jpg launch-dark.jpg before-splash-dark.jpg splash-dark.jpg before-launch-light.jpg launch-light.jpg before-splash-light.jpg splash-light.jpg
    sheet before-after-states 4 before-empty-dark.jpg empty-dark.jpg before-account-dark.jpg account-dark.jpg before-empty-light.jpg empty-light.jpg before-account-light.jpg account-light.jpg
    sheet before-after-ax5 4 before-empty-ax5.jpg empty-ax5.jpg before-account-ax5.jpg account-ax5.jpg
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
    echo "$prefix$1"
}

empty=(-inMemoryAlbum YES)

xcrun simctl ui "$udid" content_size large
for appearance in dark light; do
    xcrun simctl ui "$udid" appearance "$appearance"
    launch_screen "launch-$appearance"
    splash "splash-$appearance"
    shot "empty-$appearance" 9 "${empty[@]}" -autoScreen journal
    shot "account-$appearance" 8 "${empty[@]}" -fakeAccount signedOut -autoScreen account
done

xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot empty-ax5 9 "${empty[@]}" -autoScreen journal
shot account-ax5 8 "${empty[@]}" -fakeAccount signedOut -autoScreen account

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
