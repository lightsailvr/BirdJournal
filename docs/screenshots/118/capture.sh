#!/usr/bin/env bash
# Issue #118's evidence: the Guilds and Atlas screens on a simulator, in dark, light and accessibility extra large
# (ax3, light), at half size. Needs a debug build (`scripts/build-and-test.sh` leaves one in build/DerivedData).
#
#   docs/screenshots/118/capture.sh <simulator UDID>
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
udid="${1:?give the simulator UDID}"
bundle="com.matthewcelia.mybirdjournal"
app="$repo_root/build/DerivedData/Build/Products/Debug-iphonesimulator/BirdJournal.app"
out="$repo_root/docs/screenshots/118"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
    sips -Z 800 "$out/$name.png" >/dev/null
    echo "$name"
}

guilds=(-inMemoryAlbum YES -seedJournal YES -fakeAccount signedIn -fakeCircles some -collectionIntroShown YES)
atlas=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)

capture() {  # suffix
    local s="$1"
    shot "guilds-$s"          8 "${guilds[@]}" -autoScreen circles
    shot "guild-$s"           8 "${guilds[@]}" -autoScreen circle
    shot "guild-feed-$s"      9 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed
    shot "atlas-$s"          10 "${atlas[@]}" -autoScreen guide
    shot "atlas-new-$s"      11 "${atlas[@]}" -autoScreen guide -autoScrollTo atlas-new
    shot "pack-states-1-$s"   8 "${atlas[@]}" -autoScreen packs -autoPackStates 1
    shot "pack-states-2-$s"   8 "${atlas[@]}" -autoScreen packs -autoPackStates 2
    shot "pack-states-3-$s"   8 "${atlas[@]}" -autoScreen packs -autoPackStates 3
    shot "pack-states-4-$s"   8 "${atlas[@]}" -autoScreen packs -autoPackStates 4
    shot "pack-$s"            8 "${atlas[@]}" -autoScreen pack
    shot "profile-$s"         7 "${atlas[@]}" -autoScreen profile
    shot "profile-tale-$s"    8 "${atlas[@]}" -autoScreen profile -autoScrollTo profile-tale
}

xcrun simctl ui "$udid" content_size medium
xcrun simctl ui "$udid" appearance dark
capture dark
xcrun simctl ui "$udid" appearance light
capture light
xcrun simctl ui "$udid" content_size accessibility-extra-large
capture ax3
xcrun simctl ui "$udid" content_size medium
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true
echo "wrote $(ls "$out"/*.png | wc -l | tr -d ' ') screenshots to $out"
