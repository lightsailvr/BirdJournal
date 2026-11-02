# Sourced after scripts/lib/watchdog.sh by scripts/build-and-test.sh and scripts/mock-lens-in-chrome.sh (issue #82):
# which simulator a run uses.
# Agents run in parallel, one simulator each, so two xcodebuilds never share a simulator (or its Mock Device Kit
# state). See CLAUDE.md, "Build and test".

# Prints the UDID of the available simulator named "$1", creating it as an iPhone 17 Pro on the newest iOS runtime if
# there is none.
ensure_simulator() {
    local name="$1" udid runtime
    udid="$(simulator_udids "$name" | head -1)"
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

# Whether StoreKit on simulator "$1" already holds the app's StoreKit test configuration (issue #93). `SKTestSession`
# registers `BirdJournal.storekit` in the simulator's StoreKit container the first time a test host creates one, but
# purchases only use it in processes launched after that: the first tip a new simulator's first test host buys goes
# to the sandbox instead and waits for an Apple Account sign-in until the test times out. The path is StoreKit's own
# and may move; if it does, this says no every time and each run primes again (one more test host launch, about
# 15 s). The bundle ID is the app target's PRODUCT_BUNDLE_IDENTIFIER (project.pbxproj).
storekit_bundle_id=com.matthewcelia.mybirdjournal
storekit_config_registered() {
    local udid="$1"
    [[ -n "$(find "$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Containers/Shared/AppGroup" \
        -path "*/Octane/$storekit_bundle_id/Configuration.storekit" -print -quit 2>/dev/null)" ]]
}
