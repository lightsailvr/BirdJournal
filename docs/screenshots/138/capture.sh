#!/usr/bin/env bash
# Issue #138's evidence for #131: every journey board of design guide 2.0 (pages 4-8) and every state of page 15 on a
# simulator, from the running app, in dark and light at half size; the patch screens at xxLarge, ax3 and ax5 text; and with
# Increase Contrast in both appearances. Then the contact sheets the PR shows. Needs a debug build
# (`scripts/build-and-test.sh` leaves one in build/DerivedData), the test clip (`scripts/download-clips.sh`) and uv. Grants the
# simulator location (a fix in Griffith Park), and turns its microphone off and on again for the denied-microphone shot.
# Disconnected glasses come from `-fakeGlasses`, so it doesn't touch the mock lens's port.
#
#   docs/screenshots/138/capture.sh <simulator UDID> [app path] [sections]
#
# Sections are any of "boards type contrast sheets", all of them by default: a run on a loaded Mac can take over an hour. The
# waits are fixed, so look over the shots afterwards, and set CAPTURE_SLOW=<seconds> to add to each wait. CAPTURE_ONLY=<regex>
# takes only the shots whose names match, to fill in or redo a few.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
udid="${1:?give the simulator UDID}"
bundle="com.matthewcelia.mybirdjournal"
app="${2:-$repo_root/build/DerivedData/Build/Products/Debug-iphonesimulator/BirdJournal.app}"
out="$repo_root/docs/screenshots/138"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
sections="${3:-boards type contrast sheets}"
slow="${CAPTURE_SLOW:-0}"
only="${CAPTURE_ONLY:-}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

after_run=0
shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    [[ -z "$only" || "$name" =~ $only ]] || return 0
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    # The first launch after a terminated listening run can come up without its flags (seen on iOS 27.2): one throwaway
    # launch first.
    if ((after_run)); then
        xcrun simctl launch "$udid" "$bundle" -inMemoryAlbum YES >/dev/null
        sleep 4
        xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
        sleep 2
    fi
    after_run=0
    [[ " $* " == *" listening "* || " $* " == *" review "* ]] && after_run=1
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$name.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$name.jpg" >/dev/null
    echo "$name"
}

seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
board=(-inMemoryAlbum YES -seedBoard YES -collectionIntroShown YES)
gallery=(-inMemoryAlbum YES -seedGallery YES -collectionIntroShown YES)
empty=(-inMemoryAlbum YES)
guilds=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn -fakeCircles some)
run=(-autoPhoneListening "$clip" -autoLocation griffith)
phoebe=(-autoCardSpecies "Sayornis nigricans")
hummingbird=(-autoCardSpecies "Calypte anna")
goose=(-autoCardSpecies "Branta canadensis")

boards() {  # suffix: guide pages 4-8, in their order
    local s="$1"
    shot "board-01-ready-$s"          8 "${seeded[@]}" -autoScreen listen
    shot "board-02-call-$s"          16 "${seeded[@]}" "${run[@]}" -autoScreen listening
    shot "board-03-review-$s"        20 "${seeded[@]}" "${run[@]}" -autoScreen review
    shot "board-04-stitching-$s"     16 "${seeded[@]}" "${phoebe[@]}" -stitchInSeconds 40 -autoScreen reveal
    shot "board-05-your-patch-$s"    14 "${seeded[@]}" "${phoebe[@]}" -autoScreen reveal
    shot "board-07-patches-$s"       10 "${board[@]}" -autoScreen cards
    shot "board-08-patch-$s"          9 "${seeded[@]}" "${phoebe[@]}" -autoScreen card
    shot "board-09-paper-card-$s"     9 "${seeded[@]}" "${phoebe[@]}" -autoScreen card-back
    shot "board-10-two-editions-$s"   9 "${gallery[@]}" -autoScreen species
    shot "board-11-atlas-$s"         10 "${seeded[@]}" -autoScreen guide
    shot "board-12-share-$s"         10 "${seeded[@]}" "${phoebe[@]}" -autoScreen share
    shot "board-13-guild-$s"          9 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed
}

states() {  # suffix: guide page 15
    local s="$1"
    shot "state-empty-$s"                  8 "${empty[@]}" -autoScreen journal
    shot "state-not-found-row-$s"          8 "${seeded[@]}" -autoScreen set
    shot "state-not-found-page-$s"         9 "${seeded[@]}" "${goose[@]}" -autoScreen species
    shot "state-being-sewn-board-$s"       8 "${seeded[@]}" -fakePatchArt sewing -autoScreen cards
    shot "state-being-sewn-page-$s"        8 "${seeded[@]}" -fakePatchArt sewing "${phoebe[@]}" -autoScreen card
    shot "state-art-missing-board-$s"      8 "${seeded[@]}" -fakePatchArt missing -autoScreen cards
    shot "state-art-missing-page-$s"       8 "${seeded[@]}" -fakePatchArt missing "${phoebe[@]}" -autoScreen card
    shot "state-art-missing-reveal-$s"    10 "${seeded[@]}" -fakePatchArt missing "${phoebe[@]}" -autoScreen reveal
    shot "state-uncharted-board-$s"        8 "${seeded[@]}" -autoBoard uncharted -autoScreen cards
    shot "state-uncharted-page-$s"         8 "${seeded[@]}" "${hummingbird[@]}" -autoScreen card
    shot "state-uncharted-card-$s"         8 "${seeded[@]}" "${hummingbird[@]}" -autoScreen card-back
    shot "state-offline-atlas-$s"         10 "${seeded[@]}" -packIndexURL http://127.0.0.1:9/index.json -autoScreen guide
    shot "state-offline-guilds-$s"         8 -inMemoryAlbum YES -fakeAccount signedIn -fakeCircles offline -autoScreen circles
    shot "state-no-location-listen-$s"    16 "${seeded[@]}" -autoPhoneListening "$clip" -autoLocation denied -autoScreen listening
    shot "state-no-location-rarity-$s"     8 "${seeded[@]}" -autoCardSpecies "Turdus merula" -autoScreen sighting
    shot "state-denied-notifications-$s"  10 "${guilds[@]}" -fakePushPermission denied -autoScreen circle -autoScrollTo guild-settings
    shot "state-glasses-not-connected-$s"  7 "${seeded[@]}" -listeningSource glasses -fakeGlasses notConnected -autoScreen listen
    shot "state-glasses-none-linked-$s"    7 "${seeded[@]}" -listeningSource glasses -fakeGlasses noneLinked -autoScreen listen
    shot "state-glasses-unregistered-$s"   7 "${seeded[@]}" -listeningSource glasses -fakeGlasses unregistered -autoScreen listen
    # The microphone off: the real denial, so the real error.
    xcrun simctl privacy "$udid" revoke microphone "$bundle"
    shot "state-denied-microphone-$s"     10 "${seeded[@]}" -listeningSource phone -autoScreen listening
    xcrun simctl privacy "$udid" grant microphone "$bundle"
}

sized() {  # suffix: the screens that change with Dynamic Type
    local s="$1"
    shot "type-board-$s"         9 "${board[@]}" -autoScreen cards
    shot "type-patch-$s"         8 "${seeded[@]}" "${phoebe[@]}" -autoScreen card
    shot "type-card-$s"          8 "${seeded[@]}" "${phoebe[@]}" -autoScreen card-back
    shot "type-blank-$s"         8 "${seeded[@]}" -fakePatchArt missing -autoScreen cards
    shot "type-being-sewn-$s"    8 "${seeded[@]}" -fakePatchArt sewing "${phoebe[@]}" -autoScreen card
    shot "type-empty-$s"         8 "${empty[@]}" -autoScreen journal
    shot "type-not-found-$s"     8 "${seeded[@]}" -autoScreen set
}

contrasted() {  # suffix: Increase Contrast
    local s="$1"
    shot "contrast-board-$s"     9 "${seeded[@]}" -autoScreen cards
    shot "contrast-patch-$s"     8 "${seeded[@]}" "${phoebe[@]}" -autoScreen card
    shot "contrast-card-$s"      8 "${seeded[@]}" "${phoebe[@]}" -autoScreen card-back
    shot "contrast-species-$s"   8 "${gallery[@]}" -autoScreen species
    shot "contrast-empty-$s"     8 "${empty[@]}" -autoScreen journal
    shot "contrast-reveal-$s"   12 "${seeded[@]}" "${phoebe[@]}" -reduceMotion YES -autoScreen reveal
}

sheet() {  # sheet name, columns, shots
    local name="$1" columns="$2"; shift 2
    uv run -q "$out/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
}

xcrun simctl ui "$udid" increase_contrast disabled 2>/dev/null || true
if [[ " $sections " == *" boards "* ]]; then
    xcrun simctl ui "$udid" content_size medium
    for appearance in dark light; do
        xcrun simctl ui "$udid" appearance "$appearance"
        boards "$appearance"
        states "$appearance"
    done
fi

if [[ " $sections " == *" type "* ]]; then
    xcrun simctl ui "$udid" appearance light
    for size in extra-extra-large:xxl accessibility-extra-large:ax3 accessibility-extra-extra-extra-large:ax5; do
        xcrun simctl ui "$udid" content_size "${size%%:*}"
        sized "${size##*:}"
    done
fi

if [[ " $sections " == *" contrast "* ]]; then
    xcrun simctl ui "$udid" content_size medium
    xcrun simctl ui "$udid" increase_contrast enabled 2>/dev/null || true
    for appearance in dark light; do
        xcrun simctl ui "$udid" appearance "$appearance"
        contrasted "$appearance"
    done
    xcrun simctl ui "$udid" increase_contrast disabled 2>/dev/null || true
fi

xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true

[[ " $sections " == *" sheets "* ]] || exit 0
mkdir -p "$out/sheets"
for s in dark light; do
    sheet "boards-$s" 7 board-{01-ready,02-call,03-review,04-stitching,05-your-patch,07-patches,08-patch,09-paper-card,10-two-editions,11-atlas,12-share,13-guild}-$s.jpg
    sheet "states-patch-$s" 6 state-{empty,not-found-row,not-found-page,being-sewn-board,being-sewn-page,art-missing-board,art-missing-page,art-missing-reveal,uncharted-board,uncharted-page,uncharted-card}-$s.jpg
    sheet "states-as-1-$s" 5 state-{offline-atlas,offline-guilds,no-location-listen,no-location-rarity,denied-notifications,denied-microphone,glasses-not-connected,glasses-none-linked,glasses-unregistered}-$s.jpg
    sheet "contrast-$s" 6 contrast-{board,patch,card,species,empty,reveal}-$s.jpg
done
for s in xxl ax3 ax5; do
    sheet "type-$s" 7 type-{board,patch,card,blank,being-sewn,empty,not-found}-$s.jpg
done
echo "wrote $(ls "$out"/*.jpg | wc -l | tr -d ' ') screenshots to $out"
