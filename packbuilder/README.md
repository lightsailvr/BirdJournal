# packbuilder

Builds BirdJournal species packs (issue #8, spec "Pack builder"). One command from a clean checkout:

```sh
scripts/build-pack.sh                      # builds packs/us-ca-la/ and build/packs/us-ca-la.zip
scripts/build-pack.sh us-ca-la --limit 60  # more candidates per species; any `packbuilder build` flag passes through
```

Needs [uv](https://docs.astral.sh/uv/) (`brew install uv`); it creates the Python 3.12+ environment from
`pyproject.toml` and `uv.lock` on first run. The sounds step also needs ffmpeg (`brew install ffmpeg`), the BirdNET
models (`scripts/download-models.sh`) and a xeno-canto API key in `XENO_CANTO_API_KEY` (from
https://xeno-canto.org/account; keep it in your shell profile, never in the repo); `--no-sounds` skips the step.
Tests: `cd packbuilder && uv run pytest` (they never see the key and make no request).

## What a build does

1. **Definition.** `packs/<id>/pack.json` names the pack, its iNaturalist place and bounding box, the date
   (`inat_created_before`) after which observations are ignored so a rebuild sees the same candidates, and the
   species (scientific name and common name as the BirdNET+ label file spells them, iNaturalist taxon id, Wikipedia
   URL; `tests/test_definition.py` checks every entry against the label file). `overrides.json` beside it forces
   photos in or out per species (an excluded photo drops the rest of its observation too) and replaces description fields by hand:
   `{"Sayornis nigricans": {"include": [id], "exclude": [id], "limit": 200, "trust_article": true, "description": {"field_marks": "...", "size": "...", "habitat": "...", "summary": "..."}}}`
   (`limit` widens that species' candidate shortlist; `trust_article` takes a Wikipedia article the binomial check
   would refuse, for a species BirdNET and Wikipedia name differently after a split).
   The Los Angeles list is the 150 most-observed species of LA County on iNaturalist plus ten heard more than seen
   (the file's `comment` says how it was made). A region made of several places (the counties around Orlando) lists
   them as `inat_place_ids` instead of `inat_place_id`; the photos come from their union.

   A new pack's list starts from `packbuilder draft` (`species_list.py`), which ranks research-grade observations of
   birds in the places, maps each taxon to its BirdNET+ label (reusing the committed packs' entries, then the label
   file's binomial, then its common name, which is logged as a rename to check), skips hybrids and `--exclude`d
   species, and prints the `species` array; the ranking is cached under `cache/api/` like the build's pages:

   ```sh
   uv run packbuilder draft --place 934 --place 839 --before 2026-09-27 --top 150 \
       --season 10,11 --season-top 120 --add "Strix varia" > species.json
   ```

   `--season` takes the most-observed species of those months too (a trip pack wants the wintering ducks and the
   migrants a yearly ranking buries); `--add` takes a species by hand (the ones heard far more than seen). A taxon the
   label file does not name is printed as unresolved for a person to map or drop.
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
3. **Sounds** (issue #41, `sounds.py`). One **song** and one **call** per species, each an 8 s clip, from
   [xeno-canto](https://xeno-canto.org) (API v3, `xenocanto.py`): one search per species for its recordings in the
   pack's country (`country` in `pack.json`, default United States; a worldwide search only when the country has no
   usable song or call), ranked A/B grade first, then open licenses (CC0, CC BY, CC BY-SA) before NonCommercial
   (CC BY-NC, CC BY-NC-SA), then grade, MP3 over WAV, 5–60 s long, no background species, the country, the newest.
   No-derivatives recordings are refused (the clip is an adaptation), as are juveniles' calls, subsong and birds
   answering playback. A species xeno-canto leaves without any clip falls back to iNaturalist's research-grade
   observation sounds (`sounds_inat.py`; CC0, CC BY and CC BY-SA only; untyped, so its clip is the `sound` kind). Each recording tried is cut to
   its loudest 8 s, high-passed at 200 Hz, loudness-normalized, faded and encoded mono 48 kHz AAC at 64 kbps
   (`audio.py`, ffmpeg), then run through BirdNET+ V3.0 in the app's 3 s windows; it is kept only when the species
   is the top of the mean scores, else the next is tried (`--sound-tries`, default 3, per kind). `overrides.json`
   takes a `sounds` object per species: `{"song": "xc-123", "call": "xc-456", "exclude": ["xc-789"],
   "xeno_canto_name": "Genus species"}`. `packs/<id>/sounds.lock.json` (committed) records each chosen recording
   with its credit: a rebuild uses it without searching and downloads only the chosen files (none from a warm
   cache), and a locked recording that stops passing is replaced by a search, visible in the diff.

   **Keeping to xeno-canto's limits.** xeno-canto allows downloads but blocks a client that makes too many requests
   per second or per hour, and publishes no figure (third-party clients cite about 1,000 an hour). So every
   xeno-canto request, search or file download, goes one at a time through one pacer at least `--xc-interval`
   seconds apart (default 4, at most 900 an hour; under 2 is refused), and a lock on `cache/sounds/xeno-canto/` refuses
   a second build that tries to request beside a running one; only the first result page (up to 500
   recordings) is read; a run stops after `--xc-max-requests` (default 1500); the first 429, 503 or 403 stops the
   build at once with no retry; and every answer and file is cached under `cache/sounds/`, so a rerun resumes where
   the last stopped. The Los Angeles pack took 537 requests, about 3.4 per species; a rebuild from the cache and the lock takes none. The key is sent only as the API's
   `key` parameter, never cached or logged. iNaturalist sounds are paced at one request a second.
4. **Metadata.** Research-grade observations of each species in the region, with their photos, observers and
   licenses. Two sources describe the same iNaturalist data:
   - `--source api` (default): `api.inaturalist.org/v1/observations`, newest first up to `inat_created_before`
     (the most-faved observations are the oddities), cached under `cache/api/` so a rebuild is offline. Photos
     deleted from iNaturalist since the pin drop out of the candidate set; `overrides.json` pins the rest.
   - `--source opendata --metadata-dir DIR`: the [iNaturalist Open Data](https://github.com/inaturalist/inaturalist-open-data)
     metadata dump (`observations.csv`, `photos.csv`, `observers.csv`, tens of gigabytes), scanned with DuckDB inside
     the pack's bounding box, in one scan for every species of the pack.
5. **Filter.** Keeps CC0, CC BY and CC BY-NC photos of research-grade observations that have an observer and an
   observation URL; everything else is counted in `report.json` (`candidates.py`, `licenses.py`).
6. **Download.** The `large` (1024 px) rendition of the first `--limit` cleared candidates from the Open Data bucket
   into `cache/photos/`, `--workers` (default 8) at a time, and the `original` of the chosen ones.
7. **Detect.** A COCO SSD MobileNet v1 from the ONNX model zoo (Apache-2.0, pinned by SHA-256 in `detector.py`)
   finds the bird; originals smaller than the 552 × 368 lens crop, photos without a bird, with a bird under 2 % of the
   frame, or with a bird that, padded, cannot fill the lens crop's 368-pixel height in the original (about 263 pixels
   of bird), are dropped (`pipeline.py`).
8. **Score.** Each crop gets `0.45 × bird area + 0.35 × background darkness + 0.20 × sharpness`, all in 0…1
   (`scoring.py`): big birds on dark, sharp backgrounds read best on the additive lens display. Crops under 0.4
   sharpness are dropped before ranking. The score cannot tell a hand-held or dead bird from a perched one; that
   is what `overrides.json` is for (see the Los Angeles file for examples).
9. **Select.** Top five per species (at most one photo per observation), overrides first; fewer than three is a
   logged gap (`selection.py`).
10. **Write.** `pack.sqlite` (tables `pack`, `species`, `photo`, `sound`, `lookalike`), `lens/<photo>.jpg` (552 × 368 px, tight card-width crop),
   `phone/<photo>.jpg` (looser crop, 1200 px max), `sounds/<id>.m4a`, `LICENSE` with every photo, sound and text credit and link, `report.json`
   with counts, chosen ids, description sources, chosen and rejected sounds and the photo, description and sound gaps, and optionally a zip (`writer.py`).

The Swift `Pack` module (`SpeciesPack`) reads the output; `SCHEMA_VERSION` in `writer.py` and
`SpeciesPack.schemaVersion` move together.

## Layout

| Path | What |
| --- | --- |
| `src/packbuilder/` | The package; `cli.py` is the `packbuilder` command, `pipeline.py` the build order. |
| `packs/<id>/pack.json`, `overrides.json`, `wikipedia.lock.json`, `sounds.lock.json` | Pack definitions, manual overrides, the Wikipedia revisions the text came from and the recordings the sounds came from (committed). |
| `tests/` | pytest over synthetic fixtures: license filter, scoring order, selection and overrides, crops, Open Data join, Wikipedia text rules, the pipeline through fakes, writer output, and the committed definitions against the BirdNET label file. The detector test runs only when the model and some photos are cached; the label test only when the models are downloaded. |
| `cache/wikipedia/` | Fetched article pages (gitignored with the rest of `cache/`). |
| `cache/` | Downloads (gitignored): `models/`, `api/`, `wikipedia/`, `photos/large/`, `photos/original/`, `sounds/` (xeno-canto and iNaturalist answers and files, and the encoded clips). |

Output goes to the repo's `packs/<id>/`, which is not committed: the built pack is published as a GitHub Release asset
and fetched by `scripts/download-pack.sh` (see `packs/README.md`).
