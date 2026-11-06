#!/usr/bin/env bash
# Issue #150 slice 9's evidence (A1, A3, A5, A6, F12): the Atlas as a book, from the running app at half size, in dark and light at the
# default text size (`large`) and in dark at the largest (ax5). Puts the simulator's text size, contrast and appearance back on any exit.
#
#   docs/screenshots/150/atlas/capture.sh <simulator UDID> <app path>     the shots and the decode counts
#   docs/screenshots/150/atlas/capture.sh --sheets                        the contact sheets, the reference first
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait, and CAPTURE_ONLY=<regex> takes only
# the shots it matches, with the decode counts if it matches "counts".
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/atlas"
reference="${REFERENCE_ART:-/Users/matthewcelia/Documents/repos/BirdJournal/output/ux-audit/reference}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    # The mock's phone alone, at the running app's proportions, so the two compare at one scale.
    uv run -q --with pillow python - "$reference/4-set-page.png" "$out/sheets/reference-4-set-page.jpg" <<'PY'
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").crop((8, 0, 891, 1920)).resize((368, 800)).save(sys.argv[2], quality=84)
PY
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "$@"
    }
    sheet set-against-reference 3 "$out/sheets/reference-4-set-page.jpg" "$out/set-dark.jpg" "$out/set-light.jpg"
    sheet plates 4 "$out/atlas-dark.jpg" "$out/atlas-light.jpg" "$out/pack-dark.jpg" "$out/packs-dark.jpg"
    sheet silhouettes 3 "$out/set-rows-dark.jpg" "$out/set-mixed-dark.jpg" "$out/set-no-pack-dark.jpg"
    sheet map 4 "$out/map-dark.jpg" "$out/map-light.jpg" "$out/map-cluster-dark.jpg" "$out/map-editions-dark.jpg"
    sheet record 4 "$out/record-patch-dark.jpg" "$out/record-patch-light.jpg" "$out/record-photo-dark.jpg" "$out/record-disclosures-dark.jpg"
    sheet first-photos 4 "$out/photo-black-phoebe-dark.jpg" "$out/photo-red-tailed-hawk-dark.jpg" "$out/photo-peregrine-falcon-dark.jpg" "$out/photo-western-screech-owl-dark.jpg"
    sheet ax5 4 "$out/set-ax5.jpg" "$out/set-rows-ax5.jpg" "$out/atlas-ax5.jpg" "$out/record-ax5.jpg" "$out/record-disclosures-ax5.jpg" "$out/map-ax5.jpg" "$out/pack-ax5.jpg" "$out/packs-ax5.jpg"
    sheet contrast 4 "$out/set-contrast-dark.jpg" "$out/set-contrast-light.jpg" "$out/record-contrast-dark.jpg" "$out/record-contrast-light.jpg"
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
slow="${CAPTURE_SLOW:-0}"
only="${CAPTURE_ONLY:-}"

restore() {
    xcrun simctl ui "$udid" content_size large
    xcrun simctl ui "$udid" increase_contrast disabled
    xcrun simctl ui "$udid" appearance dark
}
trap restore EXIT

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true
restore

launch() {  # seconds flags...
    local wait="$1"; shift
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
}

snap() {  # name
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$1.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$1.jpg" >/dev/null
    echo "$1"
}

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    if [[ -n "$only" && ! "$name" =~ $only ]]; then return 0; fi
    launch "$wait" "$@"
    snap "$name"
}

base=(-inMemoryAlbum YES -collectionIntroShown YES)
seeded=("${base[@]}" -seedJournal YES)
dove=(-autoCardSpecies "Zenaida macroura")
phoebe=(-autoCardSpecies "Sayornis nigricans")

# A first launch reads the index, so the other sets are known from the second launch on.
launch 10 "${base[@]}"

for scheme in dark light; do
    xcrun simctl ui "$udid" appearance "$scheme"
    shot "set-$scheme"           9 "${seeded[@]}" -autoScreen set
    shot "atlas-$scheme"         9 "${seeded[@]}" -autoScreen guide
    shot "record-patch-$scheme" 10 "${seeded[@]}" "${dove[@]}" -autoScreen sighting
    shot "map-$scheme"          12 "${seeded[@]}" "${phoebe[@]}" -autoScreen map
done
xcrun simctl ui "$udid" appearance dark
shot set-rows-dark                 9 "${base[@]}" -autoScreen set -autoScrollTo set-rows
shot set-mixed-dark               10 "${base[@]}" -seedBoard YES -autoScreen set -autoScrollTo set-rows
shot set-no-pack-dark              9 "${seeded[@]}" -autoScreen set -autoSet us-ca-sd -autoScrollTo set-rows
shot pack-dark                     9 "${seeded[@]}" -autoScreen pack
shot packs-dark                    9 "${seeded[@]}" -autoScreen packs
shot map-cluster-dark             12 "${base[@]}" -seedGallery YES -autoCardSpecies "Haemorhous mexicanus" -autoScreen map
shot map-editions-dark  12 "${base[@]}" -seedGallery YES -seedJournal YES "${phoebe[@]}" -autoScreen map -autoMapAcross 500000
shot record-photo-dark            10 "${seeded[@]}" "${phoebe[@]}" -autoScreen sighting
shot record-disclosures-dark      10 "${seeded[@]}" "${phoebe[@]}" -autoScreen sighting -autoDisclosuresOpen YES -autoScrollTo sighting-disclosures
for bird in "Sayornis nigricans:black-phoebe" "Buteo jamaicensis:red-tailed-hawk" "Falco peregrinus:peregrine-falcon" "Megascops kennicottii:western-screech-owl"; do
    shot "photo-${bird#*:}-dark" 9 "${base[@]}" -autoCardSpecies "${bird%%:*}" -autoScreen profile
done

xcrun simctl ui "$udid" increase_contrast enabled
shot set-contrast-dark     9 "${seeded[@]}" -autoScreen set
shot record-contrast-dark 10 "${seeded[@]}" "${dove[@]}" -autoScreen sighting
xcrun simctl ui "$udid" appearance light
shot set-contrast-light     9 "${seeded[@]}" -autoScreen set
shot record-contrast-light 10 "${seeded[@]}" "${dove[@]}" -autoScreen sighting
xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" increase_contrast disabled

xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot set-ax5                9 "${seeded[@]}" -autoScreen set
shot set-rows-ax5           9 "${seeded[@]}" -autoScreen set -autoScrollTo set-rows
shot atlas-ax5              9 "${seeded[@]}" -autoScreen guide
shot pack-ax5               9 "${seeded[@]}" -autoScreen pack
shot packs-ax5              9 "${seeded[@]}" -autoScreen packs
shot record-ax5            10 "${seeded[@]}" "${dove[@]}" -autoScreen sighting
shot record-disclosures-ax5 10 "${seeded[@]}" "${phoebe[@]}" -autoScreen sighting -autoDisclosuresOpen YES -autoScrollTo sighting-disclosures
shot map-ax5               12 "${seeded[@]}" "${phoebe[@]}" -autoScreen map
xcrun simctl ui "$udid" content_size large

# A silhouette and a marker stay plain bitmaps, and a record's patch and a set's rows decode once, under a moving light. As in
# hunt/capture.sh: two 8 s windows, then the minute since launch. Each patch is two decodes, its colour and its layers.
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
if [[ -z "$only" || "counts" =~ $only ]]; then
    {
        count "A set's rows, silhouettes and patches" count-set "${base[@]}" -seedBoard YES -autoScreen set -autoScrollTo set-rows
        count "The map's markers" count-map "${seeded[@]}" "${phoebe[@]}" -autoScreen map
        count "A record's patch" count-record "${seeded[@]}" "${dove[@]}" -autoScreen sighting
    } | tee "$out/decode-counts.txt"
fi
