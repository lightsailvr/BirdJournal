import json
import sqlite3
import zipfile

from PIL import Image

from packbuilder.definition import PackDefinition, SpeciesEntry, BoundingBox
from packbuilder.descriptions import Description
from packbuilder.geometry import Box
from packbuilder.scoring import CropScore
from packbuilder.selection import ScoredPhoto
from packbuilder.sounds import ChosenSound, Clip, SoundCandidate, SoundResult
from packbuilder.writer import ChosenPhoto, SpeciesResult, write_pack
from tests.conftest import make_candidate, synthetic_photo


def definition():
    return PackDefinition(
        id="test-pack",
        name="Test Pack",
        region="Testland",
        version=1,
        place_ids=(1,),
        bounding_box=BoundingBox(south=0, west=0, north=1, east=1),
        species=[
            SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013, wikipedia_url="https://en.wikipedia.org/wiki/Black_phoebe"),
            SpeciesEntry(scientific_name="Calypte anna", common_name="Anna's Hummingbird", birdnet_label="Calypte anna", inat_taxon_id=6317, wikipedia_url=None),
        ],
    )


def result_for(entry, photo_ids, tmp_path, description=None):
    photos = []
    for offset, photo_id in enumerate(photo_ids):
        path = tmp_path / f"src-{photo_id}.jpg"
        synthetic_photo(size=(1600, 1200)).save(path)
        candidate = make_candidate(photo_id=photo_id, observation_id=photo_id * 10, license="CC BY-NC" if offset else "CC0")
        score = CropScore(0.5, 0.5, 0.5, 0.5 - offset * 0.1)
        photos.append(ChosenPhoto(scored=ScoredPhoto(candidate=candidate, box=Box(0.3, 0.3, 0.7, 0.7), score=score), original=path))
    return SpeciesResult(entry=entry, photos=photos, gap=len(photo_ids) < 3, description=description)


def test_pack_output(tmp_path):
    pack = definition()
    phoebe = Description(summary="A black flycatcher of the west.", field_marks="Black with a white belly.", size="16 cm", habitat="water, coast", source="https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245")
    results = [result_for(pack.species[0], [1, 2, 3], tmp_path, description=phoebe), result_for(pack.species[1], [4, 5], tmp_path)]
    out = tmp_path / "out"

    written = write_pack(pack, results, out, built_at="2026-09-27T00:00:00Z", archive_path=tmp_path / "dist" / "test-pack.zip")

    db = sqlite3.connect(written.database)
    db.row_factory = sqlite3.Row
    species = db.execute("SELECT * FROM species ORDER BY sort_order").fetchall()
    assert [s["id"] for s in species] == ["sayornis-nigricans", "calypte-anna"]
    assert species[0]["common_name"] == "Black Phoebe"
    assert species[0]["inat_taxon_id"] == 17013
    assert (species[0]["summary"], species[0]["field_marks"], species[0]["size"], species[0]["habitat"]) == ("A black flycatcher of the west.", "Black with a white belly.", "16 cm", "water, coast")
    assert species[0]["description_source"] == "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245"
    assert species[1]["summary"] is None and species[1]["field_marks"] is None and species[1]["description_source"] is None

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
    assert info["schema_version"] == 3

    license_text = (out / "LICENSE").read_text()
    for photo in photos:
        assert photo["credit_line"] in license_text and photo["source_url"] in license_text
    assert "Anna's Hummingbird" in license_text
    assert "CC BY-SA 4.0" in license_text and "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245" in license_text

    report = json.loads((out / "report.json").read_text())
    assert report["species"]["calypte-anna"]["gap"] is True
    assert report["species"]["sayornis-nigricans"]["photos"] == 3
    assert report["species"]["sayornis-nigricans"]["description"] == "https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1361402245"
    assert report["species"]["calypte-anna"]["description"] is None
    assert report["gaps"] == {"photos": ["calypte-anna"], "descriptions": ["calypte-anna"], "sounds": []}

    with zipfile.ZipFile(written.archive) as archive:
        names = set(archive.namelist())
    assert "pack.sqlite" in names and "LICENSE" in names and "lens/1.jpg" in names
    assert db.execute("SELECT COUNT(*) FROM lookalike").fetchone()[0] == 0, "no lookalikes in v1: nothing on the lens shows them"


def test_sounds_are_written_with_their_credits(tmp_path):
    pack = definition()
    clip_dir = tmp_path / "clips"
    clip_dir.mkdir()

    def chosen(number, kind, license="CC BY-NC-SA 4.0"):
        path = clip_dir / f"xc-{number}.m4a"
        path.write_bytes(b"m4a" * number)
        candidate = SoundCandidate(
            id=f"xc-{number}", source="xeno-canto", catalogue=f"XC{number}", kind=kind, file_url=f"https://xeno-canto.org/{number}/download",
            extension="mp3", recordist="Ron Overholtz", license=license, source_url=f"https://xeno-canto.org/{number}", quality="A",
        )
        return ChosenSound(candidate=candidate, kind=kind, clip=Clip(path=path, duration_ms=8000), score=0.9)

    phoebe = result_for(pack.species[0], [1, 2, 3], tmp_path)
    phoebe.sounds = SoundResult(sounds=[chosen(11, "song", "CC BY-SA 4.0"), chosen(12, "call")], rejections=[{"id": "xc-13", "kind": "song", "reason": "BirdNET heard Calypte anna"}])
    anna = result_for(pack.species[1], [4, 5, 6], tmp_path)
    anna.sounds = SoundResult()

    written = write_pack(pack, [phoebe, anna], tmp_path / "out", built_at="2026-10-06T00:00:00Z", archive_path=tmp_path / "pack.zip")

    db = sqlite3.connect(written.database)
    db.row_factory = sqlite3.Row
    rows = db.execute("SELECT * FROM sound ORDER BY species_id, rank").fetchall()
    assert [(r["id"], r["kind"], r["rank"]) for r in rows] == [("xc-11", "song", 0), ("xc-12", "call", 1)]
    song = rows[0]
    assert song["species_id"] == "sayornis-nigricans" and song["file"] == "sounds/xc-11.m4a" and song["duration_ms"] == 8000
    assert song["recordist"] == "Ron Overholtz" and song["license"] == "CC BY-SA 4.0" and song["quality"] == "A"
    assert song["credit_line"] == "Ron Overholtz, XC11, https://xeno-canto.org/11 (CC BY-SA 4.0)" and song["short_credit"] == "Sound: Ron Overholtz, XC11"
    assert song["source_url"] == "https://xeno-canto.org/11"
    assert (tmp_path / "out" / "sounds" / "xc-11.m4a").read_bytes() == b"m4a" * 11

    license_text = (tmp_path / "out" / "LICENSE").read_text()
    assert "Sound credits" in license_text and song["credit_line"] in license_text and rows[1]["credit_line"] in license_text
    assert "xeno-canto" in license_text

    report = json.loads((tmp_path / "out" / "report.json").read_text())
    assert report["species"]["sayornis-nigricans"]["sounds"] == {"chosen": {"song": "xc-11", "call": "xc-12"}, "rejected": [{"id": "xc-13", "kind": "song", "reason": "BirdNET heard Calypte anna"}]}
    assert report["gaps"]["sounds"] == ["calypte-anna"]

    with zipfile.ZipFile(written.archive) as archive:
        assert "sounds/xc-11.m4a" in archive.namelist()
