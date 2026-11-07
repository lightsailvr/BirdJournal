# Version identity — issue #182

`BirdJournal/Version.xcconfig` proposes `0.1.0` for the next beta. The app and widget inherit it in both configurations. Cloud input plists use `CI_BUILD_NUMBER`; local plists carry `BirdJournalBuildCommit` with the Git short SHA and optional `-dirty`. The source plists and signed products are never changed by the generator.

Checked without starting another concurrent Xcode build:

- `python3 -m unittest discover -s scripts/tests -p test_build_info.py -v`: 6 passed. Tests cover both generated app/widget Cloud numbers, local clean and dirty metadata, unchanged-output timestamp, missing/enclosing repository handling, Cloud-without-number failure, and shared project configuration.
- `plutil -lint BirdJournal/BirdJournal.xcodeproj/project.pbxproj`: passed.
- Swift frontend parsing of SettingsView and VersionTests: passed.

Integrated verification should run `BirdJournalTests/VersionTests`, inspect the built app and embedded widget Info.plists, and run the Release account-switch check because project settings changed. A Cloud archive with the actual App Store Connect workflow remains necessary to verify the distributed version; this task did not access or change App Store Connect.
