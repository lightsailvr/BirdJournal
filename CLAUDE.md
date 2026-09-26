# BirdJournal

Bird identification on Meta Ray-Ban Display glasses. iOS 27, Swift 6, SwiftUI, Meta Wearables Device Access Toolkit 1.0.0, BirdNET+ V3.0 via ONNX Runtime.

Read before working: `DECISIONS.md` (settled design choices, wins over `spec.md`), `DAT-SETUP-CHECKLIST.md` (toolkit facts and verification steps), `docs/spec-v1-glasses-bird-id.md` (the v1 spec).

Layout: `BirdJournal/` is the Xcode project and `BirdJournal/BirdJournalKit/` the local package with the `Identification`, `LensSession`, `Pack` and `Album` modules (one test target each, none depends on the toolkit; the glasses adapter and Mock Device Kit tests live in the app target); `packbuilder/` the Python species-pack builder (to be created); `docs/` specs and ADRs; `models/` the pinned model manifest; `scripts/` build and download scripts.

Build and test: `scripts/build-and-test.sh` (iOS 27 simulator; `swift test` does not work because the toolkit is iOS-only). Models: `scripts/download-models.sh` fetches the files in `models/manifest.json` and verifies SHA-256.

## Agent skills

### Issue tracker

Issues and specs live in this repo's GitHub Issues (`lightsailvr/BirdJournal`), via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
