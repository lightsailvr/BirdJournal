#!/usr/bin/env bash
# Builds the BirdJournal app for the iOS simulator and runs its app-hosted tests (Mock Device Kit smoke tests),
# then runs every BirdJournalKit package test.
#
# The Device Access Toolkit ships iOS-only xcframeworks, so the package cannot be tested with
# `swift test` on macOS. Xcode only exposes the package's test bundles through the scheme it
# synthesises when invoked inside the package directory (`BirdJournalKit-Package`), so this is two
# xcodebuild runs sharing one DerivedData.
#
# Override the simulator with BIRDJOURNAL_DESTINATION, e.g.
#   BIRDJOURNAL_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' scripts/build-and-test.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
destination="${BIRDJOURNAL_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
derived_data="$repo_root/build/DerivedData"

echo "==> Building and testing BirdJournal.app"
xcodebuild \
    -project "$repo_root/BirdJournal/BirdJournal.xcodeproj" \
    -scheme BirdJournal \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -skipMacroValidation \
    test

echo "==> Testing BirdJournalKit"
cd "$repo_root/BirdJournal/BirdJournalKit"
xcodebuild \
    -scheme BirdJournalKit-Package \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -skipMacroValidation \
    test
