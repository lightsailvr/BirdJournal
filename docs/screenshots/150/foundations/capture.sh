#!/usr/bin/env bash
# Issue #150 slice 2's evidence: the type, headings, tab bar, page and paper card, from the running app, at half size, at the
# default text size (`large`) and the largest (ax5). Needs a debug build, the test clip (`scripts/download-clips.sh`) and uv.
# Leaves the simulator's text size at `large`.
#
#   docs/screenshots/150/foundations/capture.sh <simulator UDID> <app path>
#   docs/screenshots/150/foundations/capture.sh --sheets
#
# The waits are fixed, so look over the shots afterwards; CAPTURE_SLOW=<seconds> adds to each wait.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/foundations"
references="${FG_REFERENCES:-/Users/matthewcelia/Documents/repos/BirdJournal/output/ux-audit/reference}"

if [[ "${1:-}" == "--sheets" ]]; then
    mkdir -p "$out/sheets"
    sheet() {  # name, columns, shots
        local name="$1" columns="$2"; shift 2
        uv run -q "$repo_root/docs/screenshots/138/sheet.py" "$out/sheets/$name.jpg" "$columns" "$@"
    }
    in_out() { local s; for s in "$@"; do printf '%s\n' "$out/$s.jpg"; done; }
    # The reference beside the screens that carry its headings and tab bar.
    mapfile_compat() { local line; while IFS= read -r line; do shots+=("$line"); done; }
    shots=("$references/4-set-page.png"); mapfile_compat < <(in_out set-dark atlas-dark); sheet reference-set 3 "${shots[@]}"
    shots=("$references/5-compare.png"); mapfile_compat < <(in_out sightings-dark profile-dark); sheet reference-headings 3 "${shots[@]}"
    shots=("$references/1-guild-page.png"); mapfile_compat < <(in_out guild-dark members-dark); sheet reference-faces 3 "${shots[@]}"
    shots=(); mapfile_compat < <(in_out board-light patch-light card-light card-dark listen-light atlas-light); sheet light-page-and-card 6 "${shots[@]}"
    shots=(); mapfile_compat < <(in_out reveal-dark patch-dark goal-dark packs-dark pack-dark settings-light); sheet caps-dots-words 6 "${shots[@]}"
    shots=(); mapfile_compat < <(in_out set-ax5 atlas-ax5 profile-ax5 guild-ax5 sightings-ax5 packs-ax5); sheet ax5 6 "${shots[@]}"
    shots=(); mapfile_compat < <(in_out empty-guilds-dark empty-profile-dark sign-in-dark); sheet states 3 "${shots[@]}"
    exit 0
fi

udid="${1:?give the simulator UDID}"
app="${2:?give the app path}"
bundle="com.matthewcelia.mybirdjournal"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
slow="${CAPTURE_SLOW:-0}"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"
xcrun simctl location "$udid" set 34.1365,-118.2942
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep $((wait + slow))
    xcrun simctl io "$udid" screenshot --type=jpeg "$out/$name.jpg" >/dev/null 2>&1
    sips -Z 800 -s formatOptions 78 "$out/$name.jpg" >/dev/null
    echo "$name"
}

# The tab bar at full size, from the screen `shot` left up: the stitched ring beside the system's symbols.
tab_bar() {  # name
    xcrun simctl io "$udid" screenshot --type=png "$out/$1.png" >/dev/null 2>&1
    uv run -q --with pillow python - "$out/$1.png" "$out/$1.jpg" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
image.crop((0, image.height - 280, image.width, image.height)).save(sys.argv[2], quality=85)
PY
    rm "$out/$1.png"
    echo "$1"
}

empty=(-inMemoryAlbum YES)
seeded=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES)
guilds=(-inMemoryAlbum YES -seedJournal YES -collectionIntroShown YES -fakeAccount signedIn -fakeCircles some)
phoebe=(-autoCardSpecies "Sayornis nigricans")

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
shot listen-dark     8 "${empty[@]}" -autoScreen listen
tab_bar tab-bar-dark
shot set-dark        9 "${seeded[@]}" -autoScreen set
shot atlas-dark      9 "${seeded[@]}" -autoScreen guide
shot packs-dark      9 "${seeded[@]}" -autoScreen packs
shot pack-dark       9 "${seeded[@]}" -autoScreen pack
shot profile-dark    9 "${seeded[@]}" -autoScreen profile
shot sightings-dark  9 "${seeded[@]}" -autoScreen sightings
shot board-dark     10 "${seeded[@]}" -autoScreen cards
shot patch-dark     10 "${seeded[@]}" "${phoebe[@]}" -autoScreen card
shot card-dark      11 "${seeded[@]}" "${phoebe[@]}" -autoScreen card-back
shot reveal-dark    10 "${seeded[@]}" "${phoebe[@]}" -autoScreen reveal
shot guild-dark     10 "${guilds[@]}" -autoScreen circle
shot goal-dark      10 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-feed
shot members-dark   10 "${guilds[@]}" -autoScreen circle -autoScrollTo guild-settings
shot empty-guilds-dark 9 "${empty[@]}" -fakeAccount signedIn -fakeCircles empty -autoScreen circles
shot sign-in-dark    9 "${empty[@]}" -autoScreen circles
shot empty-profile-dark 9 "${seeded[@]}" -autoCardSpecies "Branta canadensis" -autoScreen species

xcrun simctl ui "$udid" appearance light
shot listen-light    8 "${empty[@]}" -autoScreen listen
tab_bar tab-bar-light
shot atlas-light     9 "${seeded[@]}" -autoScreen guide
shot set-light       9 "${seeded[@]}" -autoScreen set
shot board-light    10 "${seeded[@]}" -autoScreen cards
shot patch-light    10 "${seeded[@]}" "${phoebe[@]}" -autoScreen card
shot card-light     11 "${seeded[@]}" "${phoebe[@]}" -autoScreen card-back
shot settings-light  8 "${empty[@]}" -autoScreen settings
shot guild-light    10 "${guilds[@]}" -autoScreen circle

xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot set-ax5         9 "${seeded[@]}" -autoScreen set
shot atlas-ax5       9 "${seeded[@]}" -autoScreen guide
shot packs-ax5       9 "${seeded[@]}" -autoScreen packs
shot profile-ax5     9 "${seeded[@]}" -autoScreen profile
shot sightings-ax5   9 "${seeded[@]}" -autoScreen sightings
shot guild-ax5      10 "${guilds[@]}" -autoScreen circle

xcrun simctl ui "$udid" content_size large
xcrun simctl ui "$udid" appearance dark
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl status_bar "$udid" clear 2>/dev/null || true
