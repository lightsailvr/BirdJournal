#!/usr/bin/env bash
# Puts the app's mock lens in the Meta Ray-Ban Display Simulator Chrome extension (issue #82): builds the app, installs
# and launches it on one simulator in mock-lens mode (`-autoMockLens YES`: pair a mock Meta Ray-Ban Display, start the
# lens with three fake species, walk the inputs), and waits until Mock Device Kit's preview server answers on the
# port. Then the tab at http://127.0.0.1:<port>/ with the extension selected shows the 600×600 Display; a click there
# reaches the app's Display tap handler (the extension's arrow keys do not arrive as Inputs swipes).
#
#   BIRDJOURNAL_SIMULATOR=BJ-82 scripts/mock-lens-in-chrome.sh                  # walk "navLeft navDown"
#   BIRDJOURNAL_SIMULATOR=BJ-82 scripts/mock-lens-in-chrome.sh "navLeft select"  # another walk
#   --friend     then a friend's notable find arrives as a push would: the lens's friend banner (issue #67)
#   --camera     a drawn frame stands in for the camera, so the viewfinders show a picture and "Capture a sighting"
#                saves its photo (issue #193). `wait` in the inputs is a second with no input, to pass the viewfinder's
#                echo window: --camera "navUp select" is the capture viewfinder, "navUp select wait select" the
#                "Photo saved" page.
#   --species N  hear N fake species instead of three (0 to 6; 0 is the empty list, 6 has a second page)
#   --port 9001  another port (default 9000, the port the maintainer's tab has open)
#   --no-build   reuse the last build in build/DerivedData
#   --stop       quit the app on that simulator, which frees the port
#
# One simulator at a time: the simulators share the Mac's loopback, so only one process can hold the port. If another
# process holds it, the script says which and stops; quit that app (or pass --port) first.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/watchdog.sh"
source "$repo_root/scripts/lib/simulator.sh"

port=9000
build=1
stop=0
friend=NO
camera=NO
species=3
inputs="navLeft navDown"
while (($#)); do
    case "$1" in
        --port) port="${2:?--port needs a number}"; shift ;;
        --no-build) build=0 ;;
        --stop) stop=1 ;;
        --friend) friend=YES ;;
        --camera) camera=YES ;;
        --species) species="${2:?--species needs a number}"; shift ;;
        -*) echo "error: unknown option $1 (--port N, --no-build, --stop, --friend, --camera, --species N)" >&2; exit 2 ;;
        *) inputs="$1" ;;
    esac
    shift
done

destination="$(resolve_destination)"
udid="$(destination_udid "$destination")"
[[ -n "$udid" ]] || { echo "error: cannot resolve a simulator from '$destination'; set BIRDJOURNAL_SIMULATOR" >&2; exit 1; }
derived_data="$repo_root/build/DerivedData"
app_path="$derived_data/Build/Products/Debug-iphonesimulator/BirdJournal.app"

if ((stop)); then
    xcrun simctl terminate "$udid" "$app_bundle_id" 2>/dev/null || true
    echo "==> Quit $app_bundle_id on $udid; port $port is free unless something else holds it."
    exit 0
fi

# The port must be free, or held by this app on this simulator (which the relaunch replaces).
holder="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fpc 2>/dev/null | sed -n 's/^p//p' | head -1 || true)"
if [[ -n "$holder" ]]; then
    holder_command="$(ps -o command= -p "$holder" 2>/dev/null || true)"
    if [[ "$holder_command" != *"CoreSimulator/Devices/$udid/"*"BirdJournal.app/BirdJournal"* ]]; then
        echo "error: port $port is held by pid $holder: ${holder_command:0:160}" >&2
        echo "       Only one process can serve the lens on a port. Pass --port <another port> and open that port in" >&2
        echo "       Chrome. Do not quit an app on a simulator that is not yours; ask whoever runs it." >&2
        exit 1
    fi
fi

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" >/dev/null

if ((build)); then
    mkdir -p "$repo_root/build/test-logs"
    log="$repo_root/build/test-logs/$(date +%Y%m%d-%H%M%S)-mock-lens-build.log"
    echo "==> Building BirdJournal for $udid (log: $log)"
    # A stale app bundle or build database in a worktree's DerivedData fails the onnxruntime CodeSign step.
    rm -rf "$app_path" "$derived_data/Build/Intermediates.noindex/XCBuildData"
    run_watched build "$log" "$udid" xcodebuild \
        -project "$repo_root/BirdJournal/BirdJournal.xcodeproj" -scheme BirdJournal \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived_data" -skipMacroValidation \
        build >/dev/null || { echo "error: build failed; see $log" >&2; exit 1; }
fi

echo "==> Installing and launching in mock-lens mode (inputs: $inputs, port $port)"
xcrun simctl install "$udid" "$app_path"
xcrun simctl launch --terminate-running-process "$udid" "$app_bundle_id" \
    -autoMockLens YES -autoMockLensInputs "$inputs" -autoMockLensFriend "$friend" -autoMockLensCamera "$camera" \
    -autoMockLensSpecies "$species" -mockPreviewPort "$port" >/dev/null

for _ in $(seq 1 60); do
    if curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
        echo "==> The preview server answers on http://127.0.0.1:$port/"
        echo "    In Chrome, open (or reload) that URL and select the Meta Ray-Ban Display Simulator extension."
        echo "    Phone screenshot: xcrun simctl io $udid screenshot lens.png"
        echo "    Quit when done (frees the port): BIRDJOURNAL_SIMULATOR=… scripts/mock-lens-in-chrome.sh --stop"
        exit 0
    fi
    sleep 1
done
echo "error: nothing answered on http://127.0.0.1:$port/ within 60 s of launch" >&2
exit 1
