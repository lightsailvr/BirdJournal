#!/usr/bin/env bash
# Issue #150 slice 1's evidence: the screens its fixes touch, from the running app, at half size, at the default text size
# (`large`) and the largest (ax5). Give it a build of `dev` and the prefix `before-` for the screens with a before.
# Needs a debug build, the test clip (`scripts/download-clips.sh`) and uv. Grants the simulator location (a fix in Griffith
# Park) and the microphone, and leaves its text size at `large`.
#
#   docs/screenshots/150/capture.sh <simulator UDID> <app path> [before-]
#   docs/screenshots/150/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out="$repo_root/docs/screenshots/150"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
    }
    pairs=()
    for screen in listen settings source guild-feed guild-sharing invite listening review share; do
        pairs+=("before-$screen-dark.jpg" "$screen-dark.jpg")
    done
    sheet before-after-dark 6 "${pairs[@]}"
    sheet after-grammar-dark 3 board-dark.jpg species-dark.jpg patch-dark.jpg
    sheet after-light 4 listen-light.jpg settings-light.jpg guild-feed-light.jpg review-light.jpg
    sheet ax5 6 before-listen-ax5.jpg listen-ax5.jpg before-guild-ax5.jpg guild-ax5.jpg before-guild-feed-ax5.jpg guild-feed-ax5.jpg
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
prefix="${3:-}"
bundle="com.matthewcelia.mybirdjournal"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

after_run=0
shot() {  # name seconds flags...
    local name="$prefix$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    # The first launch after a terminated listening run can come up without its flags (as 138's script found): one throwaway
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

empty=(-inMemoryAlbum YES)
seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
guilds=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn -fakeCircles some)
run=(-autoPhoneListening "$clip" -autoLocation griffith)
phoebe=(-autoCardSpecies "Sayornis nigricans")

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
shot listen-dark          8 "${empty[@]}" -autoScreen listen
shot settings-dark        8 "${empty[@]}" -autoScreen settings
shot source-dark          9 "${empty[@]}" -autoScreen source
shot guild-feed-dark     10 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed
shot guild-sharing-dark  10 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-settings
shot invite-dark         10 "${guilds[@]}" -autoScreen circle-invite
shot listening-dark      18 "${seeded[@]}" "${run[@]}" -autoScreen listening
shot review-dark         22 "${seeded[@]}" "${run[@]}" -autoScreen review
shot share-dark          10 "${seeded[@]}" "${phoebe[@]}" -autoScreen share
if [[ -z "$prefix" ]]; then
    shot board-dark      10 "${seeded[@]}" -autoScreen cards
    shot species-dark     9 "${seeded[@]}" "${phoebe[@]}" -autoScreen species
    shot patch-dark       9 "${seeded[@]}" "${phoebe[@]}" -autoScreen card
    xcrun simctl ui "$udid" appearance light
    shot listen-light     8 "${empty[@]}" -autoScreen listen
    shot settings-light   8 "${empty[@]}" -autoScreen settings
    shot guild-feed-light 10 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed
    shot review-light    22 "${seeded[@]}" "${run[@]}" -autoScreen review
fi

xcrun simctl ui "$udid" appearance light
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot listen-ax5           8 "${empty[@]}" -autoScreen listen
shot guild-ax5           10 "${guilds[@]}" -autoScreen circle
shot guild-feed-ax5      10 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed

xcrun simctl ui "$udid" content_size large
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true
