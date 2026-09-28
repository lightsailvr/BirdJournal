#!/usr/bin/env bash
# Captures the phone screens of issue #28 on the booted iPhone simulator, light and dark, plus the accessibility
# large-text states, into docs/screenshots/<date>/ at half size. Needs a debug build installed
# (`scripts/build-and-test.sh` or an xcodebuild of the BirdJournal scheme) and the labeled clip from
# scripts/download-clips.sh for the listening screens.
#
#   scripts/screenshots.sh                      # iPhone 17, every screen
#   scripts/screenshots.sh 435CAF4C-...         # another simulator's UDID
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
udid="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 (' | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')}"
bundle="com.matthewcelia.mybirdjournal"
app="$repo_root/build/DerivedData/Build/Products/Debug-iphonesimulator/BirdJournal.app"
wav="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"
out="$repo_root/docs/screenshots/$(date +%Y-%m-%d)"
mkdir -p "$out"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"

shot() {  # name seconds flags...
    local name="$1" wait="$2"; shift 2
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    xcrun simctl launch "$udid" "$bundle" "$@" >/dev/null
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
    sips -Z 800 "$out/$name.png" >/dev/null   # half size: the PR does not need 3x pixels
    echo "$name"
}

for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance"
    common=(-inMemoryAlbum YES -seedJournal YES)
    shot "listen-$appearance"    7  "${common[@]}" -autoScreen listen
    shot "listening-$appearance" 22 -inMemoryAlbum YES -autoPhoneListening "$wav" -autoScreen listening
    shot "review-$appearance"    34 -inMemoryAlbum YES -autoPhoneListening "$wav" -autoScreen review
    shot "journal-$appearance"   7  "${common[@]}" -autoScreen journal
    shot "sighting-$appearance"  7  "${common[@]}" -autoScreen sighting
    shot "share-$appearance"     9  "${common[@]}" -autoScreen share
    shot "guide-$appearance"     7  "${common[@]}" -autoScreen guide
    shot "profile-$appearance"   7  "${common[@]}" -autoScreen profile
    shot "packs-$appearance"     9  "${common[@]}" -autoScreen packs
    shot "pack-$appearance"      9  "${common[@]}" -autoScreen pack
    shot "credits-$appearance"   7  "${common[@]}" -autoScreen credits
    shot "source-$appearance"    8  "${common[@]}" -autoScreen source
done
xcrun simctl ui "$udid" appearance light
shot "journal-empty"   7 -inMemoryAlbum YES -autoScreen journal
shot "listen-empty"    7 -inMemoryAlbum YES -autoScreen listen

# Accessibility sizes: the largest Dynamic Type setting through the simulator's content size override.
xcrun simctl ui "$udid" content_size extra-extra-extra-large
shot "listen-xxxl"     7 -inMemoryAlbum YES -seedJournal YES -autoScreen listen
shot "listening-xxxl" 22 -inMemoryAlbum YES -autoPhoneListening "$wav" -autoScreen listening
shot "journal-xxxl"    7 -inMemoryAlbum YES -seedJournal YES -autoScreen journal
shot "profile-xxxl"    7 -inMemoryAlbum YES -autoScreen profile
xcrun simctl ui "$udid" content_size accessibility-extra-extra-extra-large
shot "listen-ax5"      7 -inMemoryAlbum YES -seedJournal YES -autoScreen listen
shot "listening-ax5"  22 -inMemoryAlbum YES -autoPhoneListening "$wav" -autoScreen listening
shot "packs-ax5"       9 -inMemoryAlbum YES -autoScreen packs
xcrun simctl ui "$udid" content_size medium
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
echo "wrote $(ls "$out" | wc -l | tr -d ' ') screenshots to $out"
