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
| `note` | Free text: source, license, what is audible. |

Labeled recordings: name the file after the dominant species and date (`house-finch-2026-10-03.wav`),
record where it was made, and keep clips under a few minutes so the suite stays quick.
