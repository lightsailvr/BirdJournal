# Sourced by scripts/build-and-test.sh and scripts/mock-lens-in-chrome.sh (issue #82). macOS has no `timeout`, so a
# command that goes quiet is ended here: `run_watched` runs it with its output in a log (and on the terminal), and
# when the log has not grown for BIRDJOURNAL_QUIET_MINUTES it samples the test host, kills the command and every
# process on the run's simulator, and fails with a clear message.
#
# Only processes on this run's simulator are touched: other agents run their own simulators at the same time.

watchdog_quiet_minutes="${BIRDJOURNAL_QUIET_MINUTES:-6}"
app_bundle_id="com.matthewcelia.mybirdjournal"

# The UDID behind an xcodebuild destination: `id=…` as given, `name=…` looked up among the available simulators.
# Empty when it cannot be resolved (then the watchdog can only kill xcodebuild itself).
destination_udid() {
    local destination="$1" name
    if [[ "$destination" =~ id=([0-9A-Fa-f-]{36}) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$destination" =~ name=([^,]+) ]]; then
        name="${BASH_REMATCH[1]}"
        xcrun simctl list devices available | sed -n "s/^ *$(printf '%s' "$name" | sed 's/[][\.*^$/]/\\&/g') (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1
    fi
}

# Ends a hung run on simulator `udid`: the app (the app-hosted test host) and the UI-test runner, matched by the
# simulator's own app container path so nothing on another simulator is hit, then shuts that simulator down. The
# shutdown is the recovery that worked in #54 and #55 (a hung toolkit leaves the simulator's Bluetooth stand-in
# wedged); the next xcodebuild boots it again.
kill_simulator_processes() {
    local udid="$1"
    [[ -n "$udid" ]] || return 0
    xcrun simctl terminate "$udid" "$app_bundle_id" >/dev/null 2>&1 || true
    pkill -KILL -f "CoreSimulator/Devices/$udid/data/Containers/Bundle/Application/" >/dev/null 2>&1 || true
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
}

# Samples the hung test host for the log: in #82 a `sample` showed which toolkit thread was spinning.
sample_test_host() {
    local udid="$1" log="$2" pid
    [[ -n "$udid" ]] || return 0
    for pid in $(pgrep -f "CoreSimulator/Devices/$udid/.*BirdJournal.app/BirdJournal" 2>/dev/null); do
        echo "==> Watchdog: sampling test host pid $pid into ${log%.log}-hang-sample-$pid.txt"
        sample "$pid" 3 -file "${log%.log}-hang-sample-$pid.txt" >/dev/null 2>&1 || true
        ps -o pid,%cpu,etime,command -p "$pid" | cut -c1-160
    done
}

# run_watched <label> <log> <udid> <command…>: runs the command with stdout and stderr in <log>, shown live, and
# kills it when the log goes quiet for watchdog_quiet_minutes. Returns the command's status, or 124 when killed.
run_watched() {
    local label="$1" log="$2" udid="$3"
    shift 3
    local quiet=$((watchdog_quiet_minutes * 60)) pid tail_pid now modified rc
    : >"$log"
    "$@" >"$log" 2>&1 &
    pid=$!
    tail -n +1 -f "$log" &
    tail_pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 10
        now=$(date +%s)
        modified=$(stat -f %m "$log")
        if ((now - modified > quiet)); then
            {
                echo
                echo "==> Watchdog: $label wrote nothing for $watchdog_quiet_minutes minutes; killing it (issue #82)."
            } >>"$log"
            sample_test_host "$udid" "$log" >>"$log" 2>&1
            pkill -TERM -P "$pid" >/dev/null 2>&1 || true
            kill -TERM "$pid" 2>/dev/null || true
            kill_simulator_processes "$udid"
            sleep 10
            pkill -KILL -P "$pid" >/dev/null 2>&1 || true
            kill -KILL "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            sleep 1
            kill "$tail_pid" 2>/dev/null || true
            wait "$tail_pid" 2>/dev/null || true
            echo "error: $label hung (no output for $watchdog_quiet_minutes minutes) and was killed by the watchdog. Log: $log" >&2
            return 124
        fi
    done
    rc=0
    wait "$pid" || rc=$?
    sleep 1
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    return "$rc"
}
