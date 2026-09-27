import json
import sqlite3
import zipfile

from PIL import Image

from packbuilder.definition import PackDefinition, SpeciesEntry, BoundingBox
from packbuilder.geometry import Box
from packbuilder.scoring import CropScore
from packbuilder.selection import ScoredPhoto
from packbuilder.writer import ChosenPhoto, SpeciesResult, write_pack
from tests.conftest import make_candidate, synthetic_photo


def definition():
    return PackDefinition(
        id="test-pack",
        name="Test Pack",
        region="Testland",
        version=1,
        place_id=1,
        bounding_box=BoundingBox(south=0, west=0, north=1, east=1),
        species=[
            SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url="https://en.wikipedia.org/wiki/Black_phoebe"),
            SpeciesEntry(scientific_name="Calypte anna", common_name="Anna's Hummingbird", birdnet_label="Calypte anna", inat_taxon_id=6317, wikipedia_url=None),
        ],
    )


def result_for(entry, photo_ids, tmp_path):
    photos = []
    for offset, photo_id in enumerate(photo_ids):
        path = tmp_path / f"src-{photo_id}.jpg"
        synthetic_photo(size=(1600, 1200)).save(path)
        candidate = make_candidate(photo_id=photo_id, observation_id=photo_id * 10, license="CC BY-NC" if offset else "CC0")
        score = CropScore(0.5, 0.5, 0.5, 0.5 - offset * 0.1)
        photos.append(ChosenPhoto(scored=ScoredPhoto(candidate=candidate, box=Box(0.3, 0.3, 0.7, 0.7), score=score), original=path))
    return SpeciesResult(entry=entry, photos=photos, gap=len(photo_ids) < 3)


def test_pack_output(tmp_path):
    pack = definition()
    results = [result_for(pack.species[0], [1, 2, 3], tmp_path), result_for(pack.species[1], [4, 5], tmp_path)]
    out = tmp_path / "out"

    written = write_pack(pack, results, out, built_at="2026-09-27T00:00:00Z", archive_path=tmp_path / "dist" / "test-pack.zip")

    db = sqlite3.connect(written.database)
    db.row_factory = sqlite3.Row
    species = db.execute("SELECT * FROM species ORDER BY sort_order").fetchall()
    assert [s["id"] for s in species] == ["sayornis-nigricans", "calypte-anna"]
    assert species[0]["common_name"] == "Black Phoebe"
    assert species[0]["inat_taxon_id"] == 17013

    photos = db.execute("SELECT * FROM photo ORDER BY species_id, rank").fetchall()
    assert len(photos) == 5
    for photo in photos:
        assert photo["observer"] and photo["license"] in {"CC0", "CC BY", "CC BY-NC"} and photo["source_url"].startswith("https://www.inaturalist.org/observations/")
        assert (out / photo["file_lens"]).exists() and (out / photo["file_phone"]).exists()
        assert Image.open(out / photo["file_lens"]).size == (552, 368)
        assert max(Image.open(out / photo["file_phone"]).size) <= 1200
    first = [p for p in photos if p["species_id"] == "sayornis-nigricans"][0]
    assert first["rank"] == 0 and first["credit_line"] == "Jane Birder, no rights reserved (CC0)"

    info = db.execute("SELECT * FROM pack").fetchone()
    assert info["id"] == "test-pack" and info["version"] == 1 and info["built_at"] == "2026-09-27T00:00:00Z"
    assert info["schema_version"] == 1

    license_text = (out / "LICENSE").read_text()
    for photo in photos:
        assert photo["credit_line"] in license_text and photo["source_url"] in license_text
    assert "Anna's Hummingbird" in license_text

    report = json.loads((out / "report.json").read_text())
    assert report["species"]["calypte-anna"]["gap"] is True
    assert report["species"]["sayornis-nigricans"]["photos"] == 3

    with zipfile.ZipFile(written.archive) as archive:
        names = set(archive.namelist())
    assert "pack.sqlite" in names and "LICENSE" in names and "lens/1.jpg" in names
    assert db.execute("SELECT COUNT(*) FROM lookalike").fetchone()[0] == 0, "lookalikes are empty until #12"
