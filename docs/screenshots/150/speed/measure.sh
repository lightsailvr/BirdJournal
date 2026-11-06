#!/usr/bin/env bash
# Issue #150 slice 4's numbers: builds the app, then launches it on your simulator over a big album (`-seedLarge`) and lets
# `SpeedTour` walk the screens. Each album is launched twice: the first pass seeds it (and leaves a Guild cache for the
# second), the second reads it back off the disk. Its lines land in `<label>-<sightings>.txt` beside this script.
#
#   BIRDJOURNAL_SIMULATOR=BJ-150-4 docs/screenshots/150/speed/measure.sh <label> [sightings ...]
#
# Needs the test clip (`scripts/download-clips.sh`). Set MEASURE_NO_BUILD=1 to reuse the last build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
out="$repo_root/docs/screenshots/150/speed"
source "$repo_root/scripts/lib/watchdog.sh"
source "$repo_root/scripts/lib/simulator.sh"
mkdir -p "$repo_root/build"
derived_data="$repo_root/build/DerivedData"
app="$derived_data/Build/Products/Debug-iphonesimulator/BirdJournal.app"
bundle="com.matthewcelia.mybirdjournal"
clip="$repo_root/fixtures/clips/birdnet-example-soundscape.wav"

label="${1:?give a label: before or after}"
shift
sizes=("$@")
((${#sizes[@]})) || sizes=(1000 5000 20000)

destination="$(resolve_destination)"
udid="$(destination_udid "$destination")"
if [[ -z "${MEASURE_NO_BUILD:-}" ]]; then
    rm -rf "$app" "$derived_data/Build/Intermediates.noindex/XCBuildData"
    xcodebuild -project "$repo_root/BirdJournal/BirdJournal.xcodeproj" -scheme BirdJournal -destination "$destination" \
        -derivedDataPath "$derived_data" -skipMacroValidation build >"$repo_root/build/measure-build.log" 2>&1 \
        || { tail -30 "$repo_root/build/measure-build.log"; exit 1; }
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" "$app"
xcrun simctl ui "$udid" content_size large
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"

# One launch: waits for the tour's last line, at most five minutes.
tour() {  # sightings, then the file to write
    local n="$1" file="$2" log pid
    log="$(mktemp)"
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    sleep 2
    xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" \
        -albumFile "speed-$n" -seedLarge "$n" -speedTour YES -collectionIntroShown YES \
        -fakeAccount signedIn -fakeCircles some -fakeCircleLatency 1 -circleCacheFile "speed-$n" \
        -autoPhoneListening "$clip" -autoLocation griffith -captionWriter none >"$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 300); do
        grep -q "SPEED done" "$log" && break
        sleep 1
    done
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    tr -d '\r' <"$log" | grep "^SPEED" >"$file" || true
    grep -q "SPEED done" "$file" || echo "warning: the tour didn't finish over $n sightings; see $log" >&2
}

for n in "${sizes[@]}"; do
    # The album stays in the simulator's tmp from run to run; a fresh install or a different label's run starts it again.
    tour "$n" "$out/$label-$n-first.txt"
    tour "$n" "$out/$label-$n.txt"
    echo "== $label, $n sightings"
    cat "$out/$label-$n.txt"
done
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
