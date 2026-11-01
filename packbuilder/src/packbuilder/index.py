"""The pack index the phone reads (issues #13, #54): every pack in `packs/manifest.json` as the Swift Pack module's
`PackIndex` decodes it. `scripts/publish-pack-index.sh` writes it with `packbuilder index` and uploads it as
`index.json` on the rolling `packs` release.

Each entry carries its pack's set definition from the committed `set.json` beside the pack definition, so a phone
knows every set (boundary, species in taxonomic order, edition) before it downloads the pack. An app build that
cannot open the entry's schema still lists the pack without offering it (`PackDescriptor.isSupported`, #41) and
ignores keys it doesn't know.
"""

from __future__ import annotations

import json
from pathlib import Path

from packbuilder.definition import PackDefinition
from packbuilder.sets import check_set, load_set


def pack_index(manifest: dict, definitions_dir: Path, repo: str) -> dict:
    packs = []
    for pack in manifest["packs"]:
        entry = {
            "id": pack["id"], "name": pack["name"], "version": pack["version"],
            "url": f"https://github.com/{repo}/releases/download/{pack['release']}/{pack['asset']}",
            "sha256": pack["sha256"], "byteCount": pack["bytes"],
        }
        # Counts and the region, when the manifest has them (issue #28): what the packs screen shows before a download.
        for key, field in (("species", "speciesCount"), ("photos", "photoCount"), ("region", "region"), ("sounds", "soundCount"), ("schema_version", "schemaVersion")):
            if key in pack:
                entry[field] = pack[key]
        # Issue #54: the set, checked against its definition so a stale set.json is never published.
        folder = Path(definitions_dir) / pack["id"]
        card_set = load_set(folder / "set.json")
        check_set(card_set, PackDefinition.load(folder / "pack.json"))
        entry["set"] = card_set
        packs.append(entry)
    return {"packs": packs}


def write_index(manifest_path: Path, definitions_dir: Path, out: Path, repo: str) -> dict:
    index = pack_index(json.loads(Path(manifest_path).read_text()), definitions_dir, repo)
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    # Compact: the boundaries would be one number per line, and the phone fetches the index on every refresh.
    Path(out).write_text(json.dumps(index, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    return index
