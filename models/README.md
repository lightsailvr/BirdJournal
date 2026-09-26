# models/

Pinned BirdNET files for the identification engine. Nothing here is committed except
`manifest.json` and this README; run the download script to populate the directory:

```sh
scripts/download-models.sh
```

The script downloads every entry in `manifest.json` into this directory and verifies its SHA-256.
Existing files whose checksum already matches are skipped, so re-running is cheap.

| File | What | Source | License |
| --- | --- | --- | --- |
| `BirdNET+_V3.0-preview3.1_Global_11K_FP16_pruned.onnx` | Acoustic model (11,560 classes, 32 kHz input) | Zenodo record 20703646 | CC BY-SA 4.0 |
| `BirdNET+_V3.0-preview3.1_Global_11K_Labels.csv` | Acoustic model labels | Zenodo record 20703646 | CC BY-SA 4.0 |
| `TERMS_OF_USE.txt` | BirdNET+ developer preview terms | Zenodo record 20703646 | CC BY-SA 4.0 |
| `BirdNET+_Geomodel_V3.0.4_Global_14K_FP16.onnx` | Geo prior (lat, lon, week) | birdnet-team/geomodel v3.0.4 | Apache-2.0 |
| `BirdNET+_Geomodel_V3.0.4_Global_14K_Labels.txt` | Geomodel labels | birdnet-team/geomodel v3.0.4 | Apache-2.0 |
| `LICENSE-MODELS.md`, `ACCEPTABLE_USE.md` | Geomodel license and acceptable use | birdnet-team/geomodel v3.0.4 | Apache-2.0 |

Attribution: "Powered by BirdNET". See DECISIONS.md, "Audio and identification", for why these exact
versions are pinned and how the engine sits behind a protocol so they can be swapped.
