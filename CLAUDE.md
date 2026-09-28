# BirdJournal

Bird identification on Meta Ray-Ban Display glasses. iOS 27, Swift 6, SwiftUI, Meta Wearables Device Access Toolkit 1.0.0, BirdNET+ V3.0 via ONNX Runtime.

Read before working: `DECISIONS.md` (settled design choices, wins over `spec.md`), `DAT-SETUP-CHECKLIST.md` (toolkit facts and verification steps), `docs/spec-v1-glasses-bird-id.md` (the v1 spec).

Layout: `BirdJournal/` is the Xcode project (the app target: `RootView` with the Listen / Journal / Field Guide tabs, `Listen/` with the `ListeningCoordinator` over both audio sources, `Journal/`, `Guide/`, `Packs/`, `Share/`, `Settings/` with the DEBUG-only `DeveloperView`, `Design/` with the tokens, and the glasses adapter under `Glasses/` and `Lens/`) and `BirdJournal/BirdJournalKit/` the local package with the `Identification`, `LensSession`, `Pack` and `Album` modules (one test target each, none depends on the toolkit; the glasses adapter and Mock Device Kit tests live in the app target); `packbuilder/` the Python species-pack builder (uv project; `scripts/build-pack.sh` builds a pack from `packbuilder/packs/<id>/` into `packs/<id>/`, which the `Pack` target's `Packs` resource folder symlinks so the bundled LA pack ships in the package bundle; built packs are not committed: `packs/manifest.json` pins them to GitHub Release zips, `scripts/download-pack.sh` fetches the bundled one and `scripts/publish-pack-index.sh` lists them all as `index.json` on the `packs` release for the phone to download); `docs/` specs and ADRs; `models/` the pinned model manifest (the `Identification` target's `Models` resource folder is a symlink to it, so the model files ship in the package bundle); `fixtures/` the labeled-clip manifest for engine tests (audio gitignored); `scripts/` build and download scripts; `BirdJournal/ci_scripts/` Xcode Cloud hooks (post-clone fetches the models and the bundled pack from this public repo's GitHub Releases).

Build and test: `scripts/build-and-test.sh` (iOS 27 simulator; `swift test` does not work because the toolkit is iOS-only). The app scheme's tests include `BirdJournalUITests` (XCUITest, real taps on the running app); run just those with `-only-testing:BirdJournalUITests`. Models: `scripts/download-models.sh` fetches the files in `models/manifest.json` and verifies SHA-256. Packs: `scripts/download-pack.sh` fetches the bundled pack's zip from `packs/manifest.json` (public GitHub Releases, no credentials; the `PackTests` bundle reads the bundled pack). Test clips: `scripts/download-clips.sh` fetches the entries in `fixtures/clips.json`; the engine tests skip clips that are absent. Pack builder tests: `cd packbuilder && uv run pytest`.

## Agent skills

### Issue tracker

Issues and specs live in this repo's GitHub Issues (`lightsailvr/BirdJournal`), via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
