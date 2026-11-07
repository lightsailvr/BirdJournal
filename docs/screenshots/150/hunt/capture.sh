#!/usr/bin/env bash
# Issue #150 slice 5's evidence (V2, L1, L2, A2): a run as a hunt, the rows that follow the picture grammar and a bird's profile,
# from the running app at half size, in dark and light at the default text size (`large`) and in dark at the largest (ax5).
# Needs a debug build, the test clip (`scripts/download-clips.sh`) and uv. Grants the simulator location and the microphone, and
# puts its text size and appearance back on any exit.
#
#   docs/screenshots/150/hunt/capture.sh <simulator UDID> <app path>     the shots and the decode counts
#   docs/screenshots/150/hunt/capture.sh --sheets                        the contact sheets, reference first
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait, and CAPTURE_ONLY=<regex> takes
# only the shots it matches, with the decode counts if it matches "counts".
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/hunt"
reference="${REFERENCE_ART:-/Users/matthewcelia/Documents/repos/BirdJournal/output/ux-audit/reference}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sips -Z 800 -s format jpeg -s formatOptions 78 "$reference/2-listening-run.png" --out "$out/sheets/reference-2-listening-run.jpg" >/dev/null
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "$@"
    }
    sheet run-against-reference 3 "$out/sheets/reference-2-listening-run.jpg" "$out/run-dark.jpg" "$out/run-light.jpg"
    sheet rows-after-add 5 "$out/run-added-dark.jpg" "$out/run-toast-dark.jpg" "$out/run-no-pack-dark.jpg" "$out/run-after-stop-dark.jpg" "$out/review-dark.jpg"
    sheet contrast 2 "$out/run-contrast-dark.jpg" "$out/run-contrast-light.jpg"
    sheet grammar-dark 4 "$out/species-dark.jpg" "$out/sightings-dark.jpg" "$out/set-dark.jpg" "$out/atlas-search-dark.jpg"
    sheet grammar-light 4 "$out/species-light.jpg" "$out/sightings-light.jpg" "$out/set-light.jpg" "$out/atlas-search-light.jpg"
    sheet profile 4 "$out/profile-dark.jpg" "$out/profile-light.jpg" "$out/profile-gallery-dark.jpg" "$out/profile-none-dark.jpg"
    sheet ax5 4 "$out/run-ax5.jpg" "$out/run-row-ax5.jpg" "$out/species-ax5.jpg" "$out/sightings-ax5.jpg" "$out/set-ax5.jpg" "$out/profile-ax5.jpg" "$out/atlas-search-ax5.jpg"
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
slow="${CAPTURE_SLOW:-0}"

restore() {
    xcrun simctl ui "$udid" content_size large 2>/dev/null || true
    xcrun simctl ui "$udid" increase_contrast disabled 2>/dev/null || true
    xcrun simctl ui "$udid" appearance dark 2>/dev/null || true
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl status_bar "$udid" clear 2>/dev/null || true
}
trap restore EXIT

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

launch() {  # seconds flags...
    local wait="$1"; shift
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    # The first launch after a terminated listening run can come up without its flags (as 138's script found): one throwaway first.
    xcrun simctl launch "$udid" "$bundle" -inMemoryAlbum YES >/dev/null
    sleep 3
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
}

snap() {
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$1.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$1.jpg" >/dev/null
    echo "$1"
}

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    [[ -z "${CAPTURE_ONLY:-}" || "$name" =~ $CAPTURE_ONLY ]] || return 0
    launch "$wait" "$@"
    snap "$name"
}

seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
# The mock's three rows, standing still: one new, two with patches.
hunt=(-fakeRunBirds "Melanerpes formicivorus_Acorn Woodpecker,Haemorhous mexicanus_House Finch,Sayornis nigricans_Black Phoebe" -autoPhoneListening "$clip" -autoLocation griffith)

for scheme in dark light; do
    xcrun simctl ui "$udid" appearance "$scheme"
    shot "run-$scheme"       12 "${seeded[@]}" "${hunt[@]}" -autoScreen listening
    shot "review-$scheme"    12 "${seeded[@]}" "${hunt[@]}" -autoScreen review
    shot "species-$scheme"    9 "${seeded[@]}" -autoScreen species-list
    shot "sightings-$scheme"  9 "${seeded[@]}" -autoScreen sightings
    shot "set-$scheme"        9 "${seeded[@]}" -seedBoard YES -autoScreen set
    shot "profile-$scheme"    9 "${seeded[@]}" -autoScreen profile
    shot "atlas-search-$scheme" 10 "${seeded[@]}" -autoScreen guide -autoQuery "Finch"
done
xcrun simctl ui "$udid" appearance dark
shot run-added-dark        14 "${seeded[@]}" "${hunt[@]}" -autoScreen listening -autoRowAdd "House Finch"
shot run-after-stop-dark   14 "${seeded[@]}" "${hunt[@]}" -autoScreen listening -autoRunStops YES
shot run-toast-dark        14 "${seeded[@]}" "${hunt[@]}" -autoScreen listening -autoRowAdd "House Finch" -autoRowAddAfter 11
shot run-no-pack-dark      12 "${seeded[@]}" -fakeRunBirds "Melanerpes formicivorus_Acorn Woodpecker,Turdus merula_Common Blackbird,Strix nebulosa_Great Gray Owl" -autoPhoneListening "$clip" -autoLocation griffith -autoScreen listening
shot profile-gallery-dark  10 -inMemoryAlbum YES -seedGallery YES -collectionIntroShown YES -autoCardSpecies "Haemorhous mexicanus" -autoScreen profile
shot profile-none-dark      9 -inMemoryAlbum YES -collectionIntroShown YES -autoScreen profile

xcrun simctl ui "$udid" increase_contrast enabled
shot run-contrast-dark     12 "${seeded[@]}" "${hunt[@]}" -autoScreen listening
xcrun simctl ui "$udid" appearance light
shot run-contrast-light    12 "${seeded[@]}" "${hunt[@]}" -autoScreen listening
xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" increase_contrast disabled

xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot run-ax5     12 "${seeded[@]}" "${hunt[@]}" -autoScreen listening -autoScrollTo run-rows
shot run-row-ax5 12 "${seeded[@]}" "${hunt[@]}" -autoScreen listening -autoScrollTo "run-row-Haemorhous mexicanus"
shot run-toast-ax5 14 "${seeded[@]}" "${hunt[@]}" -autoScreen listening -autoRowAdd "House Finch" -autoRowAddAfter 11
shot species-ax5  9 "${seeded[@]}" -autoScreen species-list
shot set-ax5      9 "${seeded[@]}" -seedBoard YES -autoScreen set
shot sightings-ax5 9 "${seeded[@]}" -autoScreen sightings
shot profile-ax5  9 "${seeded[@]}" -autoScreen profile
shot atlas-search-ax5 10 "${seeded[@]}" -autoScreen guide -autoQuery "Finch"
xcrun simctl ui "$udid" content_size large

# The trap the brief names: patches on rows that refresh every second, under a moving light. A healthy sweep logs its frame times
# and decodes each patch once, as it comes on screen; a thumbnail that had stayed a lazy provider would log AV1 lines at about the
# frame rate for every patch on screen (about 120 a second on a board, as #134 found). Each surface is read for two 8 s windows,
# and then for the minute since launch, which holds its first decodes: colour and layers, so two for each patch. The shot beside
# each count shows what was on screen: a count over rows with no patches on them would prove nothing.
decodes() {  # seconds of log
    xcrun simctl spawn "$udid" log show --last "$1" --process BirdJournal --info --style compact 2>/dev/null
}
window() {
    local log
    log="$(decodes 8s)"
    printf '%s lines, %s patch decodes, %s AV1 or ImageIO lines' "$(grep -c . <<<"$log")" "$(grep -c 'patch-decode' <<<"$log" || true)" "$(grep -Ec 'AV1|AVIF|ImageIO' <<<"$log" || true)"
}
count() {  # label shot flags...
    local label="$1" name="$2"; shift 2
    launch 14 "$@" -patchLightSweep YES -patchDecodeLog YES
    local first second
    first="$(window)"
    snap "$name" >/dev/null
    sleep 12
    second="$(window)"
    printf '%s (`%s`): first window: %s. 20 s later: %s. Patch decodes in the last minute: %s.\n' "$label" "$name" "$first" "$second" "$(decodes 1m | grep -c 'patch-decode' || true)"
}
if [[ -z "${CAPTURE_ONLY:-}" || "counts" =~ $CAPTURE_ONLY ]]; then
    {
        # -seedLarge gives nearly every bird the clip hears a Los Angeles patch, so a real list that re-sorts is mostly patches.
        count "A real run over the clip, its birds sewn" count-run-clip -inMemoryAlbum YES -seedLarge 1000 -collectionIntroShown YES -autoPhoneListening "$clip" -autoLocation griffith -autoScreen listening
        count "A run holding still, three rows" count-run-still "${seeded[@]}" "${hunt[@]}" -autoScreen listening
    } | tee "$out/decode-counts.txt"
fi
