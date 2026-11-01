# Sourced by scripts/build-and-test.sh and scripts/mock-lens-in-chrome.sh (issue #82): which simulator a run uses.
# Agents run in parallel, one simulator each, so two xcodebuilds never share a simulator (or its Mock Device Kit
# state). See CLAUDE.md, "Build and test".

# Prints the UDID of the available simulator named "$1", creating it as an iPhone 17 Pro on the newest iOS runtime if
# there is none.
ensure_simulator() {
    local name="$1" udid runtime
    udid="$(xcrun simctl list devices available | sed -n "s/^ *$(printf '%s' "$name" | sed 's/[][\.*^$/]/\\&/g') (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1)"
    if [[ -z "$udid" ]]; then
        runtime="$(xcrun simctl list runtimes available | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -1)"
        [[ -n "$runtime" ]] || { echo "error: no iOS simulator runtime installed" >&2; return 1; }
        udid="$(xcrun simctl create "$name" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")"
        echo "==> Created simulator $name ($udid) on $runtime" >&2
    fi
    echo "$udid"
}

# The xcodebuild destination for this run: BIRDJOURNAL_DESTINATION as given, else the simulator named
# BIRDJOURNAL_SIMULATOR (created if missing), else "iPhone 17".
resolve_destination() {
    if [[ -n "${BIRDJOURNAL_DESTINATION:-}" ]]; then
        echo "$BIRDJOURNAL_DESTINATION"
    elif [[ -n "${BIRDJOURNAL_SIMULATOR:-}" ]]; then
        echo "platform=iOS Simulator,id=$(ensure_simulator "$BIRDJOURNAL_SIMULATOR")"
    else
        echo "platform=iOS Simulator,name=iPhone 17"
    fi
}
