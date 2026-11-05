# fixtures/

Labeled recordings for the identification engine tests (issue #5, spec "Engine seam"). Only
`clips.json` and this README are committed; the audio lives in `fixtures/clips/`, which is gitignored.

```sh
scripts/download-clips.sh    # fetches every entry in clips.json that has a url, verifying its SHA-256
```

`IdentificationEngineTests` runs each entry whose file is present and skips the rest, so a checkout
without clips still tests green on the committed synthetic fixtures.

## Adding a recording

Add an entry to `clips.json`:

| Field | Meaning |
| --- | --- |
| `file` | Path relative to `fixtures/`, normally `clips/<name>.wav`. Any format `AVAudioFile` reads; mono or stereo, any rate. |
| `url`, `sha256` | Optional. Where the download script fetches it and the checksum it verifies. Omit for local-only recordings. |
| `latitude`, `longitude`, `week` | Where and when it was recorded. `week` is BirdNET's 48-week year (four per month). |
| `expected` | Scientific names (as in the BirdNET+ label file) that must rank in the top three of the final stack. |
| `absent` | Optional. Scientific names that must never be admitted, e.g. species the geomodel rules out at that location. |
| `withinSeconds` | Optional. Seconds into the clip by which every `expected` species must be in the stack (spec "Engine seam": top three within a time budget). |
| `note` | Free text: source, license, what is audible. |

Labeled recordings: name the file after the dominant species and date (`house-finch-2026-10-03.wav`),
record where it was made, and keep clips under a few minutes so the suite stays quick.

## The face-blur fixture (issues #68 and #66)

`BirdJournal/BirdJournalTests/Fixtures/face-portrait.jpg` is NASA's official portrait of astronaut Sally K. Ride,
S84-37256 (Johnson Space Center, June 1984), from https://images.nasa.gov/details-S84-37256 (the `~medium` asset,
scaled to 576 × 720). A work of the US government, in the public domain; used only to check that the phone finds and
blurs a face before a shared card's photo leaves it (`SharedPhotoTests`). NASA's media guidelines ask that its imagery not
imply endorsement; it implies none.
