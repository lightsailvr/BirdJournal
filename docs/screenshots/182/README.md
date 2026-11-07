# Version identity — issue #182

`BirdJournal/Version.xcconfig` uses the confirmed `0.1.0` for this beta. The app and widget inherit it in both configurations. Cloud input plists use `CI_BUILD_NUMBER`; local plists carry `BirdJournalBuildCommit` with the Git short SHA and optional `-dirty`. The source plists and signed products are never changed by the generator.

Verified on the combined review branch:

- `python3 -m unittest discover -s scripts/tests -p test_build_info.py -v`: 7 passed. Tests cover both generated app/widget Cloud numbers, local clean and dirty metadata, unchanged-output timestamp, missing/enclosing repository handling, Cloud-without-number failure, and shared project configuration.
- `plutil -lint BirdJournal/BirdJournal.xcodeproj/project.pbxproj`: passed.
- Swift frontend parsing of SettingsView and VersionTests: passed.

`BirdJournalTests/VersionTests` passed, including formatting and the actual embedded widget's matching version. The built local app and widget both reported 0.1.0 (1) with the same commit key. The canonical `scripts/build-and-test.sh --release` check passed both account-switch UI tests.

A local Cloud simulation (`CI_XCODE_CLOUD=TRUE CI_BUILD_NUMBER=42`) built both app and widget and inspected their **processed product** Info.plists: both report 0.1.0 (42), with no local commit key. This caught and fixed Xcode overriding the generated input's build number: the shared config now expands `CURRENT_PROJECT_VERSION = $(CI_BUILD_NUMBER:default=1)` before plist processing. An integration test checks Xcode's real expansion for local and Cloud settings. A Cloud archive with the actual App Store Connect workflow remains necessary to verify the distributed version; this task did not access or change App Store Connect.
