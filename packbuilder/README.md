# packbuilder

Builds BirdJournal species packs (issue #8, spec "Pack builder"). One command from a clean checkout:

```sh
scripts/build-pack.sh                      # builds packs/us-ca-la/ and build/packs/us-ca-la.zip
scripts/build-pack.sh us-ca-la --limit 60  # more candidates per species; any `packbuilder build` flag passes through
```

Needs [uv](https://docs.astral.sh/uv/) (`brew install uv`); it creates the Python 3.12+ environment from
`pyproject.toml` and `uv.lock` on first run. Tests: `cd packbuilder && uv run pytest`.

## What a build does

1. **Definition.** `packs/<id>/pack.json` names the pack, its iNaturalist place and bounding box, the date
   (`inat_created_before`) after which observations are ignored so a rebuild sees the same candidates, and the
   species (scientific name and common name as the BirdNET+ label file spells them, iNaturalist taxon id, Wikipedia
   URL; `tests/test_definition.py` checks every entry against the label file). `overrides.json` beside it forces
   photos in or out per species and replaces description fields by hand:
   `{"Sayornis nigricans": {"include": [id], "exclude": [id], "limit": 200, "trust_article": true, "description": {"field_marks": "...", "size": "...", "habitat": "...", "summary": "..."}}}`
   (`limit` widens that species' candidate shortlist; `trust_article` takes a Wikipedia article the binomial check
   would refuse, for a species BirdNET and Wikipedia name differently after a split).
   The Los Angeles list is the 150 most-observed species of LA County on iNaturalist plus ten heard more than seen
   (the file's `comment` says how it was made).
2. **Describe.** Each species' English Wikipedia article (plain-text extract, cached under `cache/wikipedia/` by
   title so a rebuild is offline and gives the same text) is cut by rule into a `summary` (the lead's first sentences,
   60 words), `field_marks` (the Description section's plumage sentences, skipping measurements, 20 words: the lens
   details page's budget after name, size and habitat, credit and button), `size` (the first body length in cm,
   "13–15 cm") and `habitat` (the three habitat terms the article uses most, from a fixed vocabulary: "coast, rivers,
   water"). An article whose lead does not name the binomial (a redirect to a family page) is refused and logged; the
   override file fills such species. Every text records its article revision (`description_source`) and the LICENSE
   lists them under CC BY-SA 4.0 (`descriptions.py`). `packs/<id>/wikipedia.lock.json` (committed) records the
   revision each title was cut from: a build from a clean cache fetches the current articles, warns for every revision
   that moved since the lock, and re-pins the lock, so drift in the text is visible in the diff. `--no-descriptions`
   skips the step.
3. **Metadata.** Research-grade observations of each species in the region, with their photos, observers and
   licenses. Two sources describe the same iNaturalist data:
   - `--source api` (default): `api.inaturalist.org/v1/observations`, newest first up to `inat_created_before`
     (the most-faved observations are the oddities), cached under `cache/api/` so a rebuild is offline. Photos
     deleted from iNaturalist since the pin drop out of the candidate set; `overrides.json` pins the rest.
   - `--source opendata --metadata-dir DIR`: the [iNaturalist Open Data](https://github.com/inaturalist/inaturalist-open-data)
     metadata dump (`observations.csv`, `photos.csv`, `observers.csv`, tens of gigabytes), scanned with DuckDB inside
     the pack's bounding box, in one scan for every species of the pack.
4. **Filter.** Keeps CC0, CC BY and CC BY-NC photos of research-grade observations that have an observer and an
   observation URL; everything else is counted in `report.json` (`candidates.py`, `licenses.py`).
5. **Download.** The `large` (1024 px) rendition of the first `--limit` cleared candidates from the Open Data bucket
   into `cache/photos/`, `--workers` (default 8) at a time, and the `original` of the chosen ones.
6. **Detect.** A COCO SSD MobileNet v1 from the ONNX model zoo (Apache-2.0, pinned by SHA-256 in `detector.py`)
   finds the bird; originals smaller than the 552 × 368 lens crop, photos without a bird, with a bird under 2 % of the
   frame, or with a bird that, padded, cannot fill the lens crop's 368-pixel height in the original (about 263 pixels
   of bird), are dropped (`pipeline.py`).
7. **Score.** Each crop gets `0.45 × bird area + 0.35 × background darkness + 0.20 × sharpness`, all in 0…1
   (`scoring.py`): big birds on dark, sharp backgrounds read best on the additive lens display. Crops under 0.4
   sharpness are dropped before ranking. The score cannot tell a hand-held or dead bird from a perched one; that
   is what `overrides.json` is for (see the Los Angeles file for examples).
8. **Select.** Top five per species (at most one photo per observation), overrides first; fewer than three is a
   logged gap (`selection.py`).
9. **Write.** `pack.sqlite` (tables `pack`, `species`, `photo`, `lookalike`), `lens/<photo>.jpg` (552 × 368 px, tight card-width crop),
   `phone/<photo>.jpg` (looser crop, 1200 px max), `LICENSE` with every photo and text credit and link, `report.json`
   with counts, chosen ids, description sources and the photo and description gaps, and optionally a zip (`writer.py`).

The Swift `Pack` module (`SpeciesPack`) reads the output; `SCHEMA_VERSION` in `writer.py` and
`SpeciesPack.schemaVersion` move together.

## Layout

| Path | What |
| --- | --- |
| `src/packbuilder/` | The package; `cli.py` is the `packbuilder` command, `pipeline.py` the build order. |
| `packs/<id>/pack.json`, `overrides.json`, `wikipedia.lock.json` | Pack definitions, manual overrides and the Wikipedia revisions the text came from (committed). |
| `tests/` | pytest over synthetic fixtures: license filter, scoring order, selection and overrides, crops, Open Data join, Wikipedia text rules, the pipeline through fakes, writer output, and the committed definitions against the BirdNET label file. The detector test runs only when the model and some photos are cached; the label test only when the models are downloaded. |
| `cache/wikipedia/` | Fetched article pages (gitignored with the rest of `cache/`). |
| `cache/` | Downloads (gitignored): `models/`, `api/`, `wikipedia/`, `photos/large/`, `photos/original/`. |

Output goes to the repo's `packs/<id>/`, which is not committed: the built pack is published as a GitHub Release asset
and fetched by `scripts/download-pack.sh` (see `packs/README.md`).
