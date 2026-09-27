# packs/

Built species packs, as `scripts/build-pack.sh` writes them from `packbuilder/packs/<id>/` (see
`packbuilder/README.md`). Each pack is a folder:

| File | What |
| --- | --- |
| `pack.sqlite` | `pack` (id, name, region, version, schema_version, built_at, license_text), `species` (id, scientific_name, common_name, birdnet_label, inat_taxon_id, wikipedia_url, summary, field_marks, size, habitat, description_source, sort_order), `photo` (id, species_id, rank, file_lens, file_phone, observer, observer_login, license, credit_line, short_credit, source_url, photo_url, inat_photo_id, tags, score), `lookalike` (species_id, other_species_id, one_line_difference; empty in v1, nothing on the lens shows it). |
| `lens/<inat photo id>.jpg` | 552 × 368 px crop around the bird, the full width of the species card (DECISIONS.md: a bundled image lays out at pixel size on the 600 px canvas). |
| `phone/<inat photo id>.jpg` | Looser crop, at most 1200 px on the long side, for the phone. |
| `LICENSE` | Every photo's credit in iNaturalist's attribution form with the observation and original photo links, then every species' Wikipedia article revision under "Text credits" (CC BY-SA 4.0). |
| `report.json` | Per-species counts, rejected candidates by reason, chosen photo ids, the description source, and `gaps` (`photos`: species with fewer than three; `descriptions`: species without text). |

Descriptions (`summary`, `field_marks`, `size`, `habitat`) are cut from each species' English Wikipedia article by
rule (`packbuilder/src/packbuilder/descriptions.py`) or written by hand in the pack's `overrides.json`;
`description_source` is the permanent link to the article revision the text came from, NULL for hand-written text.
Schema version 2 (`SpeciesPack.schemaVersion` in the Swift `Pack` module).

## Where the built packs come from

Built packs are **not committed**: the Los Angeles pack is about 160 species and 150 MB of JPEGs. `manifest.json`
pins each pack to a zip on this repository's GitHub Releases (release tag, asset name, SHA-256, byte count), and
`scripts/download-pack.sh` fetches, verifies and unpacks them into `packs/<id>/` (the Xcode Cloud post-clone hook
runs it after the models). The repository is private, so the script uses a logged-in `gh` CLI or a `GITHUB_TOKEN`
with contents read access, and keeps the zips under `build/pack-downloads/`: everything under `packs/` ships in the app's resource bundle, so nothing but packs may live here. Everything under `packs/` except this file and `manifest.json` is gitignored.

`us-ca-la` is the pack bundled in the app: the `Pack` package target's `Sources/Pack/Packs` folder is a symlink to
this directory and is declared as a package resource, so the pack ships in the package's resource bundle and
`SpeciesPack.bundled()` reads it offline. The `PackTests` bundle reads it too, so run the download before the tests.

## Publishing a new build

1. `scripts/build-pack.sh us-ca-la` writes `packs/us-ca-la/` and `build/packs/us-ca-la.zip` (reproducible from the
   committed `pack.json`, `overrides.json` and `wikipedia.lock.json` plus the builder's cache: iNaturalist metadata
   pinned to `inat_created_before`, Wikipedia pages cached by title and their revisions pinned in the lock).
2. Bump `version` in `packbuilder/packs/us-ca-la/pack.json` when the contents change for users, and rebuild.
3. `scripts/pin-pack.sh us-ca-la` writes the tag (`pack-us-ca-la-v<version>`), asset name, SHA-256 and byte count
   into `manifest.json`.
4. `gh release create pack-us-ca-la-v<version> build/packs/us-ca-la.zip --title "..." --notes "..."`, then commit
   the manifest.
