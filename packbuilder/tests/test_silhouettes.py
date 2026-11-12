"""True silhouettes (#150): each species' silhouette comes from its cached isolated reference bird, a lock pins it and
its review, only an approved one ships in the pack, and the review goes by the contact sheets' numbers."""

import hashlib
import json
import sqlite3
from pathlib import Path

import numpy as np
import pytest
from PIL import Image, ImageDraw

from packbuilder import cli, pipeline
from packbuilder.detector import Detection
from packbuilder.geometry import Box
from packbuilder.definition import PackDefinition
from packbuilder.pack_art import ArtLock
from packbuilder.patch_art import PatchLock, _isolate_prompt
from packbuilder.silhouettes import APPROVED, GAP, PENDING, REJECTED, SIZE, SilhouetteLock, SilhouetteMaker, derive, review, sources
from packbuilder.writer import write_pack
from tests.conftest import make_candidate, synthetic_photo
from tests.test_writer import definition, result_for

PACKS = Path(__file__).resolve().parents[1] / "packs"
PHOEBE, HUMMINGBIRD = "sayornis-nigricans", "calypte-anna"


def on_white(size=(576, 768)) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    image = Image.new("RGB", size, "white")
    return image, ImageDraw.Draw(image)


def wading_bird(body=(90, 70, 50), legs=(40, 40, 40), hole_in_body=None) -> Image.Image:
    """A body over two long legs that meet at the feet, so the gap between them is enclosed."""
    image, draw = on_white()
    draw.ellipse((150, 150, 430, 400), fill=body)
    draw.line((230, 380, 280, 650), fill=legs, width=14)
    draw.line((350, 380, 300, 650), fill=legs, width=14)
    draw.rectangle((240, 640, 340, 660), fill=legs)
    if hole_in_body:
        draw.ellipse(hole_in_body, fill=(255, 255, 255))
    return image


def alpha(silhouette) -> np.ndarray:
    return np.asarray(silhouette.image.getchannel("A"))


def cached_bird(cache, photo_id: int, image: Image.Image, seed: int = 49):
    prompt = hashlib.sha256(_isolate_prompt().encode()).hexdigest()[:10]
    path = cache / "isolated" / f"{photo_id}-s{seed}-bird-isolate@1-i{prompt}.png"
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    path.with_suffix(".json").write_text(json.dumps({"seed": seed}))


def maker(tmp_path, source_map=None) -> SilhouetteMaker:
    cache = tmp_path / "cache"
    cached_bird(cache, 1, wading_bird())
    cached_bird(cache, 2, wading_bird(body=(20, 20, 20)))
    source_map = source_map or {PHOEBE: (1, 49, "Black Phoebe"), HUMMINGBIRD: (2, 49, "Anna's Hummingbird")}
    return SilhouetteMaker(pack_id="test-pack", lock=SilhouetteLock.load(tmp_path / "silhouette.lock.json"), sources=source_map, cache_dir=cache)


def test_a_silhouette_is_the_birds_shape_cropped_to_size_on_transparency():
    made = derive(wading_bird())
    assert max(made.image.size) == SIZE
    assert made.image.getchannel("A").getextrema() == (0, 255)
    assert set(np.asarray(made.image.getchannel("L")).ravel()) == {255}, "the colour is the app's: it tints at draw time"
    # Tight: the bird reaches near every side, at most a pixel or two in.
    ys, xs = np.nonzero(alpha(made) > 128)
    assert xs.min() <= 3 and ys.min() <= 3 and made.image.width - xs.max() <= 4 and made.image.height - ys.max() <= 4


def test_a_silhouette_is_a_few_kilobytes():
    assert len(derive(wading_bird()).png) < 8_000


def test_the_gap_between_the_legs_stays_open_so_a_heron_keeps_its_legs():
    made = derive(wading_bird())
    height, width = alpha(made).shape
    between_the_legs = alpha(made)[int(height * 0.75), width // 2]
    assert between_the_legs == 0


def test_white_plumage_blown_to_paper_is_filled_in():
    """A Bald Eagle's white head: inside the bird's mask but as white as the page, with pale feathers around it."""
    image, draw = on_white()
    draw.ellipse((150, 150, 430, 500), fill=(235, 232, 228))
    draw.ellipse((220, 230, 360, 400), fill=(255, 255, 255))
    made = derive(image)
    assert alpha(made)[made.image.height // 2, made.image.width // 2] == 255
    assert made.holes_filled == 1


def test_a_bird_pinned_to_fill_its_holes_closes_a_white_mark_on_dark_plumage_and_is_reviewed_again(tmp_path):
    """A Gadwall's white speculum: as white as the page with dark feathers around it, so the recipe takes it for air."""
    image, draw = on_white()
    draw.ellipse((150, 150, 430, 500), fill=(60, 55, 50))
    draw.ellipse((250, 260, 330, 380), fill=(255, 255, 255))
    assert alpha(derive(image))[derive(image).image.height // 2, derive(image).image.width // 2] == 0
    filled = derive(image, fill_holes=True)
    assert alpha(filled)[filled.image.height // 2, filled.image.width // 2] == 255 and filled.holes_filled == 1

    cached_bird(tmp_path / "cache", 7, image)
    def a_maker(fill):
        return SilhouetteMaker(pack_id="test-pack", lock=SilhouetteLock.load(tmp_path / "silhouette.lock.json"),
                               sources={PHOEBE: (7, 49, "Black Phoebe")}, cache_dir=tmp_path / "cache", fill_holes=frozenset(fill))
    first = a_maker([])
    first.make([PHOEBE])
    first.lock.species[PHOEBE] |= {"review": REJECTED, "why": "a hole in it"}
    first.lock.write()
    again = a_maker([PHOEBE])
    made = again.make([PHOEBE])
    assert again.derived == 1 and made[PHOEBE].review == PENDING
    assert again.lock.species[PHOEBE]["fill_holes"] is True and "why" not in again.lock.species[PHOEBE]
    assert a_maker([PHOEBE]).make([PHOEBE])[PHOEBE].review == PENDING


def test_a_small_pinhole_in_dark_plumage_is_filled_in():
    made = derive(wading_bird(hole_in_body=(280, 260, 288, 268)))
    height, width = alpha(made).shape
    assert (alpha(made)[: height // 2, : width] > 128).mean() > 0.4
    assert made.holes_filled == derive(wading_bird()).holes_filled + 1


def test_a_nearly_white_bird_keeps_its_whole_outline():
    """An egret: nothing but off-white on white, which a lax threshold would lose."""
    image, draw = on_white()
    draw.ellipse((100, 300, 480, 500), fill=(252, 251, 250))
    made = derive(image)
    assert made.image.size[0] > made.image.size[1], "the whole ellipse, not a sliver of it"
    assert (alpha(made) > 128).mean() > 0.7


def test_stray_specks_are_cleaned_away():
    image = wading_bird()
    draw = ImageDraw.Draw(image)
    draw.rectangle((10, 10, 13, 13), fill=(90, 70, 50))
    clean = derive(wading_bird())
    assert derive(image).image.size == clean.image.size


def test_a_bird_the_frame_cuts_off_says_so():
    image, draw = on_white()
    draw.ellipse((300, 200, 800, 500), fill=(90, 70, 50))
    assert derive(image).cut == ["right"]
    assert derive(wading_bird()).cut == []


def test_a_picture_with_no_bird_raises():
    with pytest.raises(ValueError):
        derive(Image.new("RGB", (100, 100), "white"))


def test_each_species_is_derived_from_its_cached_bird_locked_and_pending(tmp_path):
    made = maker(tmp_path).make([PHOEBE, HUMMINGBIRD])
    assert made[PHOEBE].review == PENDING and not made[PHOEBE].ships and made[PHOEBE].file.exists()
    entry = SilhouetteLock.load(tmp_path / "silhouette.lock.json").species[PHOEBE]
    assert entry["photos"] == [1] and entry["isolate_seed"] == 49 and entry["review"] == PENDING
    assert entry["sha256"] == hashlib.sha256(made[PHOEBE].file.read_bytes()).hexdigest()
    assert entry["common_name"] == "Black Phoebe" and entry["workflow"].startswith("silhouette@") and entry["bytes"] > 0
    assert made[PHOEBE].photos == (1,)


def test_a_warm_lock_derives_nothing_and_keeps_its_review(tmp_path):
    first = maker(tmp_path)
    first.make([PHOEBE])
    first.lock.species[PHOEBE]["review"] = APPROVED
    first.lock.write()
    (tmp_path / "cache" / "isolated").rename(tmp_path / "gone")  # it would fail if it looked at the bird
    again = maker_without_birds(tmp_path)
    made = again.make([PHOEBE])
    assert made[PHOEBE].ships and again.derived == 0


def maker_without_birds(tmp_path) -> SilhouetteMaker:
    return SilhouetteMaker(pack_id="test-pack", lock=SilhouetteLock.load(tmp_path / "silhouette.lock.json"),
                           sources={PHOEBE: (1, 49, "Black Phoebe")}, cache_dir=tmp_path / "cache")


def test_a_new_recipe_that_comes_out_the_same_keeps_its_review_and_one_that_differs_is_reviewed_again(tmp_path):
    first = maker(tmp_path)
    first.make([PHOEBE, HUMMINGBIRD])
    review(first.lock, approve=[PHOEBE], reject=[HUMMINGBIRD], why="no legs")
    newer = maker(tmp_path)
    newer.version = "silhouette@2"
    made = newer.make([PHOEBE, HUMMINGBIRD])
    assert newer.derived == 2 and made[PHOEBE].review == APPROVED and made[HUMMINGBIRD].review == REJECTED
    assert newer.lock.species[PHOEBE]["workflow"] == "silhouette@2" and newer.lock.species[HUMMINGBIRD]["why"] == "no legs"
    changed = maker(tmp_path)
    changed.version = "silhouette@3"
    changed.lock.species[PHOEBE]["sha256"] = "an older picture"
    assert changed.make([PHOEBE])[PHOEBE].review == PENDING


def test_a_new_reference_means_a_new_review(tmp_path):
    first = maker(tmp_path)
    first.make([PHOEBE])
    first.lock.species[PHOEBE]["review"] = APPROVED
    first.lock.write()
    cached_bird(tmp_path / "cache", 3, wading_bird(body=(10, 10, 10)).transpose(Image.Transpose.FLIP_LEFT_RIGHT).rotate(20, fillcolor="white"))
    moved = maker(tmp_path, {PHOEBE: (3, 49, "Black Phoebe")})
    made = moved.make([PHOEBE])
    assert made[PHOEBE].review == PENDING and made[PHOEBE].photos == (3,)


def test_a_rejected_silhouette_waits_for_another_reference_rather_than_coming_back_the_same(tmp_path):
    first = maker(tmp_path)
    first.make([PHOEBE])
    review(first.lock, reject=[PHOEBE], why="no legs")
    again = maker(tmp_path)
    made = again.make([PHOEBE])
    assert made[PHOEBE].review == REJECTED and not made[PHOEBE].ships and again.derived == 0
    assert again.lock.species[PHOEBE]["why"] == "no legs"
    cached_bird(tmp_path / "cache", 3, wading_bird(body=(10, 10, 10)).rotate(20, fillcolor="white"))
    assert maker(tmp_path, {PHOEBE: (3, 49, "Black Phoebe")}).make([PHOEBE])[PHOEBE].review == PENDING


def test_a_species_with_no_bird_in_the_cache_is_left_out_and_the_rest_carry_on(tmp_path):
    source_map = {PHOEBE: (1, 49, "Black Phoebe"), HUMMINGBIRD: (99, 49, "Anna's Hummingbird")}
    made = maker(tmp_path, source_map).make([PHOEBE, HUMMINGBIRD])
    assert made[PHOEBE].file is not None and made[HUMMINGBIRD].file is None and not made[HUMMINGBIRD].ships


def test_the_source_is_the_patch_reference_then_the_pack_art_then_a_pin(tmp_path):
    patches = PatchLock(tmp_path / "p", {PHOEBE: {"common_name": "Black Phoebe", "photos": [7], "isolate_seed": 59}})
    art = ArtLock(tmp_path / "a", {PHOEBE: {"common_name": "Black Phoebe", "photos": [8], "isolate_seed": 49},
                                   HUMMINGBIRD: {"common_name": "Anna's Hummingbird", "photos": [9], "isolate_seed": 49},
                                   "text-only": {"common_name": "Text Bird", "photos": []}})
    found = sources(patches, art, {})
    assert found[PHOEBE] == (7, 59, "Black Phoebe") and found[HUMMINGBIRD] == (9, 49, "Anna's Hummingbird")
    assert "text-only" not in found, "a painting from text has no bird to take a shape from"
    assert sources(patches, art, {PHOEBE: 12})[PHOEBE] == (12, None, "Black Phoebe")


def test_a_pinned_reference_takes_whichever_isolation_is_cached(tmp_path):
    cache = tmp_path / "cache"
    cached_bird(cache, 12, wading_bird(), seed=59)
    made = maker(tmp_path, {PHOEBE: (12, None, "Black Phoebe")}).make([PHOEBE])
    assert made[PHOEBE].photos == (12,)
    assert SilhouetteLock.load(tmp_path / "silhouette.lock.json").species[PHOEBE]["isolate_seed"] == 59


def test_the_review_approves_rejects_and_gives_up(tmp_path):
    made = maker(tmp_path)
    made.make([PHOEBE, HUMMINGBIRD])
    review(made.lock, reject=[PHOEBE], approve_all=True, why="not a phoebe")
    assert made.lock.species[PHOEBE]["review"] == REJECTED and made.lock.species[PHOEBE]["why"] == "not a phoebe"
    assert made.lock.species[HUMMINGBIRD]["review"] == APPROVED
    review(made.lock, gap=[PHOEBE])
    assert made.lock.species[PHOEBE]["review"] == GAP
    assert SilhouetteLock.load(made.lock.path).species[PHOEBE]["review"] == GAP


def test_the_contact_sheets_are_numbered_in_the_packs_order(tmp_path):
    made = maker(tmp_path)
    species = [PHOEBE, HUMMINGBIRD]
    sheets = made.sheets(species, made.make(species), tmp_path / "sheets")
    assert [sheet.name for sheet in sheets] == ["sheet-01.jpg", "overview.jpg"]
    assert all(Image.open(sheet).width > 200 for sheet in sheets)
    # A second, shorter pass leaves no stale sheet behind.
    (tmp_path / "sheets" / "sheet-09.jpg").write_bytes(b"old")
    made.sheets(species, made.make(species), tmp_path / "sheets")
    assert not (tmp_path / "sheets" / "sheet-09.jpg").exists()


def built(tmp_path, approve):
    pack = definition()
    made = maker(tmp_path)
    species = [entry.id for entry in pack.species]
    made.make(species)
    review(made.lock, approve=approve)
    results = [result_for(pack.species[0], [1, 10, 11], tmp_path), result_for(pack.species[1], [2, 4, 5], tmp_path)]
    written = write_pack(pack, results, tmp_path / "out", built_at="2026-11-05T00:00:00Z", silhouettes=made.make(species), silhouette_version="silhouette@1")
    return written, sqlite3.connect(written.database), tmp_path / "out"


def test_only_an_approved_silhouette_goes_in_the_pack_with_the_pack_staying_on_its_schema(tmp_path):
    written, db, out = built(tmp_path, [PHOEBE])
    rows = db.execute("SELECT species_id, file, width, height, source_photo_ids, workflow_version FROM silhouette").fetchall()
    assert len(rows) == 1
    species_id, file, width, height, photos, version = rows[0]
    assert species_id == PHOEBE and file == f"silhouette/{PHOEBE}.png" and json.loads(photos) == [1] and version == "silhouette@1"
    with Image.open(out / file) as shipped:
        assert shipped.size == (width, height) and shipped.mode == "LA" and max(shipped.size) == SIZE
    assert not (out / f"silhouette/{HUMMINGBIRD}.png").exists()
    assert db.execute("SELECT schema_version FROM pack").fetchone() == (5,), "additive: a reader that doesn't know the table never opens it"
    report = json.loads((out / "report.json").read_text())
    assert report["unreviewed"]["silhouettes"] == [HUMMINGBIRD]
    assert "silhouette/" in (out / "LICENSE").read_text() and "shape taken from photo 1" in (out / "LICENSE").read_text()


def test_a_silhouette_whose_photo_left_the_pack_stays_out_because_it_could_not_be_credited(tmp_path):
    pack = definition()
    made = maker(tmp_path)
    species = [entry.id for entry in pack.species]
    made.make(species)
    review(made.lock, approve_all=True)
    results = [result_for(pack.species[0], [20, 21, 22], tmp_path), result_for(pack.species[1], [2, 4, 5], tmp_path)]
    written = write_pack(pack, results, tmp_path / "out", built_at="2026-11-05T00:00:00Z", silhouettes=made.make(species), silhouette_version="silhouette@1")
    db = sqlite3.connect(written.database)
    assert [row[0] for row in db.execute("SELECT species_id FROM silhouette")] == [HUMMINGBIRD]
    assert json.loads((tmp_path / "out" / "report.json").read_text())["unreviewed"]["silhouettes"] == [PHOEBE]


def test_a_pack_built_without_the_step_has_an_empty_table(tmp_path):
    pack = definition()
    results = [result_for(pack.species[0], [1], tmp_path), result_for(pack.species[1], [2], tmp_path)]
    written = write_pack(pack, results, tmp_path / "out", built_at="2026-11-05T00:00:00Z")
    assert sqlite3.connect(written.database).execute("SELECT COUNT(*) FROM silhouette").fetchone() == (0,)
    assert "silhouettes" not in json.loads((tmp_path / "out" / "report.json").read_text()).get("unreviewed", {})


@pytest.mark.parametrize("pack_dir", [p for p in sorted(PACKS.iterdir()) if (p / "silhouette.lock.json").exists()], ids=lambda p: p.name)
def test_the_committed_lock_covers_its_pack_and_follows_its_pins(pack_dir):
    species = PackDefinition.load(pack_dir / "pack.json").species
    lock = SilhouetteLock.load(pack_dir / "silhouette.lock.json").species
    overrides = json.loads((pack_dir / "overrides.json").read_text())
    assert {entry.id for entry in species} == set(lock)
    for entry in species:
        pin = overrides.get(entry.scientific_name, {}).get("art", {}).get("silhouette", {}).get("reference")
        if pin is not None:
            assert lock[entry.id]["photos"] == [pin], entry.common_name


def definition_folder(tmp_path) -> Path:
    folder = tmp_path / "definition"
    folder.mkdir()
    (folder / "pack.json").write_text(json.dumps({
        "id": "test-pack", "name": "Test Pack", "region": "Testland", "version": 1, "inat_place_ids": [1],
        "bounding_box": {"south": 0, "west": 0, "north": 1, "east": 1},
        "species": [
            {"scientific_name": "Sayornis nigricans", "common_name": "Black Phoebe", "birdnet_label": "Sayornis nigricans", "inat_taxon_id": 17013},
            {"scientific_name": "Calypte anna", "common_name": "Anna's Hummingbird", "birdnet_label": "Calypte anna", "inat_taxon_id": 6317},
        ],
    }))
    (folder / "overrides.json").write_text("{}")
    (folder / "patch.lock.json").write_text(json.dumps({"species": {
        PHOEBE: {"common_name": "Black Phoebe", "photos": [1], "isolate_seed": 49, "review": "approved"},
        HUMMINGBIRD: {"common_name": "Anna's Hummingbird", "photos": [2], "isolate_seed": 49, "review": "approved"},
    }}))
    return folder


def test_the_command_line_derives_draws_and_reviews_by_the_sheets_numbers(tmp_path):
    folder = definition_folder(tmp_path)
    cache = tmp_path / "cache"
    cached_bird(cache / "art", 1, wading_bird())
    cached_bird(cache / "art", 2, wading_bird(body=(20, 20, 20)))
    sheets = tmp_path / "sheets"
    assert cli.main(["silhouettes", str(folder), "--cache", str(cache), "--sheets", str(sheets)]) == 0
    assert (sheets / "sheet-01.jpg").exists()
    assert cli.main(["silhouette-review", str(folder), "--reject", "1", "--approve-all", "--why", "no legs"]) == 0
    lock = SilhouetteLock.load(folder / "silhouette.lock.json")
    assert lock.species[PHOEBE]["review"] == REJECTED and lock.species[PHOEBE]["why"] == "no legs"
    assert lock.species[HUMMINGBIRD]["review"] == APPROVED
    # Commas and names work too; an unknown number names the problem and changes nothing.
    assert cli.main(["silhouette-review", str(folder), "--gap", "1,Anna's Hummingbird"]) == 0
    assert SilhouetteLock.load(folder / "silhouette.lock.json").species[HUMMINGBIRD]["review"] == GAP
    assert cli.main(["silhouette-review", str(folder), "--approve", "3"]) == 1


def test_a_pack_without_art_locks_gets_no_step_and_no_stray_lock(tmp_path):
    folder = definition_folder(tmp_path)
    (folder / "patch.lock.json").unlink()
    assert cli.main(["silhouettes", str(folder), "--cache", str(tmp_path / "cache"), "--sheets", str(tmp_path / "sheets")]) == 1
    assert not (folder / "silhouette.lock.json").exists()


def test_a_build_derives_them_draws_their_sheets_and_ships_the_approved(tmp_path):
    """Through build_pack: nothing ships before the review, the sheets are there, and an approved silhouette is in the rebuilt pack."""
    pack = definition()
    entry = pack.species[0]
    pack = PackDefinition(id=pack.id, name=pack.name, region=pack.region, version=1, place_ids=(1,), bounding_box=pack.bounding_box, species=[entry])

    class Metadata:
        def candidates_for(self, taxon_id):
            return [make_candidate(photo_id=i, observation_id=i * 10, license="CC0", width=2048, height=1536) for i in (1, 2)]

    class Detector:
        def detect(self, image):
            return [Detection(Box(0.3, 0.3, 0.7, 0.7), 0.9)]

    def fetch(candidate, cache_dir, size):
        path = tmp_path / f"{candidate.photo_id}-{size}.jpg"
        if not path.exists():
            synthetic_photo(size=(1600, 1200)).save(path)
        return path

    (tmp_path / "overrides.json").write_text(json.dumps({entry.scientific_name: {"include": [1, 2]}}))
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=fetch, min_photos=1)

    def build():
        return pipeline.build_pack(pack, tmp_path / "overrides.json", Metadata(), Detector(), options, art_sheets=tmp_path / "sheets",
                                   silhouette_maker=maker(tmp_path, {PHOEBE: (1, 49, "Black Phoebe")}))

    assert sqlite3.connect(build().database).execute("SELECT COUNT(*) FROM silhouette").fetchone() == (0,)
    assert (tmp_path / "sheets" / "silhouettes" / "sheet-01.jpg").exists() and (tmp_path / "sheets" / "silhouettes" / "overview.jpg").exists()
    review(SilhouetteLock.load(tmp_path / "silhouette.lock.json"), approve_all=True)
    rows = sqlite3.connect(build().database).execute("SELECT species_id, file, workflow_version FROM silhouette").fetchall()
    assert rows == [(PHOEBE, f"silhouette/{PHOEBE}.png", "silhouette@1")]
    assert (tmp_path / "pack" / rows[0][1]).exists()


def test_the_command_line_takes_a_pin_from_the_overrides(tmp_path):
    folder = definition_folder(tmp_path)
    (folder / "overrides.json").write_text(json.dumps({"Sayornis nigricans": {"art": {"silhouette": {"reference": 5}}}}))
    cache = tmp_path / "cache"
    cached_bird(cache / "art", 5, wading_bird())
    cached_bird(cache / "art", 2, wading_bird())
    assert cli.main(["silhouettes", str(folder), "--cache", str(cache), "--sheets", str(tmp_path / "sheets")]) == 0
    assert SilhouetteLock.load(folder / "silhouette.lock.json").species[PHOEBE]["photos"] == [5]
