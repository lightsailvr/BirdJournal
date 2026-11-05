#!/usr/bin/env bash
# Issue #119's evidence for #110: every reskinned screen and every designed state (design guide page 16) on a simulator,
# in dark, light and accessibility extra large (ax3, light), at half size; the five screens of the VoiceOver walk at
# the largest accessibility size (ax5, light); and the tab bar and the listening accessory with Increase Contrast.
# Needs a debug build (`scripts/build-and-test.sh` leaves one in build/DerivedData) and the test clip
# (`scripts/download-clips.sh`). Grants the simulator location (with a fix in Griffith Park) and turns its microphone
# off and on again for the denied-microphone shot.
#
#   docs/screenshots/110/capture.sh <simulator UDID> [app path]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
udid="${1:?give the simulator UDID}"
bundle="com.matthewcelia.mybirdjournal"
app="${2:-$repo_root/build/DerivedData/Build/Products/Debug-iphonesimulator/BirdJournal.app}"
out="$repo_root/docs/screenshots/110"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

after_run=0
shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 3
    # The first launch after a terminated listening run can come up without its flags (seen on iOS 27.2): one throwaway
    # launch first.
    if ((after_run)); then
        xcrun simctl launch "$udid" "$bundle" -inMemoryAlbum YES >/dev/null
        sleep 4
        xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
        sleep 3
    fi
    after_run=0
    [[ " $* " == *" listening "* ]] && after_run=1
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
    sips -Z 800 "$out/$name.png" >/dev/null
    echo "$name"
}

seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
empty=(-inMemoryAlbum YES)
guilds=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn -fakeCircles some)
run=(-autoPhoneListening "$clip")

screens() {  # suffix: every reskinned screen
    local s="$1"
    shot "screen-listen-ready-$s"    8 "${seeded[@]}" -autoScreen listen
    shot "screen-listen-active-$s"  16 "${seeded[@]}" "${run[@]}" -autoScreen listening
    shot "screen-reveal-$s"         10 "${seeded[@]}" -autoScreen reveal -autoCardSpecies "Sayornis nigricans"
    shot "screen-cards-$s"           8 "${seeded[@]}" -autoScreen cards
    shot "screen-sightings-$s"       8 "${seeded[@]}" -autoScreen sightings
    shot "screen-species-$s"         8 "${seeded[@]}" -autoScreen species-list
    shot "screen-card-front-$s"      9 "${seeded[@]}" -autoScreen card -autoCardSpecies "Sayornis nigricans"
    shot "screen-card-back-$s"       9 "${seeded[@]}" -autoScreen card-back -autoCardSpecies "Sayornis nigricans"
    shot "screen-share-$s"          10 "${seeded[@]}" -autoScreen share -autoCardSpecies "Sayornis nigricans"
    shot "screen-atlas-$s"          10 "${seeded[@]}" -autoScreen guide
    shot "screen-set-$s"             9 "${seeded[@]}" -autoScreen set
    shot "screen-profile-$s"         8 "${seeded[@]}" -autoScreen profile
    shot "screen-packs-$s"           9 "${seeded[@]}" -autoScreen packs
    shot "screen-guilds-$s"          8 "${guilds[@]}" -autoScreen circles
    shot "screen-guild-$s"           8 "${guilds[@]}" -autoScreen circle
    shot "screen-guild-feed-$s"      9 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed
    shot "screen-settings-$s"        7 "${seeded[@]}" -autoScreen settings
    shot "screen-accessory-$s"      12 "${seeded[@]}" "${run[@]}" -autoScreen listening -autoThenTab journal
}

states() {  # suffix: every designed state of page 16
    local s="$1"
    shot "state-no-guilds-$s"              8 -inMemoryAlbum YES -fakeAccount signedIn -fakeCircles empty -autoScreen circles
    shot "state-signed-out-$s"             7 -inMemoryAlbum YES -fakeAccount signedOut -autoScreen circles
    shot "state-no-cards-$s"               9 "${empty[@]}" -autoScreen journal
    shot "state-offline-guilds-$s"         8 -inMemoryAlbum YES -fakeAccount signedIn -fakeCircles offline -autoScreen circles
    shot "state-offline-atlas-$s"         10 "${seeded[@]}" -packIndexURL http://127.0.0.1:9/index.json -autoScreen guide
    shot "state-offline-pack-$s"           8 "${seeded[@]}" -autoScreen packs -autoPackStates 2
    shot "state-no-location-listen-$s"    16 "${seeded[@]}" "${run[@]}" -autoLocation denied -autoScreen listening
    shot "state-no-location-rarity-$s"     9 "${seeded[@]}" -autoScreen card -autoCardSpecies "Turdus merula"
    shot "state-search-collection-$s"      9 "${seeded[@]}" -autoScreen cards -autoQuery kiwi
    shot "state-search-atlas-$s"          10 "${seeded[@]}" -autoScreen guide -autoQuery kiwi
    shot "state-denied-notifications-$s"  10 "${guilds[@]}" -fakePushPermission denied -autoScreen circle -autoScrollTo guild-settings
    shot "state-glasses-not-connected-$s"  7 "${seeded[@]}" -listeningSource glasses -fakeGlasses notConnected -autoScreen listen
    shot "state-glasses-none-linked-$s"    7 "${seeded[@]}" -listeningSource glasses -fakeGlasses noneLinked -autoScreen listen
    shot "state-glasses-unregistered-$s"   7 "${seeded[@]}" -listeningSource glasses -fakeGlasses unregistered -autoScreen listen
    # The microphone off: the real denial, so the real error.
    xcrun simctl privacy "$udid" revoke microphone "$bundle"
    shot "state-denied-microphone-$s"     10 "${seeded[@]}" -listeningSource phone -autoScreen listening
    xcrun simctl privacy "$udid" grant microphone "$bundle"
}

xcrun simctl ui "$udid" increase_contrast disabled 2>/dev/null || true
xcrun simctl ui "$udid" content_size medium
xcrun simctl ui "$udid" appearance dark
screens dark; states dark
xcrun simctl ui "$udid" appearance light
screens light; states light
xcrun simctl ui "$udid" content_size accessibility-extra-large
screens ax3; states ax3

# The VoiceOver walk's five screens at the largest accessibility size, for clipping and overlap.
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot "ax5-listen"       8 "${seeded[@]}" -autoScreen listen
shot "ax5-cards"        8 "${seeded[@]}" -autoScreen cards
shot "ax5-card-front"   9 "${seeded[@]}" -autoScreen card -autoCardSpecies "Sayornis nigricans"
shot "ax5-atlas"       10 "${seeded[@]}" -autoScreen guide
shot "ax5-guild"        8 "${guilds[@]}" -autoScreen circle

# The system's glass (the tab bar, the listening accessory) with Increase Contrast, in both appearances.
xcrun simctl ui "$udid" content_size medium
xcrun simctl ui "$udid" increase_contrast enabled 2>/dev/null || true
for appearance in dark light; do
    xcrun simctl ui "$udid" appearance "$appearance"
    shot "contrast-accessory-$appearance" 12 "${seeded[@]}" "${run[@]}" -autoScreen listening -autoThenTab journal
    shot "contrast-listen-$appearance"     8 "${seeded[@]}" -autoScreen listen
done
xcrun simctl ui "$udid" increase_contrast disabled 2>/dev/null || true

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true
echo "wrote $(ls "$out"/*.png | wc -l | tr -d ' ') screenshots to $out"
