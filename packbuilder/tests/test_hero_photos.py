"""Hero photos (#150): the review shows each first photo as a bird's profile shows it, flags a bird that slot cuts, keeps
a replacement as a proposal the build ignores, and pins it only when the maintainer accepts it by number."""

import json
from pathlib import Path

import pytest
from PIL import Image

from packbuilder import cli
from packbuilder.definition import PackDefinition
from packbuilder.detector import Detection
from packbuilder.geometry import Box
from packbuilder.hero_photos import assess, as_shown, candidates, cuts, first_photos, propose, review, sheets, slot_of, write_overrides
from packbuilder.selection import Overrides
from packbuilder.writer import write_pack
from tests.conftest import make_candidate, synthetic_photo
from tests.test_silhouettes import definition_folder
from tests.test_writer import definition, result_for

PACKS = Path(__file__).resolve().parents[1] / "packs"
PHOEBE, HUMMINGBIRD = "sayornis-nigricans", "calypte-anna"
FULL_BIRD = Box(0.35, 0.4, 0.65, 0.6)


class FixedDetector:
    def __init__(self, box: Box | None = FULL_BIRD):
        self.box = box

    def detect(self, image):
        return [Detection(self.box, 0.9)] if self.box else []


def test_the_slot_is_the_middle_of_the_picture_at_three_to_two():
    assert slot_of((600, 400)) == (0, 0, 600, 400)
    assert slot_of((800, 400)) == (100, 0, 700, 400), "a wide picture loses its sides"
    assert slot_of((600, 1200)) == (0, 400, 600, 800), "a portrait picture loses its top and bottom"


def test_a_bird_whose_head_is_above_the_slot_in_a_portrait_photo_is_flagged():
    """Black Phoebe's first photo: the whole bird is in the picture, and the profile shows its back."""
    assert cuts(Box(0.1, 0.2, 0.9, 0.75), (737, 1200)) == ["slot: top", "slot: bottom"]


def test_a_bird_that_all_shows_is_not_flagged_and_one_at_the_frame_is():
    assert cuts(Box(0.3, 0.2, 0.7, 0.8), (1200, 800)) == []
    assert cuts(Box(0.3, 0.0, 0.7, 0.8), (1200, 800)) == ["frame: top"]
    assert cuts(Box(0.0, 0.2, 1.0, 0.8), (1200, 800)) == ["frame: left", "frame: right"]


def test_a_photo_with_no_bird_found_is_flagged():
    picture = Image.new("RGB", (600, 400))
    assert assess(picture, FixedDetector(None)) == ["no bird found"]
    assert assess(picture, FixedDetector()) == []


def test_as_shown_crops_to_the_slot():
    assert as_shown(Image.new("RGB", (600, 1200))).size == (600, 400)


def pack(tmp_path):
    """A built pack with first photos 1 and 4, and its overrides."""
    built = definition()
    results = [result_for(built.species[0], [1, 2, 3], tmp_path), result_for(built.species[1], [4, 5, 6], tmp_path)]
    write_pack(built, results, tmp_path / "out", built_at="2026-11-05T00:00:00Z")
    return built, tmp_path / "out"


def test_first_photos_are_numbered_in_the_packs_order(tmp_path):
    _, out = pack(tmp_path)
    firsts = first_photos(out)
    assert [(f.number, f.species_id, f.photo_id) for f in firsts] == [(1, PHOEBE, 1), (2, HUMMINGBIRD, 4)]
    assert firsts[0].file.exists()


def test_a_species_with_no_photo_keeps_the_numbers_of_the_rest_as_in_pack_json(tmp_path):
    built = definition()
    write_pack(built, [result_for(built.species[0], [], tmp_path), result_for(built.species[1], [4], tmp_path)], tmp_path / "out", built_at="2026-11-05T00:00:00Z")
    assert [(f.number, f.species_id) for f in first_photos(tmp_path / "out")] == [(2, HUMMINGBIRD)]


def test_the_sheets_show_every_first_photo_and_each_proposal(tmp_path):
    built, out = pack(tmp_path)
    (tmp_path / "cache" / "photos" / "large").mkdir(parents=True)
    synthetic_photo(size=(1200, 800)).save(tmp_path / "cache" / "photos" / "large" / "9.jpg")
    overrides = {}
    propose(built, overrides, PHOEBE, 9, "the whole bird")
    made, flags = sheets(built, overrides, first_photos(out), FixedDetector(Box(0.0, 0.2, 0.5, 0.8)), tmp_path / "cache", tmp_path / "sheets")
    assert [path.name for path in made] == ["first-01.jpg", "proposals-01.jpg"]
    assert flags == {1: ["frame: left"], 2: ["frame: left"]}
    # Without proposals the old sheet goes.
    made, _ = sheets(built, {}, first_photos(out), FixedDetector(), tmp_path / "cache", tmp_path / "sheets")
    assert [path.name for path in made] == ["first-01.jpg"] and not (tmp_path / "sheets" / "proposals-01.jpg").exists()


class Metadata:
    def __init__(self, found):
        self.found = found

    def candidates_for(self, taxon_id):
        return self.found


def cached_large(tmp_path, photo_id, size=(1600, 1200)):
    folder = tmp_path / "cache" / "photos" / "large"
    folder.mkdir(parents=True, exist_ok=True)
    synthetic_photo(size=size).save(folder / f"{photo_id}.jpg")


def test_candidates_come_from_the_cached_pool_and_show_the_whole_bird(tmp_path, monkeypatch):
    built = definition()
    entry = built.species[0]
    photos = [make_candidate(photo_id=i, observation_id=i * 10, license="CC0", width=2048, height=1536) for i in (1, 2, 3)]
    cached_large(tmp_path, 1)
    cached_large(tmp_path, 3)  # 2 isn't in the cache: no download for a review
    monkeypatch.setattr("packbuilder.hero_photos.score_crop", lambda image, box: type("S", (), {"sharpness": 0.9})())
    found = candidates(entry, Overrides(), Metadata(photos), FixedDetector(), tmp_path / "cache")
    assert {c.photo_id for c in found} == {1, 3}
    assert all(c.picture.width / c.picture.height == pytest.approx(1.5, abs=0.01) for c in found)
    assert candidates(entry, Overrides(exclude=[1]), Metadata(photos), FixedDetector(), tmp_path / "cache")[0].photo_id == 3
    assert candidates(entry, Overrides(), Metadata(photos), FixedDetector(Box(0.0, 0.1, 0.9, 0.9)), tmp_path / "cache") == [], "the original's frame cuts that bird"


def test_a_proposal_is_not_a_pin_and_an_excluded_photo_cannot_be_proposed():
    built = definition()
    overrides = {"Sayornis nigricans": {"include": [7], "exclude": [8]}}
    propose(built, overrides, PHOEBE, 9, "the whole bird")
    assert overrides["Sayornis nigricans"]["hero"] == {"proposed": 9, "_why": "the whole bird"}
    assert Overrides.from_mapping(overrides["Sayornis nigricans"]).include == [7], "the build doesn't see it"
    with pytest.raises(ValueError):
        propose(built, overrides, PHOEBE, 8, "excluded")


def test_accepting_pins_it_first_and_keeps_the_photos_that_are_credited(tmp_path):
    folder = definition_folder(tmp_path)
    (folder / "silhouette.lock.json").write_text(json.dumps({"species": {PHOEBE: {"photos": [6], "review": "pending"}}}))
    built = PackDefinition.load(folder / "pack.json")
    overrides = {"Sayornis nigricans": {"include": [7]}, "Calypte anna": {}}
    propose(built, overrides, PHOEBE, 9, "the whole bird")
    propose(built, overrides, HUMMINGBIRD, 10, "better light")
    assert review(built, overrides, folder, accept=[PHOEBE], decline=[HUMMINGBIRD]) == ([PHOEBE], [HUMMINGBIRD])
    phoebe = overrides["Sayornis nigricans"]
    assert phoebe["include"] == [9, 1, 6, 7], "the proposal, the patch's photo and the silhouette's, what was pinned"
    assert phoebe["hero"] == {"pinned": 9, "_why": "the whole bird"}
    assert "Calypte anna" not in overrides, "a declined proposal leaves nothing behind"
    with pytest.raises(KeyError):
        review(built, overrides, folder, accept=[HUMMINGBIRD])


def test_one_species_cant_be_both_accepted_and_declined(tmp_path):
    folder = definition_folder(tmp_path)
    built = PackDefinition.load(folder / "pack.json")
    overrides = {}
    propose(built, overrides, PHOEBE, 9, "a")
    with pytest.raises(ValueError):
        review(built, overrides, folder, accept=[PHOEBE], decline=[PHOEBE])
    assert overrides["Sayornis nigricans"]["hero"]["proposed"] == 9


def test_accept_all_leaves_what_this_answer_declines(tmp_path):
    folder = definition_folder(tmp_path)
    built = PackDefinition.load(folder / "pack.json")
    overrides = {}
    propose(built, overrides, PHOEBE, 9, "a")
    propose(built, overrides, HUMMINGBIRD, 10, "b")
    assert review(built, overrides, folder, decline=[HUMMINGBIRD], accept_all=True) == ([PHOEBE], [HUMMINGBIRD])
    assert overrides["Sayornis nigricans"]["include"][0] == 9 and "Calypte anna" not in overrides


def test_the_command_line_applies_the_answer_by_the_sheets_numbers(tmp_path):
    folder = definition_folder(tmp_path)
    assert cli.main(["hero-review", str(folder), "--propose", "1=9", "--propose", "2=10", "--why", "the whole bird"]) == 0
    overrides = json.loads((folder / "overrides.json").read_text())
    assert overrides["Sayornis nigricans"]["hero"]["proposed"] == 9
    assert cli.main(["hero-review", str(folder), "--accept", "9"]) == 1, "no such number"
    assert cli.main(["hero-review", str(folder), "--propose", "Foo=1"]) == 1, "no such bird"
    assert cli.main(["hero-candidates", str(folder), "--species", "999", "--out", str(tmp_path / "c.jpg")]) == 1
    assert cli.main(["hero-review", str(folder), "--accept", "1", "--decline", "2"]) == 0
    overrides = json.loads((folder / "overrides.json").read_text())
    assert overrides["Sayornis nigricans"]["include"] == [9, 1] and overrides["Sayornis nigricans"]["hero"]["pinned"] == 9
    assert "Calypte anna" not in overrides
    assert cli.main(["hero-review", str(folder), "--accept", "2"]) == 1, "no proposal left"


@pytest.mark.parametrize("pack_dir", sorted(PACKS.iterdir()), ids=lambda p: p.name)
def test_no_committed_proposal_is_a_photo_the_build_would_drop(pack_dir):
    for name, data in json.loads((pack_dir / "overrides.json").read_text()).items():
        if isinstance(data, dict) and "proposed" in data.get("hero", {}):
            assert data["hero"]["proposed"] not in data.get("exclude", []), name


def test_the_overrides_file_keeps_its_committed_format(tmp_path):
    source = (tmp_path / "o.json")
    data = {"_comment": "x", "Bird": {"exclude": [1, 2]}}
    write_overrides(source, data)
    assert source.read_text() == '{\n "_comment": "x",\n "Bird": {\n  "exclude": [\n   1,\n   2\n  ]\n }\n}\n'


def test_a_proposal_changes_no_build_and_an_accepted_one_comes_first(tmp_path):
    """Through the pipeline: the build's choice is the same with a proposal in the overrides, and first once it's pinned."""
    from packbuilder.pipeline import BuildOptions, build_species
    from packbuilder.detector import Detection as Det

    built = definition()
    entry = built.species[0]
    photos = [make_candidate(photo_id=i, observation_id=i * 10, license="CC0", width=2048, height=1536) for i in (1, 2, 3, 9)]

    def fetch(candidate, cache_dir, size):
        path = tmp_path / f"{candidate.photo_id}-{size}.jpg"
        if not path.exists():
            synthetic_photo(size=(1600, 1200)).save(path)
        return path

    options = BuildOptions(cache_dir=tmp_path, out_dir=tmp_path / "out", fetch=fetch)
    detector = type("D", (), {"detect": lambda self, image: [Det(Box(0.3, 0.3, 0.7, 0.7), 0.9)]})()
    raw = {}
    propose(built, {entry.scientific_name: raw}, PHOEBE, 9, "the whole bird")
    before = build_species(entry, Overrides.from_mapping({}), Metadata(photos), detector, options)
    proposed = build_species(entry, Overrides.from_mapping(raw), Metadata(photos), detector, options)
    assert [c.candidate.photo_id for c in proposed.photos] == [c.candidate.photo_id for c in before.photos]
    pinned = build_species(entry, Overrides.from_mapping({"include": [9]}), Metadata(photos), detector, options)
    assert pinned.photos[0].candidate.photo_id == 9
