#!/usr/bin/env bash
# Capture the species page before/after at default and AX5, light/dark, with one/several/no patch.
# Build and install the desired revision first, then: capture.sh <simulator UUID> <before|after>
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
udid="${1:?simulator UUID}" stage="${2:?before or after}"
bundle=com.matthewcelia.mybirdjournal
out="$root/docs/screenshots/179/$stage"
mkdir -p "$out"
restore() { xcrun simctl ui "$udid" content_size large; xcrun simctl ui "$udid" appearance dark; }
trap restore EXIT
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
for appearance in light dark; do
 xcrun simctl ui "$udid" appearance "$appearance"
 for size in large accessibility-extra-extra-extra-large; do
  xcrun simctl ui "$udid" content_size "$size"
  for scenario in one several none; do
   seed=(-seedJournal YES -autoCardSpecies 'Sayornis nigricans')
   [[ "$scenario" != several ]] || seed=(-seedGallery YES -autoCardSpecies 'Haemorhous mexicanus')
   [[ "$scenario" != none ]] || seed=(-autoCardSpecies 'Branta canadensis')
   xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
   xcrun simctl launch "$udid" "$bundle" -inMemoryAlbum YES -collectionIntroShown YES -autoScreen gallery "${seed[@]}" >/dev/null
   sleep 5
   raw="$out/$scenario-$appearance-$size.png"
   xcrun simctl io "$udid" screenshot "$raw" >/dev/null 2>&1
   sips -s format jpeg -s formatOptions 82 -Z 1000 "$raw" --out "${raw%.png}.jpg" >/dev/null
   rm "$raw"
  done
 done
done
xcrun simctl status_bar "$udid" clear
