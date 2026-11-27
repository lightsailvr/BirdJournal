"""How the North America pack is built (issue #215, of spec #206): three photos a species, sounds from the United
States first and Canada when it has none, a build of some of its birds that leaves the rest of the pack's files alone,
and a rarity calibration that never pools it."""

import json
from pathlib import Path

from packbuilder.definition import PackDefinition

PACKS = Path(__file__).resolve().parents[1] / "packs"


def written(tmp_path, **fields) -> Path:
    path = tmp_path / "pack.json"
    path.write_text(json.dumps({
        "id": "test-pack", "name": "Test Pack", "region": "Testland", "version": 1, "inat_place_id": 1,
        "bounding_box": {"south": 0, "west": 0, "north": 1, "east": 1},
        "species": [{"scientific_name": "Sayornis nigricans", "common_name": "Black Phoebe", "inat_taxon_id": 17013}],
        **fields,
    }))
    return path


def test_a_definition_says_how_many_photos_a_species_keeps_and_where_its_sounds_are_searched(tmp_path):
    continental = PackDefinition.load(written(tmp_path, photos_per_species=3, sound_countries=["United States", "Canada"]))
    assert continental.photos_per_species == 3
    assert continental.sound_countries == ("United States", "Canada")


def test_a_definition_that_says_neither_keeps_five_photos_and_searches_its_country(tmp_path):
    assert PackDefinition.load(written(tmp_path)).photos_per_species == 5
    assert PackDefinition.load(written(tmp_path)).sound_countries == ("United States",)
    assert PackDefinition.load(written(tmp_path, country="Canada")).sound_countries == ("Canada",)


def test_north_america_keeps_three_photos_and_searches_the_united_states_then_canada():
    definition = PackDefinition.load(PACKS / "north-america" / "pack.json")
    assert definition.photos_per_species == 3
    assert definition.sound_countries == ("United States", "Canada")
    assert len(definition.species) == 300, "the tracer builds ten of them; the list stays the approved one"


def test_the_regional_packs_keep_five_photos_and_their_one_country():
    for folder in sorted(PACKS.iterdir()):
        if folder.name != "north-america":
            definition = PackDefinition.load(folder / "pack.json")
            assert (definition.photos_per_species, definition.sound_countries) == (5, ("United States",)), folder.name


# --- Three photos a species -------------------------------------------------------------------------------------------

import sqlite3  # noqa: E402

import pytest  # noqa: E402

from packbuilder import pipeline  # noqa: E402
from packbuilder.definition import BoundingBox, SpeciesEntry  # noqa: E402
from packbuilder.detector import Detection  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

from tests.comfy_stub import BACKGROUND, serve  # noqa: E402
from tests.conftest import make_candidate  # noqa: E402
from tests.test_pack_art import BIRD, artist  # noqa: E402
from tests.test_pipeline import FakeMetadata  # noqa: E402

ROBIN = SpeciesEntry(scientific_name="Turdus migratorius", common_name="American Robin", birdnet_label="Turdus migratorius", inat_taxon_id=12727)
CROW = SpeciesEntry(scientific_name="Corvus brachyrhynchos", common_name="American Crow", birdnet_label="Corvus brachyrhynchos", inat_taxon_id=8021)
CARDINAL = SpeciesEntry(scientific_name="Cardinalis cardinalis", common_name="Northern Cardinal", birdnet_label="Cardinalis cardinalis", inat_taxon_id=9083)


@pytest.fixture
def comfy():
    state, server = serve()
    yield state
    server.shutdown()


class Detector:
    def detect(self, image):
        return [Detection(box=BIRD, score=0.9)]


def continental(species, **fields) -> PackDefinition:
    return PackDefinition(id="north-america", name="North America", region="United States and Canada", version=1, place_ids=(1, 6712),
                          bounding_box=BoundingBox(0, 0, 1, 1), species=species, photos_per_species=3, sound_countries=("United States", "Canada"), **fields)


def six_photos(entry, first: int):
    """Six cleared photos of a species, each its own observation, the later ones better lit."""
    return [make_candidate(photo_id=photo_id, observation_id=photo_id, taxon_id=entry.inat_taxon_id, width=1200, height=1600) for photo_id in range(first, first + 6)]


def lit_by_id(tmp_path):
    """A fetcher of sharp photos of a bird on the stub's background, brighter with their id, so the best-lit of a
    species' photos is its last."""
    def fetch(candidate, cache_dir, size):
        path = tmp_path / f"photo-{candidate.photo_id}.jpg"
        if not path.exists():
            light = 0.1 + 0.08 * (candidate.photo_id % 10)  # dim enough that none is fully lit or blown out
            pixels = np.full((1600, 1200, 3), BACKGROUND, dtype=np.uint8)
            x0, y0, x1, y1 = BIRD.pixels((1200, 1600))
            feathers = np.random.default_rng(candidate.photo_id).integers(90, 250, size=((y1 - y0) // 8, (x1 - x0) // 8, 3)) * light
            pixels[y0:y1, x0:x1] = np.kron(feathers, np.ones((8, 8, 1)))[: y1 - y0, : x1 - x0].astype(np.uint8)
            Image.fromarray(pixels, "RGB").save(path, quality=95)
        return path
    return fetch


def photo_rows(pack_dir, species_id):
    with sqlite3.connect(pack_dir / "pack.sqlite") as db:
        return [int(row[0].removeprefix("inat-")) for row in db.execute("SELECT id FROM photo WHERE species_id = ? ORDER BY rank", (species_id,))]


def test_a_build_keeps_as_many_photos_a_species_as_its_definition_says(tmp_path):
    definition = continental([ROBIN])
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))

    pipeline.build_pack(definition, tmp_path / "overrides.json", FakeMetadata(six_photos(ROBIN, 11)), Detector(), options)

    assert len(photo_rows(tmp_path / "pack", "turdus-migratorius")) == 3
    report = json.loads((tmp_path / "pack" / "report.json").read_text())
    assert report["gaps"]["photos"] == [], "three is the pack's full count, not a gap"


def test_a_build_told_how_many_photos_to_keep_overrides_its_definition(tmp_path):
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path), max_photos=4)

    pipeline.build_pack(continental([ROBIN]), tmp_path / "overrides.json", FakeMetadata(six_photos(ROBIN, 11)), Detector(), options)

    assert len(photo_rows(tmp_path / "pack", "turdus-migratorius")) == 4


def test_three_photos_still_give_a_hero_a_patch_reference_and_a_silhouette(tmp_path, comfy):
    """The hero is the pack's first photo, the patch is painted from the best-lit of the three, and the silhouette is
    that bird's shape: each needs one photo, and with a pinned hero and a pinned reference the three still fit."""
    from packbuilder.pack_art import ArtLock
    from packbuilder.patch_art import PatchLock
    from packbuilder.silhouettes import SilhouetteLock, SilhouetteMaker, sources

    definition = continental([ROBIN, CROW])
    metadata = FakeMetadata(six_photos(ROBIN, 11) + six_photos(CROW, 21))
    # The crow's hero is pinned as `hero-review --accept` pins it, with the photo its patch is painted from after it.
    (tmp_path / "overrides.json").write_text(json.dumps({CROW.scientific_name: {"include": [26, 22], "hero": {"pinned": 26}, "art": {"reference": 22}}}))
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))
    picker = artist(tmp_path, comfy, references={"corvus-brachyrhynchos": 22})
    silhouettes = SilhouetteMaker(pack_id=definition.id, lock=SilhouetteLock.load(tmp_path / "silhouette.lock.json"), cache_dir=tmp_path / "cache",
                                  sources=lambda: sources(PatchLock.load(tmp_path / "patch.lock.json"), ArtLock.load(tmp_path / "art.lock.json"), {}))

    pipeline.build_pack(definition, tmp_path / "overrides.json", metadata, Detector(), options, reference_picker=picker, silhouette_maker=silhouettes)

    robin, crow = photo_rows(tmp_path / "pack", "turdus-migratorius"), photo_rows(tmp_path / "pack", "corvus-brachyrhynchos")
    assert len(robin) == 3 and len(crow) == 3
    assert crow[:2] == [26, 22], "the pinned hero opens the profile and the pinned reference keeps its place"
    references = json.loads((tmp_path / "art.lock.json").read_text())["species"]
    shapes = json.loads((tmp_path / "silhouette.lock.json").read_text())["species"]
    assert references["turdus-migratorius"]["photos"] == [max(robin)], "the best-lit of the three it kept"
    assert references["corvus-brachyrhynchos"]["photos"] == [22]
    for species_id, kept in (("turdus-migratorius", robin), ("corvus-brachyrhynchos", crow)):
        assert references[species_id]["photos"][0] in kept, "the patch's photo is one the pack credits"
        assert shapes[species_id]["photos"] == references[species_id]["photos"]


# --- Some of a pack's birds (the tracer's ten of the 300) -------------------------------------------------------------

from packbuilder.sounds import CALL, SONG, SoundLock  # noqa: E402
from tests import test_sounds  # noqa: E402


def test_some_of_a_packs_birds_keep_its_order_and_their_numbers_in_it():
    whole = continental([ROBIN, CROW, CARDINAL])
    some = whole.only(["cardinalis-cardinalis", "turdus-migratorius"])

    assert [entry.id for entry in some.species] == ["turdus-migratorius", "cardinalis-cardinalis"], "in the pack's order, whatever order they were named in"
    assert some.partial and not whole.partial
    assert [some.number(entry.id) for entry in some.species] == [1, 3], "the contact sheets' numbers are the whole pack's"
    assert (some.listed, whole.listed) == (3, 3)
    with pytest.raises(KeyError, match="pica-hudsonia"):
        whole.only(["pica-hudsonia"])


class OnlyAsked(FakeMetadata):
    """Fails the test when the build asks about a bird it was not told to build."""

    def __init__(self, candidates, allowed):
        super().__init__(candidates)
        self.allowed = {entry.inat_taxon_id for entry in allowed}

    def candidates_for(self, taxon_id):
        assert taxon_id in self.allowed, f"the build asked for taxon {taxon_id}, which it was not told to build"
        return super().candidates_for(taxon_id)


def test_a_build_of_some_birds_writes_only_them_and_says_how_many_the_pack_lists(tmp_path):
    some = continental([ROBIN, CROW, CARDINAL]).only(["corvus-brachyrhynchos"])
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))

    pipeline.build_pack(some, tmp_path / "overrides.json", OnlyAsked(six_photos(CROW, 21), [CROW]), Detector(), options)

    with sqlite3.connect(tmp_path / "pack" / "pack.sqlite") as db:
        assert [row[0] for row in db.execute("SELECT id FROM species")] == ["corvus-brachyrhynchos"]
    report = json.loads((tmp_path / "pack" / "report.json").read_text())
    assert report["partial"] == {"species": 1, "listed": 3}, "nobody mistakes it for the pack"


def test_a_whole_build_does_not_call_itself_partial(tmp_path):
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))
    pipeline.build_pack(continental([CROW]), tmp_path / "overrides.json", FakeMetadata(six_photos(CROW, 21)), Detector(), options)
    assert "partial" not in json.loads((tmp_path / "pack" / "report.json").read_text())


def sound_picker(tmp_path, lock):
    source = test_sounds.FakeSource("xeno-canto", [test_sounds.sound(1, SONG), test_sounds.sound(2, CALL)])
    return test_sounds.picker(tmp_path, [(source, test_sounds.Fetches(tmp_path))], lock=lock)


def test_a_build_of_some_birds_leaves_the_others_recordings_in_the_lock(tmp_path):
    lock_path = tmp_path / "sounds.lock.json"
    lock_path.write_text(json.dumps({ROBIN.scientific_name: {SONG: test_sounds.sound(5, SONG).to_json()}}))
    some = continental([ROBIN, CROW]).only(["corvus-brachyrhynchos"])
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))

    pipeline.build_pack(some, tmp_path / "overrides.json", FakeMetadata(six_photos(CROW, 21)), Detector(), options, sounds=sound_picker(tmp_path, SoundLock(lock_path)))

    lock = json.loads(lock_path.read_text())
    assert lock[ROBIN.scientific_name][SONG]["id"] == "xc-5", "the robin was not built, so its recording stands"
    assert lock[CROW.scientific_name][SONG]["id"] == "xc-1"


def test_a_whole_build_still_drops_a_bird_that_left_the_pack_from_the_lock(tmp_path):
    lock_path = tmp_path / "sounds.lock.json"
    lock_path.write_text(json.dumps({ROBIN.scientific_name: {SONG: test_sounds.sound(5, SONG).to_json()}}))
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))

    pipeline.build_pack(continental([CROW]), tmp_path / "overrides.json", FakeMetadata(six_photos(CROW, 21)), Detector(), options, sounds=sound_picker(tmp_path, SoundLock(lock_path)))

    assert list(json.loads(lock_path.read_text())) == [CROW.scientific_name]


def test_the_sheets_of_some_birds_carry_their_numbers_in_the_whole_pack(tmp_path, comfy):
    """The maintainer reviews by the sheets' numbers, and `silhouette-review 3` means the pack's third bird: a sheet
    of the ten birds of the tracer must not number them 1 to 10."""
    from packbuilder.pack_art import ArtLock
    from packbuilder.patch_art import PatchArtist, PatchLock
    from packbuilder.silhouettes import SilhouetteLock, SilhouetteMaker, sources

    some = continental([ROBIN, CROW, CARDINAL]).only(["cardinalis-cardinalis", "corvus-brachyrhynchos"])
    metadata = FakeMetadata(six_photos(CROW, 21) + six_photos(CARDINAL, 31))
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=lit_by_id(tmp_path))
    picker = artist(tmp_path, comfy)
    patches = PatchArtist(picker.client, pack_id="us-ca-la", lock=PatchLock.load(tmp_path / "patch.lock.json"), art_lock=picker.lock, cache_dir=tmp_path / "cache")
    silhouettes = SilhouetteMaker(pack_id=some.id, lock=SilhouetteLock.load(tmp_path / "silhouette.lock.json"), cache_dir=tmp_path / "cache",
                                  sources=lambda: sources(PatchLock.load(tmp_path / "patch.lock.json"), ArtLock.load(tmp_path / "art.lock.json"), {}))

    pipeline.build_pack(some, tmp_path / "overrides.json", metadata, Detector(), options, reference_picker=picker, patch_artist=patches,
                        silhouette_maker=silhouettes, art_sheets=tmp_path / "sheets")

    for step in ("patches", "silhouettes"):
        listed = json.loads((tmp_path / "sheets" / step / "sheets.json").read_text())
        assert [(row["number"], row["species"], row["sheet"]) for row in listed] == [(2, "corvus-brachyrhynchos", "sheet-01.jpg"), (3, "cardinalis-cardinalis", "sheet-01.jpg")], step
        assert all(row["review"] == "pending" for row in listed), step


def test_the_patches_command_paints_the_birds_named_by_their_numbers_and_keeps_those_numbers(tmp_path, comfy):
    """`packbuilder patches --only 2` is the pack's second bird, on the sheet as 002."""
    from packbuilder import cli
    from tests.test_patch_art import FINCH, RAVEN, pack_art_lock

    folder = tmp_path / "us-ca-la"
    folder.mkdir()
    (folder / "pack.json").write_text(json.dumps({
        "id": "us-ca-la", "name": "Los Angeles", "region": "LA", "version": 1, "inat_place_id": 1, "bounding_box": {"south": 0, "west": 0, "north": 1, "east": 1},
        "species": [{"scientific_name": "Haemorhous mexicanus", "common_name": "House Finch", "inat_taxon_id": 199840},
                    {"scientific_name": "Corvus corax", "common_name": "Northern Raven", "inat_taxon_id": 8010}],
    }))
    lock = pack_art_lock(folder, tmp_path / "cache" / "art")
    lock.write()

    assert cli.main(["patches", str(folder), "--comfy", comfy.url, "--cache", str(tmp_path / "cache"), "--sheets", str(tmp_path / "sheets"), "--only", "2"]) == 0

    listed = json.loads((tmp_path / "sheets" / "sheets.json").read_text())
    assert [(row["number"], row["species"]) for row in listed] == [(2, RAVEN)]
    assert list(json.loads((folder / "patch.lock.json").read_text())["species"]) == [RAVEN], "the finch was not painted"
    assert cli.main(["patches", str(folder), "--comfy", comfy.url, "--cache", str(tmp_path / "cache"), "--sheets", str(tmp_path / "sheets"), "--only", "Nonesuch"]) == 1
    assert FINCH not in json.loads((folder / "patch.lock.json").read_text())["species"]


# --- Rarity calibration ----------------------------------------------------------------------------------------------

REPO = Path(__file__).resolve().parents[2]
CALIBRATION = REPO / "BirdJournal" / "BirdJournalKit" / "Sources" / "Identification" / "RarityCalibration.json"
GEOMODEL = REPO / "models" / "BirdNET+_Geomodel_V3.0.4_Global_14K_FP16.onnx"
REGIONAL = ["us-ca-bay", "us-ca-desert", "us-ca-la", "us-ca-sd", "us-fl-orlando", "us-la-south", "us-ny-nyc", "us-pnw"]


def test_the_rarity_calibration_pools_the_regional_packs_and_never_north_america():
    """Spec #206: labels mean what they meant. A continent's bounding box would read every bird over the whole of it."""
    from packbuilder.rarity import pooled

    definitions = [PackDefinition.load(folder / "pack.json") for folder in sorted(PACKS.iterdir())]
    assert [definition.id for definition in pooled(definitions)] == REGIONAL
    assert "north-america" in [definition.id for definition in definitions]


def test_the_committed_calibration_is_the_one_cards_were_labelled_under():
    committed = json.loads(CALIBRATION.read_text())
    assert committed["version"] == 1
    assert committed["thresholds"] == {"rare": 0.101, "uncommon": 0.386, "common": 0.763}
    assert committed["packs"] == ["us-ca-bay", "us-ca-desert", "us-ca-la", "us-ca-sd", "us-fl-orlando"] and committed["readings"] == 1290329


@pytest.mark.skipif(not GEOMODEL.exists(), reason="the geomodel is not downloaded (scripts/download-models.sh)")
def test_a_calibration_run_leaves_north_america_out_of_what_it_writes(tmp_path):
    from packbuilder import cli

    before = CALIBRATION.read_bytes()
    assert cli.main(["calibrate-rarity", "--version", "99", "--out", str(tmp_path / "calibration.json")]) == 0

    written = json.loads((tmp_path / "calibration.json").read_text())
    assert written["packs"] == REGIONAL
    assert CALIBRATION.read_bytes() == before, "a run told where to write never touches the committed thresholds"
