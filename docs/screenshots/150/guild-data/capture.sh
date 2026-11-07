#!/usr/bin/env bash
# Issue #150 slice 8's evidence: Compare as boards, a goal's patches, the goal on Listen, and friends on a set's rows and a paper card,
# against the reference pictures, in dark, in light and at the largest text size, from the running app at half size, JPEG. Leaves
# the text size at `large` and the appearance at dark. Then each new surface under a moving light, counting patch decodes.
#
#   docs/screenshots/150/guild-data/capture.sh <simulator UDID> <app path>
#   docs/screenshots/150/guild-data/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait, and CAPTURE_ONLY=<prefix> takes
# only the shots whose names start with it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/guild-data"
references="${REFERENCES:-/Users/matthewcelia/Documents/repos/BirdJournal/output/ux-audit/reference}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "${@/#/$out/}"
    }
    # The references first, scaled to the sheets' width like the rest.
    for picture in 1-guild-page 3-listen-rejected-hoop 4-set-page 5-compare; do
        sips -Z 800 -s format jpeg -s formatOptions 80 "$references/$picture.png" --out "$out/reference-$picture.jpg" >/dev/null
    done
    sheet against-5-compare 3 reference-5-compare.jpg compare-dark.jpg compare-light.jpg
    sheet against-1-guild-page 3 reference-1-guild-page.jpg goal-dark.jpg goal-light.jpg
    sheet against-3-listen 3 reference-3-listen-rejected-hoop.jpg listen-dark.jpg listen-light.jpg
    sheet against-4-set-page 3 reference-4-set-page.jpg set-dark.jpg set-light.jpg
    sheet the-rest 4 compare-both-dark.jpg goal-board-dark.jpg card-dark.jpg compare-blanks-dark.jpg
    sheet ax5 4 compare-ax5.jpg goal-ax5.jpg listen-ax5.jpg set-ax5.jpg card-ax5.jpg
    sheet contrast 4 compare-contrast-dark.jpg compare-contrast-light.jpg goal-contrast-dark.jpg goal-contrast-light.jpg
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

launch() {  # seconds flags...
    local wait="$1"; shift
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
    [[ -z "${CAPTURE_ONLY:-}" || "$name" == "$CAPTURE_ONLY"* ]] || return 0
    launch "$wait" "$@"
    snap "$name"
}

base=(-inMemoryAlbum YES -seedReferenceBirds YES -collectionIntroShown YES -fakeAccount signedIn -fakeCircles reference -autoLocation griffith)

dark_and_light() {
    local suffix="$1"
    shot "compare-$suffix" 10 "${base[@]}" -autoScreen compare
    shot "goal-$suffix"    10 "${base[@]}" -autoScreen circle
    shot "listen-$suffix"  10 "${base[@]}" -autoScreen listen -autoScrollTo local-set
    shot "set-$suffix"     10 "${base[@]}" -autoScreen set -autoScrollTo set-rows
}

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
dark_and_light dark
shot compare-both-dark   10 "${base[@]}" -autoScreen compare -autoScrollTo compare-both
shot goal-board-dark     10 "${base[@]}" -autoScreen goal-patches
shot card-dark           10 "${base[@]}" -autoScreen card-back -autoCardSpecies "Sayornis nigricans" -autoCardScroll card-friends
# Every patch without its painting, as on a phone without the pack.
shot compare-blanks-dark 10 "${base[@]}" -autoScreen compare -fakePatchArt missing
shot goal-blanks-dark    10 "${base[@]}" -autoScreen circle -fakePatchArt missing

xcrun simctl ui "$udid" appearance light
dark_and_light light

xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot compare-ax5 12 "${base[@]}" -autoScreen compare
shot goal-ax5    12 "${base[@]}" -autoScreen circle
shot listen-ax5  12 "${base[@]}" -autoScreen listen -autoScrollTo local-set
shot set-ax5     12 "${base[@]}" -autoScreen set -autoScrollTo set-rows
shot card-ax5    12 "${base[@]}" -autoScreen card-back -autoCardSpecies "Sayornis nigricans" -autoCardScroll card-friends
xcrun simctl ui "$udid" content_size large

# Increase Contrast, in both appearances.
xcrun simctl ui "$udid" increase_contrast enabled
xcrun simctl ui "$udid" appearance dark
shot compare-contrast-dark 10 "${base[@]}" -autoScreen compare
shot goal-contrast-dark    10 "${base[@]}" -autoScreen circle
xcrun simctl ui "$udid" appearance light
shot compare-contrast-light 10 "${base[@]}" -autoScreen compare
shot goal-contrast-light    10 "${base[@]}" -autoScreen circle
xcrun simctl ui "$udid" increase_contrast disabled
xcrun simctl ui "$udid" appearance dark

# Patches under a moving light. A healthy sweep decodes each patch once, as it comes on screen (colour and layers, so two for each
# patch), and nothing after that; a thumbnail that had stayed a lazy provider would log AV1 lines at about the frame rate.
decodes() {  # seconds of log
    xcrun simctl spawn "$udid" log show --last "$1" --process BirdJournal --info --style compact 2>/dev/null
}
window() {
    local log
    log="$(decodes 8s)"
    printf '%s patch decodes, %s AV1 or ImageIO lines' "$(grep -c 'patch-decode' <<<"$log" || true)" "$(grep -Ec 'AV1|AVIF|ImageIO' <<<"$log" || true)"
}
count() {  # label flags...
    local label="$1"; shift
    launch 14 "$@" -patchLightSweep YES -patchDecodeLog YES
    local first second
    first="$(window)"
    sleep 12
    second="$(window)"
    printf '%s: first window: %s. 20 s later: %s. Patch decodes in the last minute: %s.\n' "$label" "$first" "$second" "$(decodes 1m | grep -c 'patch-decode' || true)"
}
if [[ -z "${CAPTURE_ONLY:-}" || "counts" == "$CAPTURE_ONLY"* ]]; then
    {
        count "Compare's boards" "${base[@]}" -autoScreen compare
        count "A Guild's page, with its goal's row" "${base[@]}" -autoScreen circle
    } | tee "$out/decode-counts.txt"
fi
