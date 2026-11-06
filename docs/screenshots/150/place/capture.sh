#!/usr/bin/env bash
# Issue #150 slice 6's evidence: the painting that follows you, the edition's tint, and the thread, from the running app, at half
# size, at the default text size (`large`) and the largest (ax5). Leaves the simulator at `large`.
#
#   docs/screenshots/150/place/capture.sh <simulator UDID> <app path>
#   docs/screenshots/150/place/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/place"
reference="${AUDIT_REFERENCE:-$HOME/Documents/repos/BirdJournal/output/ux-audit/reference}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "$@"
    }
    # The mock's lower half against Listen's, at the same scale. Thread on paper and lavender are the mocks' own, whole.
    uv run -q --with pillow python - "$reference" "$out" <<'PY'
import sys
from PIL import Image
reference, out = sys.argv[1:3]
mock = Image.open(f"{reference}/3-listen-rejected-hoop.png").convert("RGB").crop((0, 1130, 900, 1500))
shots = [Image.open(f"{out}/section-{appearance}.jpg").convert("RGB") for appearance in ("dark", "light")]
crops = [shot.crop((0, round(shot.height * 0.555), shot.width, round(shot.height * 0.75))).resize((900, round(900 * (shot.height * 0.195) / shot.width))) for shot in shots]
sheet = Image.new("RGB", (900, mock.height + sum(crop.height for crop in crops) + 40), "#1b2b2e")
y = 10
for picture in [mock, *crops]:
    sheet.paste(picture, (0, y))
    y += picture.height + 10
sheet.save(f"{out}/sheets/reference-listen.jpg", quality=84)
PY
    sheet reference-thread 4 "$reference/4-set-page.png" "$out/set-la-dark.jpg" "$reference/1-guild-page.png" "$out/goals-dark.jpg"
    sheet places-dark 3 "$out"/listen-{griffith,joshua-tree,san-diego,oakland,orlando,kansas}-dark.jpg
    sheet places-light 3 "$out"/listen-{griffith,joshua-tree,san-diego,oakland,orlando,kansas}-light.jpg
    sheet tint-dark 4 "$out"/{set-la,set-desert,set-coastal,patch,atlas,species-list,goals,download}-dark.jpg
    sheet large-and-contrast 4 "$out"/{listen-ax5,section-ax5,atlas-ax5,listen-contrast-light,listen-contrast-dark,set-desert-contrast-dark}.jpg
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

launch() {  # seconds flags...
    local wait="$1"; shift
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
}

take() {  # name
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$1.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$1.jpg" >/dev/null
    echo "$1"
}

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    launch "$wait" "$@"
    take "$name"
}

empty=(-inMemoryAlbum YES -collectionIntroShown YES)
seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
guilds=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn -fakeCircles some)

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" increase_contrast disabled

# A first launch reads the index, so the other sets' places are known from the second launch on.
launch 10 "${empty[@]}"

for appearance in dark light; do
    xcrun simctl ui "$udid" appearance "$appearance"
    for place in griffith joshua-tree san-diego oakland orlando kansas denied; do
        shot "listen-$place-$appearance" 8 "${empty[@]}" -autoLocation "$place" -autoScreen listen
    done
    shot "section-$appearance" 9 "${seeded[@]}" -autoLocation griffith -autoScreen listen -autoScrollTo local-set
done

xcrun simctl ui "$udid" appearance dark
shot set-la-dark        9 "${seeded[@]}" -autoLocation griffith -autoScreen set
shot set-desert-dark    9 "${seeded[@]}" -autoLocation griffith -autoScreen set -autoSet us-ca-desert
shot set-coastal-dark   9 "${seeded[@]}" -autoLocation griffith -autoScreen set -autoSet us-ca-sd
shot patch-dark         9 "${seeded[@]}" -autoLocation joshua-tree -autoScreen card
shot atlas-dark         9 "${seeded[@]}" -autoLocation griffith -autoScreen guide
shot species-list-dark  9 "${seeded[@]}" -autoLocation griffith -autoScreen species-list
shot goals-dark        10 "${guilds[@]}" -autoLocation griffith -autoScreen circle
# Part way through a download, in San Diego's thread, from a clean install so its pack isn't there yet, and it's left that way.
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl uninstall "$udid" "$bundle"
xcrun simctl install "$udid" "$app"
shot download-dark      6 "${empty[@]}" -autoLocation griffith -autoDownloadPack us-ca-sd
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl uninstall "$udid" "$bundle"
xcrun simctl install "$udid" "$app"
launch 10 "${empty[@]}"

xcrun simctl ui "$udid" increase_contrast enabled
shot listen-contrast-dark     8 "${seeded[@]}" -autoLocation joshua-tree -autoScreen listen
shot set-desert-contrast-dark 9 "${seeded[@]}" -autoLocation griffith -autoScreen set -autoSet us-ca-desert
xcrun simctl ui "$udid" appearance light
shot listen-contrast-light    8 "${seeded[@]}" -autoLocation joshua-tree -autoScreen listen
xcrun simctl ui "$udid" increase_contrast disabled

xcrun simctl ui "$udid" appearance dark
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot listen-ax5   8 "${seeded[@]}" -autoLocation griffith -autoScreen listen
shot section-ax5  9 "${seeded[@]}" -autoLocation griffith -autoScreen listen -autoScrollTo local-set
shot atlas-ax5    9 "${seeded[@]}" -autoLocation griffith -autoScreen guide

xcrun simctl ui "$udid" content_size large
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true
