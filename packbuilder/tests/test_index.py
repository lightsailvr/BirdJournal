"""The pack index (issue #54): every entry carries its pack's set definition from the committed set.json."""

import json
from pathlib import Path

import pytest

from packbuilder.index import pack_index
from packbuilder.sets import load_set

REPO = Path(__file__).resolve().parents[2]
PACKS = REPO / "packbuilder" / "packs"
MANIFEST = json.loads((REPO / "packs" / "manifest.json").read_text())


def test_every_entry_carries_its_set_and_schema():
    index = pack_index(MANIFEST, PACKS, "lightsailvr/BirdJournal")
    assert [entry["id"] for entry in index["packs"]] == [pack["id"] for pack in MANIFEST["packs"]]
    for entry in index["packs"]:
        assert entry["set"] == load_set(PACKS / entry["id"] / "set.json")
        assert entry["set"]["id"] == entry["id"]
        assert entry["schemaVersion"] in (3, 4)
        assert entry["url"].startswith("https://github.com/lightsailvr/BirdJournal/releases/download/pack-")


def test_the_bundled_pack_is_published_at_schema_4():
    bundled = next(pack for pack in MANIFEST["packs"] if pack.get("bundled"))
    assert bundled["schema_version"] == 4


def test_a_stale_set_is_never_published(tmp_path):
    definitions = tmp_path / "packs"
    (definitions / "us-ca-la").mkdir(parents=True)
    pack = json.loads((PACKS / "us-ca-la" / "pack.json").read_text())
    pack["set"]["edition"]["name"] = "Garden edition"
    (definitions / "us-ca-la" / "pack.json").write_text(json.dumps(pack))
    (definitions / "us-ca-la" / "set.json").write_text((PACKS / "us-ca-la" / "set.json").read_text())
    manifest = {"packs": [p for p in MANIFEST["packs"] if p["id"] == "us-ca-la"]}
    with pytest.raises(ValueError, match="out of date"):
        pack_index(manifest, definitions, "lightsailvr/BirdJournal")
