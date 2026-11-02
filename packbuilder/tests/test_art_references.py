"""The art worker's reference birds (issue #68): approved species' isolated birds from the cache, with their lengths."""

import json
import sqlite3
from pathlib import Path

from PIL import Image

from packbuilder.art_references import export, isolated_bird
from packbuilder.pack_art import ArtLock


def _pack(path: Path, rows: list[tuple[str, str, str | None]]) -> Path:
    db = path / "pack.sqlite"
    with sqlite3.connect(db) as connection:
        connection.execute("CREATE TABLE species (id TEXT PRIMARY KEY, scientific_name TEXT, size TEXT)")
        connection.executemany("INSERT INTO species VALUES (?, ?, ?)", rows)
    return db


def _bird(cache: Path, name: str, won_with: int, colour: tuple[int, int, int] = (200, 40, 40)) -> None:
    isolated = cache / "isolated"
    isolated.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (32, 48), colour).save(isolated / f"{name}.png")
    (isolated / f"{name}.json").write_text(json.dumps({"seed": won_with, "attempts": 1}))


def _entry(photo: int | None, isolate_seed: int | None, review: str = "approved") -> dict:
    return {
        "common_name": "x", "photos": [photo] if photo else [], "workflow": "pack-art@3",
        "isolate": "bird-isolate@1" if photo else None, "isolate_seed": isolate_seed, "review": review,
    }


def test_approved_species_are_exported_with_their_birds_and_lengths(tmp_path: Path) -> None:
    db = _pack(tmp_path, [
        ("haemorhous-mexicanus", "Haemorhous mexicanus", "13–15 cm"),
        ("buteo-jamaicensis", "Buteo jamaicensis", None),
        ("psaltriparus-minimus", "Psaltriparus minimus", "11 cm"),
        ("sayornis-nigricans", "Sayornis nigricans", "16 cm"),
        ("calypte-anna", "Calypte anna", "10 cm"),
    ])
    cache = tmp_path / "cache" / "art"
    _bird(cache, "111-s49-bird-isolate@1-iabc", won_with=49)
    # A retry: the cache keeps the starting seed in the name, the lock and the JSON the winning one.
    _bird(cache, "222-s49-bird-isolate@1-iabc", won_with=50, colour=(90, 60, 30))
    _bird(cache, "333-s49-bird-isolate@1-iabc", won_with=49)
    lock = ArtLock(tmp_path / "art.lock.json", {
        "haemorhous-mexicanus": _entry(111, 49),
        "buteo-jamaicensis": _entry(222, 50),
        # From text: there is no reference bird to paint into a scene.
        "psaltriparus-minimus": _entry(None, None),
        # Not approved yet: its reference wasn't looked at.
        "sayornis-nigricans": _entry(333, 49, review="pending"),
        # Approved, but its bird isn't in this cache.
        "calypte-anna": _entry(444, 49),
    })
    overrides = {"Buteo jamaicensis": {"art": {"length_cm": 52}}}
    out = tmp_path / "references"

    references = export("us-ca-la", lock, overrides, db, cache, out)

    assert references["pack"] == "us-ca-la"
    assert references["species"] == {
        "Haemorhous mexicanus": {"file": "haemorhous-mexicanus.png", "length_cm": 14.0, "photo_id": 111, "species_id": "haemorhous-mexicanus"},
        "Buteo jamaicensis": {"file": "buteo-jamaicensis.png", "length_cm": 52.0, "photo_id": 222, "species_id": "buteo-jamaicensis"},
    }
    assert references["no_reference"] == ["Psaltriparus minimus"]
    assert references["missing"] == ["Calypte anna"]
    assert json.loads((out / "references.json").read_text()) == references
    assert Image.open(out / "buteo-jamaicensis.png").getpixel((0, 0)) == (90, 60, 30)
    assert sorted(path.name for path in out.iterdir()) == ["buteo-jamaicensis.png", "haemorhous-mexicanus.png", "references.json"]


def test_a_bird_isolated_with_another_seed_is_not_taken(tmp_path: Path) -> None:
    cache = tmp_path / "art"
    _bird(cache, "111-s49-bird-isolate@1-iabc", won_with=49)
    assert isolated_bird(cache, _entry(111, 51)) is None
    assert isolated_bird(cache, _entry(111, 49)) == cache / "isolated" / "111-s49-bird-isolate@1-iabc.png"


def test_the_export_replaces_the_folder(tmp_path: Path) -> None:
    db = _pack(tmp_path, [("haemorhous-mexicanus", "Haemorhous mexicanus", "14 cm")])
    out = tmp_path / "references"
    out.mkdir()
    (out / "stale.png").write_bytes(b"old")
    export("us-ca-la", ArtLock(tmp_path / "lock.json", {}), {}, db, tmp_path / "art", out)
    assert sorted(path.name for path in out.iterdir()) == ["references.json"]
