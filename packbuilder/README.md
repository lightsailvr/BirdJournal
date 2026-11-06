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
The pack-art step paints on comfybox's FLUX.3 ComfyUI over the tailnet (`--comfy`, default `http://comfybox:8189`;
`art/README.md`) whatever `art.lock.json` lacks; `--no-art` skips it.
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
     (the most-faved observations are the oddities), asking only for observations with a photo under the photo
     license set, so the shortlist reaches as far back in time as those licenses need; cached under `cache/api/`
     (the file names carry the license set, so another set is another query) so a rebuild is offline. Photos
     deleted from iNaturalist since the pin drop out of the candidate set; `overrides.json` pins the rest.
   - `--source opendata --metadata-dir DIR`: the [iNaturalist Open Data](https://github.com/inaturalist/inaturalist-open-data)
     metadata dump (`observations.csv`, `photos.csv`, `observers.csv`, tens of gigabytes), scanned with DuckDB inside
     the pack's bounding box, in one scan for every species of the pack.
5. **Filter.** Keeps photos under the photo license set of research-grade observations that have an observer and an
   observation URL; everything else is counted in `report.json` (`candidates.py`, `licenses.py`). The set is
   configuration per asset kind in `licenses.py`: photos take `PHOTO_LICENSES`, CC0, CC BY and CC BY-SA (ADR-0001:
   no NonCommercial photo since the app takes tips; `--photo-licenses cc0,cc-by,cc-by-sa` overrides it for one
   build), and a crop of a CC BY-SA photo is shared under CC BY-SA. Sounds take `SOUND_LICENSE_TIERS`, the rules of step 3.
6. **Download.** The `large` (1024 px) rendition of the first `--limit` cleared candidates, at most two per observation
   (only one photo of an observation is chosen, and a burst of frames from one prolific observer would otherwise fill
   the shortlist), from the Open Data bucket into `cache/photos/`, `--workers` (default 8) at a time, and the
   `original` of the chosen ones.
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
10. **Pack art.** One painting per species in the set's edition theme, painted from its best-lit photo (below).
11. **Fact sheet and lore.** Each species' sourced facts, and lore written from them by a Claude model (below).
12. **Write.** `pack.sqlite` (tables `pack`, `species`, `photo`, `sound`, `lookalike`, and since schema 4 `set_definition` with the
   pinned `set.json`, the joined `stats`, `threatened` and `family` (see "Stats and type lines"), `pack_art` with each approved painting's file, source photo ids and workflow versions, `fact` with each species' fact sheet and `lore` with its approved lore and tagline (see "Fact sheet and lore")), `lens/<photo>.jpg` (552 × 368 px, tight card-width crop),
   `phone/<photo>.jpg` (looser crop, 1200 px max), `sounds/<id>.m4a`, `art/<species>.avif` (864 × 1152, 3:4), `LICENSE` with every photo, sound, art and text credit and link, `report.json`
   with counts, chosen ids, description sources, chosen and rejected sounds, each species' art review, the photo, description, sound, stats and art gaps and the art and lore not yet approved (`unreviewed.art`, `unreviewed.lore`), and optionally a zip (`writer.py`).

The Swift `Pack` module (`SpeciesPack`) reads the output; `SCHEMA_VERSION` in `writer.py` and
`SpeciesPack.schemaVersion` move together.

## Sets

A pack's species make a set the birder collects toward (issue #54). The `set` section of `pack.json` names the edition
(`name`, shown on cards that are not Legendary, and `theme`, what pack art is painted in) and the region boundary as
named parts, each one of `census_county` (the five-digit FIPS code; US Census Bureau TIGERweb, public domain),
`nps_park` (the NPS unit code; NPS Land Resources Division boundaries, public domain) or `polygon` (a hand-drawn
GeoJSON file beside `pack.json`, for a region that is neither, such as the Coachella Valley in `us-ca-desert/regions/`).

`uv run packbuilder set packs/<id>` fetches the boundaries into `cache/boundaries/`, simplifies each part with
Douglas–Peucker (0.5 km by default, `--tolerance-km`), drops islets and holes under 1 km², orders the species by the
IOC World Bird List (CC BY 3.0; the pinned version and its SHA-256 in `sets.py`, fetched into `cache/taxonomy/`, with
`TAXONOMY_FIXES` for the BirdNET names IOC spells differently; an unmapped species fails), and writes `set.json`
beside the definition (committed). Rerun it after changing a pack's species, names, edition or boundary: `build` and
`index` refuse a `set.json` that no longer matches its definition. The parts stay apart in `set.json` because the
phone gives a sighting to the smallest containing part (Anza-Borrego beats San Diego County).

`uv run packbuilder index --out <file>` writes the pack index from `packs/manifest.json` with each pack's `set.json`;
`scripts/publish-pack-index.sh` runs it before uploading.

## Stats and type lines

Every card carries real natural-history numbers (issue #55), joined before any download so an unmapped species fails
the build at once (`stats.py`). Three CC BY 4.0 workbooks, pinned by SHA-256 in `stats.py`, are fetched once into
`cache/datasets/`: AVONET (mass, habitat, migration, trophic niche as the diet, primary lifestyle), BIRDBASE (nest
type, clutch range, flightlessness, the IUCN category, the order and family) and the avian wingspan database (a
measured wingspan, else the predicted midpoint, flagged so the card shows "≈"). AVONET's eBird/Clements sheet is the
anchor: a BirdNET name gives the Avibase ID, which leads to the wingspan database directly or through AVONET's
BirdLife–eBird crosswalk (several BirdLife species: the namesake). BIRDBASE has no Avibase ID and is matched by its
eBird/Clements v2024b name. A flightless species has no wingspan, and nor does a species the wingspan database lacks
(it has no Galliformes); a stat a dataset lacks is left off.

Two committed files steer it, shared by every pack:

- `stats/fixes.json`: BirdNET name → the dataset's name for renames, splits and lumps since a dataset's taxonomy
  (`avonet`, `wingspan`, `birdbase`, each with its reason); `known_gaps`, the species a build may leave without stats
  (listed in `report.json` as `gaps.stats`); and `threatened`, the hand list of species protected where the packs
  are though the IUCN rates them lower (US Endangered Species Act listings). IUCN Vulnerable, Endangered and
  Critically Endangered are threatened anyway.
- `stats/type-lines.json`: a group word per order and a family word per family ("Songbird — Finch"), a family's own
  group where it differs (gulls are Seabirds) and a genus's own word (an Eagle among the Hawks). A family it lacks
  fails the build.

## Pack art

Every card shows painted art the moment it exists (issue #57). After the photos are chosen, `pack_art.py` paints each
species once per pack with the committed `pack-art` workflow and prompts (`art/`), in the set's edition theme
(`set.edition.theme` in `pack.json`):

- **The reference** is the species' best-lit photo among the pack's chosen photos (`lighting`: the light on the
  middle of the bird, less for a bird darker than the frame around it or for blown highlights), not the lens score's
  first, which favours a dark background; the colour fit makes a dim reference a dim bird. `overrides.json` pins one
  with `{"art": {"reference": <photo id>}}`. A species with no photo is painted from text alone (`pack-art-text`,
  which names it) and must be looked at closely.
- **The setting** (prompts v10) is what the reference shows the bird on, set per species in `overrides.json` as
  `{"art": {"setting": ...}}`: `perch` (any perch off the ground, painted as a branch), `trunk`, `flight`, `ground`,
  `rock`, `shore`, `wade` or `water`; without one the model chooses. The bird's length (its description's, or
  `art.length_cm`) sizes the branch and the leaves beside it, so a finch sits on a twig and a hawk on a limb.
- **The painting** isolates the reference bird on white, paints from it and keeps it only through the fidelity gate
  (`painting.py`, `fidelity.py`): an unfaithful painting is painted again with the next seed, three times at most,
  and the closest is kept and flagged NOT FAITHFUL.
- **The lock**, `packs/<id>/art.lock.json` (committed), pins each species' source photo, workflow, isolation and
  prompts versions, theme, seeds, the painting's SHA-256 and its review. Paintings live in `cache/art/paintings/`
  under their SHA-256 (isolated birds in `cache/art/isolated/`). A rebuild whose lock is warm paints nothing; changed
  inputs paint again and go back to review; a painting gone from the cache is repainted from its locked seeds, which
  give the same picture.
- **The review.** The build draws contact sheets into `build/pack-art/<id>/` (`sheet-NN.jpg`: each reference crop
  beside its painting with its state and fidelity; `overview.jpg`: every painting). Record the verdicts, then rebuild:

  ```sh
  uv run packbuilder art-review packs/us-ca-la --approve-all --reject "House Finch" --why "invented a crest"
  uv run packbuilder art-review packs/us-ca-la --gap "Bushtit" --why "three rounds, never the right bird"
  ```

  Only `approved` art goes into the pack. A rejected painting is painted again by the next build with new seeds
  (its rejected seeds and the reason stay in the lock); a gap gets none and is listed under `gaps.art` in
  `report.json`, and its cards show another pack's painting of the species, else the reference photo. `--approve-all`
  approves only faithful paintings from a photo: one from text, or one flagged NOT FAITHFUL, needs `--approve` by
  name. Painting the Los Angeles pack from scratch takes about 3.3 hours from the Mac
  (about 75 s a species); run it under `caffeinate -i`.

### Set covers

Each regional set has one illustrated landscape cover (issue #114), for the Atlas tiles and the Listen tab's ready
state. `covers.py` paints it on comfybox from text alone with the `set-cover` workflow and `art/cover-prompts.json`, in
the set's edition theme (`set.json`'s `edition.theme`): a landscape with no bird in focus, no text, no map and no
location marker. FLUX.3 paints a 1664 × 944 canvas, cropped to the middle 1536 × 864 past the ragged paper edge its
watercolours often end in.

- **A round** is four candidates from consecutive seeds, about 5 s each. `packbuilder build` paints what the lock lacks
  (skipped by `--no-art` or `--no-cover`); `packbuilder cover` does the same without building the pack.
- **The lock**, `packs/<id>/cover.lock.json` (committed), pins the round: the theme, workflow, prompts version and
  model, each candidate's seed and SHA-256 (the painting is `cache/covers/<sha256>.png`), and the review. A warm lock
  paints nothing; a changed theme or template paints a new round for review; a cover gone from the cache is
  repainted from its seed.
- **The review.** The sheet is `build/pack-art/<id>/cover.jpg`, beside the pack art's: the candidates numbered, the
  Atlas (2.4:1) and Listen (3:2) crops drawn faintly. Choose one, or turn the round down:

  ```sh
  uv run packbuilder cover packs/us-ca-sd                         # paint the round (or repaint missing candidates)
  uv run packbuilder cover-review packs/us-ca-sd --approve 2      # writes packs/us-ca-sd/cover-thumbnail.jpg
  uv run packbuilder cover-review packs/us-ca-sd --reject --why "too much sky"   # the next run paints four more
  ```

  Only the approved cover ships: `cover.avif` in the pack (a `cover` row with its workflow, seed and model, and a
  "Set cover" credit in the LICENSE, labelled as an AI illustration), and in the pack index, where
  `packbuilder index` carries the committed `cover-thumbnail.jpg` (480 × 270 JPEG, base64) and refuses one that isn't
  the approved cover's. Commit the lock and the thumbnail together; then rebuild and pin the pack and publish the
  index, so the pack and the index show the same cover.
- **In the app.** Every approved cover also ships in the app itself, so the Listen painting works before a set's pack is
  on the phone and offline (issue #150): `uv run packbuilder bundle-covers` writes them at full size as JPEG, about 3 MB
  together, with each `set.json` (so a phone that has never read the index knows which set it's in) and `covers.json`, into
  the `Pack` target's `Covers` folder, which is committed. Run it after approving a
  cover: `test_covers` fails while a bundled cover isn't the one its lock approved. It reads the cover cache, so the
  chosen paintings have to be there (`packbuilder cover` paints a missing one from its seed).

## Patches

Since design guide 2.0 (#131) the collectible is an embroidered patch, one per species per edition, and the patch is the only painting in the app; the app no longer shows the pack art above (#137), and only the packs not yet rebuilt with patches (#58) still carry it. `packbuilder patches` (issue #133) paints them; `packbuilder build` runs the same step in place of the pack art for a pack whose edition has a patch in `art/patch-prompts.json` and whose `art.lock.json` names its reference birds (Los Angeles, for now; the other packs keep pack art until their references are isolated, #58).

```sh
cd packbuilder
uv run packbuilder patches packs/us-ca-la            # paint what patch.lock.json lacks, then the contact sheets
uv run packbuilder patches packs/us-ca-la --only haemorhous-mexicanus --only sayornis-nigricans   # a trial
uv run packbuilder patch-review packs/us-ca-la --approve-all
uv run packbuilder patch-review packs/us-ca-la --reject "Black Phoebe" --why "the face came out white"
uv run packbuilder patch-review packs/us-ca-la --gap "Black Phoebe" --why "thread can't hold it"
```

- **What a patch is painted from**: the species' reference bird, isolated on white, that its pack art was painted from (the photo and isolation seed in `art.lock.json`, the bird in `<cache>/art/isolated/`). FLUX.3 Image Klein paints it with the `patch-art` workflow and the `patch-prompts.json` template: a merit-badge-style patch of the set's edition (its shape, the merrowed cord's colour, the twill and a few stitched shapes of its motif), lying flat on white card under even light, so the app does the lighting. The bird stands where it lives, from its `art.setting` in `overrides.json`: ducks on water, shorebirds on sand, woodpeckers on bark (the maintainer's review of the Los Angeles patches; version 1 put every bird on a branch). No prompt names the species.
- **Pinning a patch** (`art.patch` in `overrides.json`): `reference` paints from another of the pack's photos, a well-lit adult (Heermann's Gull's pack art reference is a brown immature), isolated from its original in `<cache>/photos/original/` when the cache lacks it; `box` gives the bird's place in that photo (x0, y0, x1, y1 as fractions) when the detector can't see it, as with a poorwill on bark mulch; `markings` states plumage facts the thread keeps getting wrong ("The head and neck are solid black, the bill is white and the eye is red"), describing the bird and never naming it. A dark bird (median L* of the isolated bird under `dark_lightness`, 22) gets the black-thread clause; for every bird, the clause blackened a House Finch's blue-grey belly.
- **Cut and measured**: the patch is cut from its card (`cut_from_card`: the card is what reaches the edge and stays card-coloured; the soft shadow is dropped and the convex hull of the rest is the patch, since every edition's shape is convex; BiRefNet takes the bird as often as the patch). The bird inside it is found by BiRefNet on the patch's interior with everything outside the cord filled with the twill, and measured against the reference (ΔE and IoU, `packbuilder.fidelity`). The measure only ranks and flags: thread colour moved a good House Finch about as far as a failed Black Phoebe, so there are no automatic retries and no colour fit (the interior mask can take in the leaves beside the bird).
- **Reviewed**: every patch is reviewed on the contact sheets in `build/pack-art/<pack id>/patches/` (the reference bird beside its patch, with its state, measure and whether the dark clause was used). `patch.lock.json` pins each: the reference photo and isolation seed, the workflow and prompts versions, the edition's patch, the seed, the cut patch's SHA-256 (`<cache>/art/patches/<sha256>.png`, with `-raw.png` the painting as it came) and the review, as for pack art. A rejected patch is painted again with the next seed by the next run, with the current templates; a new prompts version alone leaves reviewed patches alone.
- **In the pack (schema 5)**: an approved patch is written, without the pale rim of card its cut can leave along one side (`trim_rim`: that only changes the alpha, so the lock stands), as `patch/<species id>.avif`, its colour on transparency at 720 px on its longest side, and `patch/<species id>-layers.avif` at half size, its height map (thread relief plus the raised cord) in red, the cord's mask (25 px deep at 720 px) in green and the stitch order (one thread colour at a time, the largest first, the cord last) in blue (`patch_art.layers`), with a `patch` row: the files, its size, the bare twill's colour, the stitch layers' starts and its source photo. About 120 KB a species; a build with patches writes no pack art, which keeps Los Angeles inside its 200 MB budget.
- **Running it**: about 20 s a patch on the box itself; from the Mac it waits on the tailnet (about a minute a patch on 2026-11-03). To run it on the box, copy `packbuilder/src`, `art/`, the pack's definition and locks and the isolated birds to a checkout-shaped folder there and run `PYTHONPATH=packbuilder/src ~/comfyui-flux3/.venv/bin/python -m packbuilder.cli patches packbuilder/packs/<id> --comfy http://127.0.0.1:8189 --cache packbuilder/cache`, then copy `patch.lock.json`, `<cache>/art/patches/` and the sheets back.

## Rarity calibration

`uv run packbuilder calibrate-rarity --version <n>` reads the BirdNET geomodel (from the repo's `models/`) for every
species of every definition under `packs/`, over a 6 × 6 grid across each pack's bounding box and all 48 weeks, and
writes the label thresholds the app ships to `BirdJournal/BirdJournalKit/Sources/Identification/RarityCalibration.json`
(`rarity.py`; ADR-0006, issue #52). It takes a few seconds. Run it again only for a new calibration, with the next
version: cards keep the version they were labelled under.

## Fact sheet and lore

Lore and captions state only true facts (issue #56). `factsheet.py` gives each species a **fact sheet**: its stats
told as short sentences, each credited to the dataset it came from, then up to eight sentences of its Wikipedia
article at the pinned revision that stand alone, taken across the kinds of section (the lead, behaviour and diet,
breeding, voice, people, names, range, status, appearance) so one long section never fills it. The pack ships it in
`fact`; the phone's captions read it.

`lore.py` then has Claude (`claude-opus-5-5` by default, `--lore-model`) write 50 to 80 words of myth-voiced lore and a
tagline of 12 words or fewer from the sheet alone, every sentence citing the fact ids it rests on. A draft that cites
nothing, cites a fact the sheet lacks or misses the counts is sent back with what was wrong, three times at most.

- **The key** is read from `BIRDJOURNAL_ANTHROPIC_API_KEY` in the shell profile, else the login Keychain item
  `birdjournal-anthropic-api-key` (never the repository, and not `ANTHROPIC_API_KEY`, which would switch Claude Code
  itself to API billing). It is needed only when lore is missing from the lock; the build stops with a clear message
  without it, or at once when the API refuses it. `--no-lore` skips the step.
- **Lore alone**: `uv run packbuilder lore packs/us-ca-la` writes the fact sheets and the missing lore from the cache
  without building the pack (`--only "Black Phoebe"` for a trial).
- **Pacing**: one request at a time, `--lore-interval` seconds apart (default 2).
- **The lock**, `packs/<id>/lore.lock.json` (committed), pins each species' fact sheet as the lore used it, the
  sentences with their citations, the tagline, the model, the prompt version and the review. A warm lock makes no
  request, and the pack ships the locked facts, so lore and fact sheet never disagree; a sheet that moved since (a
  new Wikipedia revision) is logged and kept as locked. A hand-edited entry that cites a fact its sheet lacks stops
  the build.
- **Only on request**: `--regenerate-lore "House Finch"` (repeat, or `all`) writes lore again; so does a rejection.
- **The review.** Every build writes `build/lore/<id>/review.md` (species, state, tagline, lore and the facts each
  sentence cites). Record the verdicts, then rebuild:

  ```sh
  uv run packbuilder lore-review packs/us-ca-la --approve-all --reject "House Finch" --why "too grand; keep to the seeds"
  ```

  Only `approved` lore goes into the pack; a rejected species is written again by the next build with the reason in
  the prompt. The lore is CC BY-SA 4.0 as an adaptation of the Wikipedia text, credited in the LICENSE with the
  article revisions.
- **Story titles** (issue #113): each species' lore has a title of 2 to 5 words that heads it on the card front
  ("The Waterside Mason"), citing the facts it rests on. It never names the bird (its common or scientific name, the
  word for its kind, the person it is named for, a hyphenated marking such as "red-tailed"), holds no number, and a
  set's titles may not begin with the same two words or end on the same word past 15 % of the set. New lore is
  written with its title; lore locked before titles gets one from a title-only request (the locked lore and tagline
  in the prompt), and the lore, its tagline and their review stay byte for byte. The title has its own review:

  ```sh
  uv run packbuilder lore packs/us-ca-la --only "Black Phoebe"          # a trial: one title-only request
  uv run packbuilder lore packs/us-ca-la --lore-budget 6                # every title the lock lacks
  uv run packbuilder lore-review packs/us-ca-la --approve-all-titles --reject-title "House Finch" --why "say what it eats"
  ```

  A rejected title is written again alone by the next run, with the reason; `--regenerate-title <species>|all` asks
  for another, and `--no-titles` makes no title-only request. Only an approved title on approved lore ships (the
  nullable `lore.title` column); the rest is listed under `unreviewed.titles` in `report.json`, and the lore ships
  without one.

## Layout

| Path | What |
| --- | --- |
| `src/packbuilder/` | The package; `cli.py` is the `packbuilder` command, `pipeline.py` the build order. |
| `src/packbuilder/art.py`, `comfy.py`, `fidelity.py`, `painting.py`, `contact_sheets.py`, `bakeoff.py` | Card art (#49): prompts and workflows from the repo's `art/`, the 3:4 card crop and the telephoto crop of a glasses photo, a ComfyUI client for comfybox, the painted bird's fidelity to its photo and the colour fit, painting through the fidelity gate, contact sheets, and the art model bake-off (`python -m packbuilder.bakeoff`; see `art/README.md`). |
| `src/packbuilder/pack_art.py` | The pack-art step (#57): the reference by lighting, the lock, the review and the contact sheets. |
| `src/packbuilder/factsheet.py`, `lore.py` | The fact sheet and the lore step (#56): the Anthropic client, the citation checks, the lock, the review and its file. |
| `packs/<id>/pack.json`, `overrides.json`, `wikipedia.lock.json`, `sounds.lock.json`, `art.lock.json`, `lore.lock.json` | Pack definitions, manual overrides, the Wikipedia revisions the text came from, the recordings the sounds came from, the pack art's sources and review, and the lore with its facts and review (committed). |
| `tests/` | pytest over synthetic fixtures: license filter, scoring order, selection and overrides, crops, Open Data join, Wikipedia text rules, the pipeline through fakes, writer output, the committed definitions against the BirdNET label file, the art prompts, workflows and crops, fidelity and the colour fit, and the ComfyUI client and the bake-off's retries against a stub server. The detector test runs only when the model and some photos are cached; the label test only when the models are downloaded. |
| `packs/<id>/set.json`, `packs/<id>/regions/*.geojson` | The pinned set definition `packbuilder set` builds, and hand-drawn boundary parts (committed). |
| `stats/fixes.json`, `stats/type-lines.json` | The stats join's name fixes, known gaps and threatened hand list, and the type-line words (committed). |
| `tests/` | pytest over synthetic fixtures: license filter, scoring order, selection and overrides, crops, Open Data join, Wikipedia text rules, the pipeline through fakes, writer output, and the committed definitions against the BirdNET label file. The detector test runs only when the model and some photos are cached; the label test only when the models are downloaded. |
| `cache/wikipedia/` | Fetched article pages (gitignored with the rest of `cache/`). |
| `cache/` | Downloads (gitignored): `models/`, `api/`, `wikipedia/`, `photos/large/`, `photos/original/`, `sounds/` (xeno-canto and iNaturalist answers and files, and the encoded clips), `boundaries/` and `taxonomy/` (the set's sources), `datasets/` (the stats workbooks), `art/` (the paintings by SHA-256 and the isolated reference birds). |

Output goes to the repo's `packs/<id>/`, which is not committed: the built pack is published as a GitHub Release asset
and fetched by `scripts/download-pack.sh` (see `packs/README.md`).
