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
   species (scientific name, common name as the BirdNET+ label file spells it, iNaturalist taxon id, Wikipedia URL).
   `overrides.json` beside it forces photos in or out per species (`{"Sayornis nigricans": {"include": [id], "exclude": [id]}}`).
2. **Metadata.** Research-grade observations of each species in the region, with their photos, observers and
   licenses. Two sources describe the same iNaturalist data:
   - `--source api` (default): `api.inaturalist.org/v1/observations`, newest first up to `inat_created_before`
     (the most-faved observations are the oddities), cached under `cache/api/` so a rebuild is offline. Photos
     deleted from iNaturalist since the pin drop out of the candidate set; `overrides.json` pins the rest.
   - `--source opendata --metadata-dir DIR`: the [iNaturalist Open Data](https://github.com/inaturalist/inaturalist-open-data)
     metadata dump (`observations.csv`, `photos.csv`, `observers.csv`, tens of gigabytes), scanned with DuckDB inside
     the pack's bounding box, in one scan for every species of the pack.
3. **Filter.** Keeps CC0, CC BY and CC BY-NC photos of research-grade observations that have an observer and an
   observation URL; everything else is counted in `report.json` (`candidates.py`, `licenses.py`).
4. **Download.** The `large` (1024 px) rendition of the first `--limit` cleared candidates from the Open Data bucket
   into `cache/photos/`, and the `original` of the chosen ones.
5. **Detect.** A COCO SSD MobileNet v1 from the ONNX model zoo (Apache-2.0, pinned by SHA-256 in `detector.py`)
   finds the bird; photos without one, with a bird under 2 % of the frame, or with a bird narrower than the
   260-pixel lens crop in the original, are dropped (`pipeline.py`).
6. **Score.** Each crop gets `0.45 × bird area + 0.35 × background darkness + 0.20 × sharpness`, all in 0…1
   (`scoring.py`): big birds on dark, sharp backgrounds read best on the additive lens display. Crops under 0.4
   sharpness are dropped before ranking. The score cannot tell a hand-held or dead bird from a perched one; that
   is what `overrides.json` is for (see the Los Angeles file for examples).
7. **Select.** Top five per species (at most one photo per observation), overrides first; fewer than three is a
   logged gap (`selection.py`).
8. **Write.** `pack.sqlite` (tables `pack`, `species`, `photo`, `lookalike`), `lens/<photo>.jpg` (260 px square, tight crop),
   `phone/<photo>.jpg` (looser crop, 1200 px max), `LICENSE` with every credit and link, `report.json` with counts,
   chosen ids and gaps, and optionally a zip (`writer.py`).

The Swift `Pack` module (`SpeciesPack`) reads the output; `SCHEMA_VERSION` in `writer.py` and
`SpeciesPack.schemaVersion` move together.

## Layout

| Path | What |
| --- | --- |
| `src/packbuilder/` | The package; `cli.py` is the `packbuilder` command, `pipeline.py` the build order. |
| `packs/<id>/pack.json`, `overrides.json` | Pack definitions and manual overrides (committed). |
| `tests/` | pytest over synthetic fixtures: license filter, scoring order, selection and overrides, crops, Open Data join, writer output. The detector test runs only when the model and some photos are cached. |
| `cache/` | Downloads (gitignored): `models/`, `api/`, `photos/large/`, `photos/original/`. |

Output goes to the repo's `packs/<id>/` (see `packs/README.md`).
