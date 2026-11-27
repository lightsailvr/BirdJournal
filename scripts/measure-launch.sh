#!/usr/bin/env bash
# Launch time on a simulator, from the app's own `launch` signposts (issue #208; #220 repeats it with the North America
# pack). Installs the app fresh on your simulator, launches it a few times unmeasured, then <runs> times measured, and
# prints the median of each interval beside the lowest and highest.
#
#   BIRDJOURNAL_SIMULATOR=BJ-208 scripts/measure-launch.sh [--configuration Debug|Release] [--runs 10] [--label before]
#       [--app <BirdJournal.app> --built-from <commit>] [--sightings <n>] [-- <more launch arguments>]
#   scripts/measure-launch.sh --summary [--max-load 30] before-Debug after-Debug
#       the table again, a column per label; with --max-load, over the launches taken at that load average or less
#
# What a launch is here: `simctl launch` of a terminated app. The clock starts when the process starts (`proc_pidinfo`) and
# stops at the "Journal interactive" signpost, which the root emits when it appears with the stores loaded (the same proxy
# as docs/screenshots/175: a view's appearance, not a tap answered). The phases are the app's signpost intervals, read from
# the simulator's `log stream`: wall time, not CPU time, and some of them overlap.
#
# The state is a fresh install's: the app is UNINSTALLED from the simulator first, so there is no journal and no downloaded
# pack, only the bundled one. That is why the script refuses to run without BIRDJOURNAL_SIMULATOR or
# BIRDJOURNAL_DESTINATION: never point it at a simulator whose journal matters.
#   Debug   launches with `-freshPackStorage YES -packIndexURL http://127.0.0.1:9/index.json`, so the index is never read
#           and nothing depends on the network; `--sightings <n>` fills an album file with n sightings first (`-seedLarge`).
#   Release has no debug flags: it reads the pack index from the network after its first launch and caches it, so its later
#           launches decode that index too (`Read cached index and sets`), as a birder's do. The unmeasured launches wait
#           for that file, and every launch's line says whether it was there (`index_cached`).
#
# Comparing two builds: build each, keep its app (`--app`), and alternate short series of both under the same label
# (`--label before`, `--label after`, twice or more each), since the load on this Mac moves the numbers more than most
# changes do. Each series appends to build/launch-times/<label>.jsonl, a line per launch with the load average beside it;
# delete the file to start a label again. Without `--app` the script builds the working tree first.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/watchdog.sh"
source "$repo_root/scripts/lib/simulator.sh"
metrics="$repo_root/scripts/lib/launch_metrics.py"
out="$repo_root/build/launch-times"
bundle="$app_bundle_id"

configuration=Debug
runs=10
warmups=2
label=""
app=""
commit=""
sightings=0
extra=()
while (($#)); do
    case "$1" in
        --configuration) configuration="${2:?--configuration needs Debug or Release}"; shift ;;
        --runs) runs="${2:?--runs needs a number}"; shift ;;
        --warmups) warmups="${2:?--warmups needs a number}"; shift ;;
        --label) label="${2:?--label needs a name}"; shift ;;
        --app) app="${2:?--app needs the path of a built BirdJournal.app}"; shift ;;
        --built-from) commit="${2:?--built-from needs the commit the app was built from}"; shift ;;
        --sightings) sightings="${2:?--sightings needs a number}"; shift ;;
        --summary)
            shift
            files=() filter=()
            if [[ "${1:-}" == --max-load ]]; then filter=(--max-load "${2:?--max-load needs a load average}"); shift 2; fi
            for name in "$@"; do files+=("$out/$name.jsonl"); done
            exec python3 "$metrics" summary ${filter[@]+"${filter[@]}"} "${files[@]}"
            ;;
        --) shift; extra=("$@"); break ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$configuration" == Debug || "$configuration" == Release ]] || { echo "error: --configuration is Debug or Release" >&2; exit 2; }
if [[ -z "${BIRDJOURNAL_SIMULATOR:-}" && -z "${BIRDJOURNAL_DESTINATION:-}" ]]; then
    echo "error: set BIRDJOURNAL_SIMULATOR (or BIRDJOURNAL_DESTINATION): this uninstalls the app from the simulator it measures on" >&2
    exit 2
fi
if ((sightings > 0)) && [[ "$configuration" != Debug ]]; then
    echo "error: --sightings seeds through a debug launch flag; a Release build has none" >&2
    exit 2
fi
label="${label:-$configuration}"
mkdir -p "$out"

destination="$(resolve_destination)"
udid="$(destination_udid "$destination")"
[[ -n "$udid" ]] || { echo "error: no simulator for $destination" >&2; exit 2; }

built=0
if [[ -z "$app" ]]; then
    built=1
    if [[ "$configuration" == Debug ]]; then
        scheme=BirdJournal; derived_data="$repo_root/build/DerivedData"
    else
        scheme=BirdJournal-Release; derived_data="$repo_root/build/DerivedData-release"
    fi
    app="$derived_data/Build/Products/$configuration-iphonesimulator/BirdJournal.app"
    # A stale app bundle or build database fails the onnxruntime CodeSign step (scripts/build-and-test.sh).
    rm -rf "$app" "$derived_data/Build/Intermediates.noindex/XCBuildData"
    echo "==> Building $configuration (log: $repo_root/build/measure-launch-build.log)"
    xcodebuild -project "$repo_root/BirdJournal/BirdJournal.xcodeproj" -scheme "$scheme" -configuration "$configuration" \
        -destination "$destination" -derivedDataPath "$derived_data" -skipMacroValidation build \
        >"$repo_root/build/measure-launch-build.log" 2>&1 || { tail -30 "$repo_root/build/measure-launch-build.log"; exit 1; }
fi
[[ -d "$app" ]] || { echo "error: no app at $app" >&2; exit 2; }

arguments=()
if [[ "$configuration" == Debug ]]; then
    arguments+=(-freshPackStorage YES -packIndexURL http://127.0.0.1:9/index.json -collectionIntroShown YES)
    ((sightings > 0)) && arguments+=(-albumFile "launch-$sightings" -seedLarge "$sightings")
else
    arguments+=(-whatsNew hide)
fi
arguments+=(${extra[@]+"${extra[@]}"})

if [[ -z "$commit" ]]; then
    commit="$(git -C "$repo_root" rev-parse --short HEAD)"
    git -C "$repo_root" diff --quiet HEAD -- BirdJournal || commit="$commit+changes"
    ((built)) || commit="unknown (--app without --built-from)"
fi

echo "==> $label: $configuration, $runs launches after $warmups unmeasured, on $destination"
echo "==> App: $app (built from $commit)"
uptime
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
xcrun simctl uninstall "$udid" "$bundle" >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app"
xcrun simctl privacy "$udid" grant location "$bundle"
xcrun simctl privacy "$udid" grant microphone "$bundle"

stream="$(mktemp -t birdjournal-launch)"
xcrun simctl spawn "$udid" log stream --signpost --style ndjson \
    --predicate 'subsystem == "com.matthewcelia.mybirdjournal" AND category == "launch"' >"$stream" 2>/dev/null &
stream_pid=$!
cleanup() {
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    pkill -P "$stream_pid" >/dev/null 2>&1 || true
    kill "$stream_pid" >/dev/null 2>&1 || true
    rm -f "$stream"
}
trap cleanup EXIT
sleep 3  # the stream misses what is logged before it attaches

# Whether the app has kept a pack index from the network (PackStorage's `index.json`), which a launch then decodes.
index_cached() {
    local data
    data="$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null)" || return 1
    [[ -f "$data/Library/Application Support/Packs/index.json" ]]
}

# One launch: prints its JSON line once the app is interactive (a minute at most), then lets it settle. The next one ends it.
launch() {  # settle seconds
    local settle="$1" pid started line="" status cached=no
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    sleep 2
    index_cached && cached=yes
    pid="$(xcrun simctl launch "$udid" "$bundle" "${arguments[@]}" | sed -n 's/.*: \([0-9][0-9]*\)$/\1/p')"
    [[ -n "$pid" ]] || { echo "error: the app didn't launch" >&2; return 1; }
    started="$(python3 "$metrics" start-time "$pid")"
    for _ in $(seq 1 300); do
        status=0
        line="$(python3 "$metrics" run "$stream" "$pid" "$started" "configuration=$configuration" "commit=$commit" "index_cached=$cached")" || status=$?
        ((status == 0)) && break
        ((status == 3)) || return 1
        sleep 0.2
    done
    [[ -n "$line" ]] || { echo "error: no \"Journal interactive\" signpost within a minute" >&2; return 1; }
    sleep "$settle"
    echo "$line"
}

# The first launch after an install is slower, and it is the one that seeds an album or first reads the index.
for _ in $(seq 1 "$warmups"); do
    launch $((sightings > 0 ? 20 : 6)) >/dev/null
done
if [[ "$configuration" == Release ]]; then
    # Still running from the last unmeasured launch: give its index read a minute, so every measured launch starts alike.
    for _ in $(seq 1 60); do
        index_cached && break
        sleep 1
    done
    index_cached || echo "warning: the pack index never arrived, so these launches decode no cached index" >&2
fi
for run in $(seq 1 "$runs"); do
    line="$(launch 3)"
    echo "$line" >>"$out/$label.jsonl"
    echo "$line" | python3 -c 'import json, sys; r = json.load(sys.stdin); print("    launch %s: %.0f ms to interactive, %.1f ms opening the bundled pack, load %.1f, %s" % (sys.argv[1], r["process_to_interactive_ms"], r.get("open_bundled_pack_ms", float("nan")), r["load_average"], r.get("context", "")))' "$run"
done
uptime
python3 "$metrics" summary "$out/$label.jsonl"
