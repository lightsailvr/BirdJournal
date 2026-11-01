#!/usr/bin/env bash
# Builds the BirdJournal app for the iOS simulator, runs its tests, then every BirdJournalKit package test.
#
# The Device Access Toolkit ships iOS-only xcframeworks, so the package cannot be tested with `swift test` on macOS.
# Xcode only exposes the package's test bundles through the scheme it synthesises inside the package directory
# (`BirdJournalKit-Package`), so the package is its own xcodebuild run sharing one DerivedData.
#
# By default there are four runs, each under the watchdog (issue #82), and a failure in one does not stop the next:
#   1. build-for-testing the app;
#   2. the app's tests without the Mock Device Kit suites (unit tests and BirdJournalUITests);
#   3. the Mock Device Kit suites on their own (`BirdJournalTests/MockDeviceKitTests`), so a mock failure or hang
#      cannot hide the other results (the split that worked in #54 and #55);
#   4. the BirdJournalKit package tests.
# Any xcodebuild test arguments given (`-only-testing:…`, `-skip-testing:…`) replace runs 2 to 4 with one app run
# that takes them, e.g. `scripts/build-and-test.sh -only-testing:BirdJournalTests/MockDeviceKitTests`.
# `--package` with test arguments runs them on the package instead (`--package -only-testing:LensSessionTests`).
#
# Simulator (one per agent, since agents run in parallel; see CLAUDE.md):
#   BIRDJOURNAL_SIMULATOR=BJ-82          a simulator by name, created (iPhone 17 Pro, newest iOS) if missing
#   BIRDJOURNAL_DESTINATION='platform=iOS Simulator,id=…'   any xcodebuild destination (wins over the name)
#   neither: the "iPhone 17" simulator, for the maintainer's own runs.
#
# Timeouts, so a hang is a failure and never a stall:
#   BIRDJOURNAL_TEST_ALLOWANCE (seconds, default 180) and BIRDJOURNAL_TEST_MAX_ALLOWANCE (default 300) are
#   xcodebuild's per-test execution time allowances; the Mock Device Kit suites also carry Swift Testing time limits.
#   BIRDJOURNAL_QUIET_MINUTES (default 6): the watchdog kills a run whose log has not grown for that long, samples
#   the test host into the logs, shuts the run's simulator down and fails the run.
# Logs: build/test-logs/<time>-<run>.log.
#
# `--release` runs only `AccountSwitchUITests` in the Release configuration (the `BirdJournal-Release` scheme, issue
# #88: the account is off in Release), with its own DerivedData so the Debug build is not thrown away.
#
# `--hang-probe await|spin|silent` runs only the deliberately hung tests in HangProbeTests.swift, to check the
# timeouts: `await` and `spin` fail at their one-minute time limit, `silent` at xcodebuild's allowance, or at the
# watchdog with the allowance raised (BIRDJOURNAL_TEST_ALLOWANCE=3000 BIRDJOURNAL_QUIET_MINUTES=2).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/watchdog.sh"
source "$repo_root/scripts/lib/simulator.sh"

derived_data="$repo_root/build/DerivedData"
log_dir="$repo_root/build/test-logs"
mkdir -p "$log_dir"
stamp="$(date +%Y%m%d-%H%M%S)"

target=app
hang_probe=""
test_args=()
while (($#)); do
    case "$1" in
        --package) target=package ;;
        --release) target=release ;;
        --hang-probe) hang_probe="${2:?--hang-probe needs await, spin or silent}"; shift ;;
        *) test_args+=("$1") ;;
    esac
    shift
done

if [[ -n "$hang_probe" ]] && { ((${#test_args[@]})) || [[ "$target" == package ]]; }; then
    echo "error: --hang-probe takes no other arguments" >&2
    exit 2
fi

destination="$(resolve_destination)"
udid="$(destination_udid "$destination")"
echo "==> Destination: $destination${udid:+ ($udid)}"
uptime

# `-collect-test-diagnostics never`: on a failure xcodebuild otherwise runs `simctl diagnose`, which gathers every
# crash report on the Mac and sat silent for over 3 minutes in #82, long enough to look like a hang.
timeouts=(
    -collect-test-diagnostics never
    -test-timeouts-enabled YES
    -default-test-execution-time-allowance "${BIRDJOURNAL_TEST_ALLOWANCE:-180}"
    -maximum-test-execution-time-allowance "${BIRDJOURNAL_TEST_MAX_ALLOWANCE:-300}"
)
app=(
    xcodebuild
    -project "$repo_root/BirdJournal/BirdJournal.xcodeproj"
    -scheme BirdJournal
    -destination "$destination"
    -derivedDataPath "$derived_data"
    -skipMacroValidation
)
package=(
    xcodebuild
    -scheme BirdJournalKit-Package
    -destination "$destination"
    -derivedDataPath "$derived_data"
    -skipMacroValidation
)

failures=()
# run_step <name> <command…>: one watched run, recorded as a failure (and the rest carry on) when it fails.
run_step() {
    local name="$1" status=0
    shift
    echo "==> $name (log: $log_dir/$stamp-$name.log)"
    run_watched "$name" "$log_dir/$stamp-$name.log" "$udid" "$@" || status=$?
    if ((status != 0)); then
        failures+=("$name (exit $status, log $log_dir/$stamp-$name.log)")
    fi
    return 0
}

# A stale app bundle or build database in a worktree's DerivedData fails the onnxruntime CodeSign step.
rm -rf "$derived_data/Build/Products/Debug-iphonesimulator/BirdJournal.app" \
    "$derived_data/Build/Intermediates.noindex/XCBuildData"

if [[ -n "$hang_probe" ]]; then
    run_step build "${app[@]}" build-for-testing
    if ((${#failures[@]} == 0)); then
        export TEST_RUNNER_BIRDJOURNAL_HANG_PROBE="$hang_probe"
        run_step "hang-probe-$hang_probe" \
            "${app[@]}" "${timeouts[@]}" test-without-building -only-testing:BirdJournalTests/HangProbeTests
    fi
elif [[ "$target" == release ]]; then
    release_data="$repo_root/build/DerivedData-release"
    rm -rf "$release_data/Build/Products/Release-iphonesimulator/BirdJournal.app" \
        "$release_data/Build/Intermediates.noindex/XCBuildData"
    run_step release xcodebuild -project "$repo_root/BirdJournal/BirdJournal.xcodeproj" -scheme BirdJournal-Release \
        -destination "$destination" -derivedDataPath "$release_data" -skipMacroValidation "${timeouts[@]}" test
elif [[ "$target" == package ]]; then
    cd "$repo_root/BirdJournal/BirdJournalKit"
    run_step package "${package[@]}" "${timeouts[@]}" test ${test_args[@]+"${test_args[@]}"}
else
    run_step build "${app[@]}" build-for-testing
    if ((${#failures[@]} == 0)); then
        if ((${#test_args[@]})); then
            run_step app-tests "${app[@]}" "${timeouts[@]}" test-without-building "${test_args[@]}"
        else
            run_step app-tests "${app[@]}" "${timeouts[@]}" test-without-building \
                -skip-testing:BirdJournalTests/MockDeviceKitTests -skip-testing:BirdJournalTests/HangProbeTests
            run_step mock-device-kit "${app[@]}" "${timeouts[@]}" test-without-building \
                -only-testing:BirdJournalTests/MockDeviceKitTests
            cd "$repo_root/BirdJournal/BirdJournalKit"
            run_step package "${package[@]}" "${timeouts[@]}" test
        fi
    fi
fi

if ((${#failures[@]})); then
    echo "==> FAILED:" >&2
    printf '    %s\n' "${failures[@]}" >&2
    exit 1
fi
echo "==> All runs passed."
