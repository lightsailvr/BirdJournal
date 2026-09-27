# packs/

Built species packs, as `scripts/build-pack.sh` writes them from `packbuilder/packs/<id>/` (see
`packbuilder/README.md`). Each pack is a folder:

| File | What |
| --- | --- |
| `pack.sqlite` | `pack` (id, name, region, version, schema_version, built_at, license_text), `species` (id, scientific_name, common_name, birdnet_label, inat_taxon_id, wikipedia_url, summary, field_marks, size, habitat, sort_order), `photo` (id, species_id, rank, file_lens, file_phone, observer, observer_login, license, credit_line, short_credit, source_url, photo_url, inat_photo_id, tags, score). |
| `lens/<inat photo id>.jpg` | 260 px square crop around the bird, for the lens photo page (DECISIONS.md: a bundled image lays out at pixel size on the 600 px canvas). |
| `phone/<inat photo id>.jpg` | Looser crop, at most 1200 px on the long side, for the phone. |
| `LICENSE` | Every photo's credit in iNaturalist's attribution form, with the observation and original photo links. |
| `report.json` | Per-species counts, rejected candidates by reason, chosen photo ids and gaps. |

`us-ca-la` is the Los Angeles pack bundled in the app: the `Pack` package target's `Sources/Pack/Packs` folder is a
symlink to this directory and is declared as a package resource, so the pack ships in the package's resource
bundle and `SpeciesPack.bundled()` reads it offline. It is committed while it is ten species (about 10 MB); when
#12 grows it to about 150 species it should move to a GitHub Release fetched by a script and the Xcode Cloud
post-clone hook, like the models. The zip archives (the download format for other regions, #13) are written to
`build/packs/` and not committed.

Descriptions (`summary`, `field_marks`, `size`, `habitat`) are empty until #12.
