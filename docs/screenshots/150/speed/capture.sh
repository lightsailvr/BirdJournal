#!/usr/bin/env bash
# Issue #150 slice 4's screenshots: nothing should look different except the redacted placeholder, so these are the
# placeholder (with the server slowed down) and the same screens drawn from the cache with no connection at all, in dark, in
# light and at the largest text size. Half size, JPEG. Leaves the simulator's text size at `large`.
#
#   docs/screenshots/150/speed/capture.sh <simulator UDID> <app path>
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait, and CAPTURE_ONLY=<prefix>
# takes only the shots whose names start with it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/speed"
udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    [[ -z "${CAPTURE_ONLY:-}" || "$name" == "$CAPTURE_ONLY"* ]] || return 0
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$name.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$name.jpg" >/dev/null
    echo "$name"
}

base=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn)
cache=(-circleCacheFile speed-capture)

all() {  # suffix
    local suffix="$1"
    shot "placeholder-list-$suffix"  6 "${base[@]}" -fakeCircles some -fakeCircleLatency 60 -autoScreen circles
    # Compare opens over a Guild's page, so with the slow server its own read is the one still out.
    shot "placeholder-compare-$suffix" ${COMPARE_WAIT:-26} "${base[@]}" -fakeCircles some -fakeCircleLatency 5 -autoScreen compare
    # Reads the page once so it's in the cache, then draws it again offline.
    shot "cached-fill-$suffix"      10 "${base[@]}" -fakeCircles some "${cache[@]}" -autoScreen circle
    shot "cached-list-$suffix"       6 "${base[@]}" -fakeCircles offline "${cache[@]}" -autoScreen circles
    shot "cached-page-$suffix"       8 "${base[@]}" -fakeCircles offline "${cache[@]}" -autoScreen circle
    rm -f "$out/cached-fill-$suffix.jpg"
}

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
all dark
xcrun simctl ui "$udid" appearance light
all light
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
all ax5
xcrun simctl ui "$udid" content_size large
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true
