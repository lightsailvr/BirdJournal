"""Pack art (issue #57) against a stub ComfyUI: the step paints each species from its best-lit open-license photo in
the set's edition theme, writes the lock, and paints nothing on a rebuild whose lock is warm."""

import io
import json

import numpy as np
import pytest
from PIL import Image

from packbuilder.art import ArtSetting
from packbuilder.comfy import ComfyClient
from packbuilder.definition import SpeciesEntry
from packbuilder.descriptions import Description
from packbuilder.geometry import Box
from packbuilder.pack_art import ArtLock, PackArtist, lighting, pick_reference, review
from packbuilder.scoring import CropScore
from packbuilder.selection import ScoredPhoto
from packbuilder.writer import ChosenPhoto, SpeciesResult
from tests.comfy_stub import BACKGROUND, bird_on, serve
from tests.conftest import make_candidate

THEME = "citrus groves, chaparral hills and warm golden valley light"
FINCH = SpeciesEntry(scientific_name="Haemorhous mexicanus", common_name="House Finch", birdnet_label="Haemorhous mexicanus", inat_taxon_id=199840)
PHOEBE = SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013)
BUSHTIT = SpeciesEntry(scientific_name="Psaltriparus minimus", common_name="Bushtit", birdnet_label="Psaltriparus minimus", inat_taxon_id=14303)
BIRD = Box(0.3, 0.25, 0.7, 0.75)


@pytest.fixture
def comfy():
    state, server = serve()
    yield state
    server.shutdown()


def photo(tmp_path, photo_id, light=1.0, background=BACKGROUND, rank=0):
    """A chosen photo: the stub's two-tone bird on its green background, `light` scaling the bird's brightness."""
    image = Image.new("RGB", (1200, 1600), background)
    colours = tuple(tuple(min(255, int(c * light)) for c in colour) for colour in ((200, 70, 50), (150, 115, 85)))
    bird_on(image, box=(BIRD.x0, BIRD.y0, BIRD.x1, BIRD.y1), colours=colours)
    path = tmp_path / f"original-{photo_id}.jpg"
    image.save(path, quality=95)
    candidate = make_candidate(photo_id=photo_id, observation_id=photo_id * 10)
    return ChosenPhoto(scored=ScoredPhoto(candidate=candidate, box=BIRD, score=CropScore(0.5, 0.5, 0.5, 0.9 - rank * 0.1)), original=path)


def result(entry, photos):
    return SpeciesResult(entry=entry, photos=photos, gap=len(photos) < 3)


def artist(tmp_path, comfy, theme=THEME, references=None, settings=None):
    return PackArtist(
        ComfyClient(comfy.url, poll_seconds=0.01), pack_id="us-ca-la", theme=theme, lock=ArtLock.load(tmp_path / "art.lock.json"),
        cache_dir=tmp_path / "cache", references=references or {}, settings=settings or {},
    )


def test_each_species_is_painted_from_its_best_lit_photo_in_the_editions_theme_and_the_lock_pins_it(tmp_path, comfy):
    dim, bright = photo(tmp_path, 11, light=0.35, rank=0), photo(tmp_path, 12, light=1.0, rank=1)
    results = [result(FINCH, [dim, bright]), result(PHOEBE, [photo(tmp_path, 21)])]

    art = artist(tmp_path, comfy).paint(results)

    isolations = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/bird-isolate"]
    paintings = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/pack-art"]
    assert [job.names[0].rsplit("-", 1)[0] for job in isolations] == ["birdjournal/isolate-12", "birdjournal/isolate-21"], "the brighter finch photo, not the pack's first"
    assert len(paintings) == 2
    for job in paintings:
        assert THEME in job.prompt
        assert "House Finch" not in job.prompt and "Haemorhous" not in job.prompt, "a name pulls in the model's stereotype"
        # The painting's reference is the isolated bird: the photo's bird on white.
        reference = np.asarray(Image.open(io.BytesIO(job.images[0])).convert("RGB"))
        assert (reference > 235).all(axis=-1).mean() > 0.5

    lock = json.loads((tmp_path / "art.lock.json").read_text())["species"]
    finch = lock["haemorhous-mexicanus"]
    assert finch["photos"] == [12]
    assert (finch["workflow"], finch["isolate"], finch["theme"], finch["review"]) == ("pack-art@3", "bird-isolate@1", THEME, "pending")
    assert finch["seed"] == paintings[0].seed and finch["faithful"] is True
    assert set(lock) == {"haemorhous-mexicanus", "sayornis-nigricans"}
    assert art["haemorhous-mexicanus"].file.exists() and art["haemorhous-mexicanus"].photos == (12,)
    assert art["haemorhous-mexicanus"].review == "pending"


def test_a_rebuild_with_a_warm_lock_paints_nothing(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12)]), result(PHOEBE, [photo(tmp_path, 21)])]
    first = artist(tmp_path, comfy).paint(results)
    jobs = len(comfy.jobs)

    again = artist(tmp_path, comfy).paint(results)

    assert len(comfy.jobs) == jobs
    assert {k: (v.file, v.photos, v.workflow) for k, v in again.items()} == {k: (v.file, v.photos, v.workflow) for k, v in first.items()}


def test_the_locked_reference_is_kept_while_the_pack_still_has_it(tmp_path, comfy):
    artist(tmp_path, comfy).paint([result(FINCH, [photo(tmp_path, 12, light=0.6)])])
    jobs = len(comfy.jobs)

    # A brighter photo joins the pack: the reviewed painting stays.
    artist(tmp_path, comfy).paint([result(FINCH, [photo(tmp_path, 13, light=1.0), photo(tmp_path, 12, light=0.6, rank=1)])])

    assert len(comfy.jobs) == jobs


def test_each_species_is_painted_on_its_setting_sized_from_its_length_and_a_changed_setting_repaints_only_it(tmp_path, comfy):
    """Prompts v10 (the review of the Los Angeles sheets): a perched finch on a pencil-thin twig with leaves at its own
    scale, its length from its description; a phoebe whose length is pinned; the setting in the lock."""
    finch = SpeciesResult(entry=FINCH, photos=[photo(tmp_path, 12)], gap=True, description=Description("", "", "13–15 cm", "", ""))
    results = [finch, result(PHOEBE, [photo(tmp_path, 21)])]
    settings = {"haemorhous-mexicanus": ArtSetting("perch"), "sayornis-nigricans": ArtSetting("ground", length_cm=16)}
    artist(tmp_path, comfy, settings=settings).paint(results)

    finch_prompt, phoebe_prompt = (job.prompt for job in comfy.paintings if job.filename_prefix == "birdjournal/pack-art")
    assert "a slender twig no thicker than a pencil" in finch_prompt and "each leaf about half as long as the bird" in finch_prompt
    assert "does not float" in finch_prompt and "rock" not in finch_prompt
    assert "It stands on the ground" in phoebe_prompt and "twig" not in phoebe_prompt
    lock = json.loads((tmp_path / "art.lock.json").read_text())["species"]
    assert (lock["haemorhous-mexicanus"]["setting"], lock["sayornis-nigricans"]["setting"]) == ("perch", "ground")
    jobs = len(comfy.paintings)

    artist(tmp_path, comfy, settings={**settings, "sayornis-nigricans": ArtSetting("perch", length_cm=16)}).paint(results)

    repainted = [job for job in comfy.paintings[jobs:] if job.filename_prefix == "birdjournal/pack-art"]
    assert len(repainted) == 1 and "a slender twig" in repainted[0].prompt, "only the phoebe, now on a branch"


def test_a_changed_theme_repaints_and_the_painting_goes_back_to_review(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12)])]
    artist(tmp_path, comfy).paint(results)
    review(ArtLock.load(tmp_path / "art.lock.json"), approve=["haemorhous-mexicanus"])

    art = artist(tmp_path, comfy, theme="fog over the bay").paint(results)

    assert "fog over the bay" in comfy.paintings[-1].prompt
    assert art["haemorhous-mexicanus"].review == "pending"


def test_an_approved_painting_missing_from_the_cache_is_repainted_from_its_locked_seed(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12)])]
    art = artist(tmp_path, comfy).paint(results)
    review(ArtLock.load(tmp_path / "art.lock.json"), approve=["haemorhous-mexicanus"])
    seed = comfy.paintings[-1].seed
    art["haemorhous-mexicanus"].file.unlink()

    again = artist(tmp_path, comfy).paint(results)

    assert comfy.paintings[-1].seed == seed
    assert again["haemorhous-mexicanus"].review == "approved", "the same seed and inputs paint the same picture"


def test_a_rejected_painting_is_repainted_with_a_new_seed(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12)])]
    artist(tmp_path, comfy).paint(results)
    first_seed = comfy.paintings[-1].seed
    review(ArtLock.load(tmp_path / "art.lock.json"), reject=["House Finch"])

    art = artist(tmp_path, comfy).paint(results)

    assert comfy.paintings[-1].seed != first_seed
    assert art["haemorhous-mexicanus"].review == "pending"
    entry = json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    assert entry["rejected_seeds"] == [first_seed]


def test_a_gap_is_never_painted_again(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12)])]
    artist(tmp_path, comfy).paint(results)
    review(ArtLock.load(tmp_path / "art.lock.json"), gap=["haemorhous-mexicanus"], why="painted with a crest it doesn't have")
    jobs = len(comfy.jobs)

    art = artist(tmp_path, comfy).paint(results)

    assert len(comfy.jobs) == jobs
    assert art["haemorhous-mexicanus"].review == "gap" and art["haemorhous-mexicanus"].file is None
    entry = json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    assert entry["why"] == "painted with a crest it doesn't have"


def test_a_species_without_a_photo_is_painted_from_text_alone_and_named(tmp_path, comfy):
    art = artist(tmp_path, comfy).paint([result(BUSHTIT, [])])

    (job,) = comfy.paintings
    assert job.kind == "text" and job.filename_prefix == "birdjournal/pack-art-text"
    assert "Bushtit" in job.prompt and "Psaltriparus minimus" in job.prompt and THEME in job.prompt
    entry = json.loads((tmp_path / "art.lock.json").read_text())["species"]["psaltriparus-minimus"]
    assert (entry["photos"], entry["workflow"], entry["isolate"], entry["review"]) == ([], "pack-art-text@1", None, "pending")
    assert art["psaltriparus-minimus"].photos == ()


def test_an_unfaithful_painting_is_painted_again_and_marked_if_none_is_faithful(tmp_path, comfy):
    comfy.unfaithful = {"birdjournal/pack-art"}
    art = artist(tmp_path, comfy).paint([result(FINCH, [photo(tmp_path, 12)])])

    entry = json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    assert entry["faithful"] is False and entry["attempts"] == 3
    assert art["haemorhous-mexicanus"].review == "pending"


def test_a_reference_override_wins_over_the_lighting(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12, light=1.0), photo(tmp_path, 13, light=0.5, rank=1)])]

    artist(tmp_path, comfy, references={"haemorhous-mexicanus": 13}).paint(results)

    assert comfy.paintings[0].names[0].startswith("birdjournal/isolate-13-")


def test_a_reference_override_the_pack_lacks_is_reported_and_the_best_lit_photo_painted(tmp_path, comfy, caplog):
    results = [result(FINCH, [photo(tmp_path, 12, light=0.5), photo(tmp_path, 13, light=1.0, rank=1)])]
    with caplog.at_level("WARNING", logger="packbuilder"):
        artist(tmp_path, comfy, references={"haemorhous-mexicanus": 99}).paint(results)

    assert "art.reference 99 is not one of the pack's photos" in caplog.text
    assert json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]["photos"] == [13]


def test_review_approves_rejects_and_lists_gaps_by_id_or_common_name(tmp_path, comfy):
    artist(tmp_path, comfy).paint([result(FINCH, [photo(tmp_path, 12)]), result(PHOEBE, [photo(tmp_path, 21)])])
    lock = ArtLock.load(tmp_path / "art.lock.json")

    review(lock, approve_all=True)

    states = {k: v["review"] for k, v in json.loads((tmp_path / "art.lock.json").read_text())["species"].items()}
    assert states == {"haemorhous-mexicanus": "approved", "sayornis-nigricans": "approved"}
    with pytest.raises(KeyError):
        review(ArtLock.load(tmp_path / "art.lock.json"), reject=["Snowy Owl"])


def test_lighting_prefers_a_lit_bird_to_a_dim_or_backlit_one(tmp_path):
    def image_of(light, background):
        return Image.open(photo(tmp_path, 1, light=light, background=background).original)

    lit = lighting(image_of(1.0, BACKGROUND), BIRD)
    assert lit > lighting(image_of(0.35, BACKGROUND), BIRD), "dim"
    assert lit > lighting(image_of(0.6, (235, 240, 245)), BIRD), "backlit against a bright sky"


def test_pick_reference_takes_the_best_lit_photo_unless_one_is_pinned(tmp_path):
    dim, bright = photo(tmp_path, 11, light=0.35), photo(tmp_path, 12, light=1.0, rank=1)

    assert pick_reference([dim, bright]) is bright
    assert pick_reference([dim, bright], pinned=11) is dim
    assert pick_reference([dim, bright], pinned=99) is bright, "a pinned photo the pack no longer has is ignored"
    assert pick_reference([]) is None


def test_the_build_paints_then_ships_only_what_the_review_approved_and_a_rebuild_paints_nothing(tmp_path, comfy):
    import sqlite3

    from packbuilder import pipeline
    from packbuilder.definition import BoundingBox, PackDefinition
    from packbuilder.detector import Detection
    from tests.test_pipeline import FakeMetadata

    class Detector:
        def detect(self, image):
            return [Detection(box=BIRD, score=0.9)]

    def fetch(candidate, cache_dir, size):
        return photo(tmp_path, candidate.photo_id).original

    definition = PackDefinition(id="us-ca-la", name="Los Angeles", region="LA", version=1, place_ids=(1,), bounding_box=BoundingBox(0, 0, 1, 1), species=[FINCH])
    metadata = FakeMetadata([make_candidate(photo_id=photo_id, observation_id=photo_id, taxon_id=FINCH.inat_taxon_id, width=1200, height=1600) for photo_id in (12, 13)])
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=fetch, min_photos=1)
    # The stub's flat birds are too smooth for the sharpness filter; included photos skip it.
    (tmp_path / "overrides.json").write_text(json.dumps({FINCH.scientific_name: {"include": [12, 13]}}))

    def build():
        return pipeline.build_pack(definition, tmp_path / "overrides.json", metadata, Detector(), options, artist=artist(tmp_path, comfy), art_sheets=tmp_path / "sheets")

    written = build()
    assert sqlite3.connect(written.database).execute("SELECT COUNT(*) FROM pack_art").fetchone()[0] == 0, "nothing ships before the review"
    assert (tmp_path / "sheets" / "sheet-01.jpg").exists() and (tmp_path / "sheets" / "overview.jpg").exists()
    review(ArtLock.load(tmp_path / "art.lock.json"), approve_all=True)
    jobs = len(comfy.jobs)

    written = build()

    assert len(comfy.jobs) == jobs
    [(species_id, file, photos, version)] = sqlite3.connect(written.database).execute("SELECT * FROM pack_art").fetchall()
    assert (species_id, file, version) == ("haemorhous-mexicanus", "art/haemorhous-mexicanus.avif", "pack-art@3 bird-isolate@1 prompts@10")
    assert json.loads(photos)[0] in (12, 13) and (tmp_path / "pack" / file).exists()
    report = json.loads((tmp_path / "pack" / "report.json").read_text())
    assert report["gaps"]["art"] == [] and report["unreviewed"] == {"art": []}


def test_approve_all_leaves_paintings_from_text_and_unfaithful_ones_for_a_look_of_their_own(tmp_path, comfy):
    artist(tmp_path, comfy).paint([result(BUSHTIT, []), result(FINCH, [photo(tmp_path, 12)])])
    comfy.unfaithful = {"birdjournal/pack-art"}
    artist(tmp_path, comfy).paint([result(PHOEBE, [photo(tmp_path, 21)])])

    review(ArtLock.load(tmp_path / "art.lock.json"), approve_all=True)

    states = {k: v["review"] for k, v in json.loads((tmp_path / "art.lock.json").read_text())["species"].items()}
    assert states == {"psaltriparus-minimus": "pending", "haemorhous-mexicanus": "approved", "sayornis-nigricans": "pending"}


def test_rejecting_twice_before_a_repaint_skips_no_round_and_the_reason_survives_the_repaint(tmp_path, comfy):
    results = [result(FINCH, [photo(tmp_path, 12)])]
    artist(tmp_path, comfy).paint(results)
    review(ArtLock.load(tmp_path / "art.lock.json"), reject=["House Finch"], why="a crest it doesn't have")
    review(ArtLock.load(tmp_path / "art.lock.json"), reject=["House Finch"])

    artist(tmp_path, comfy).paint(results)

    entry = json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    assert len(entry["rejected_seeds"]) == 1 and entry["why"] == "a crest it doesn't have"


def test_references_isolates_each_species_best_lit_bird_and_paints_nothing(tmp_path, comfy):
    from packbuilder.patch_art import cached_isolations

    dim, bright = photo(tmp_path, 11, light=0.35, rank=0), photo(tmp_path, 12, light=1.0, rank=1)

    chosen = artist(tmp_path, comfy).isolate_references([result(FINCH, [dim, bright]), result(PHOEBE, [photo(tmp_path, 21)]), result(BUSHTIT, [])])

    assert chosen == {"haemorhous-mexicanus": 12, "sayornis-nigricans": 21}, "a species with no photo has no reference"
    assert [job.filename_prefix for job in comfy.paintings] == ["birdjournal/bird-isolate"] * 2, "no pack art is painted (#137)"
    lock = json.loads((tmp_path / "art.lock.json").read_text())["species"]
    finch = lock["haemorhous-mexicanus"]
    assert (finch["photos"], finch["isolate"], finch["review"], finch["faithful"]) == ([12], "bird-isolate@1", "reference", True)
    assert set(lock) == {"haemorhous-mexicanus", "sayornis-nigricans"}
    # The patch step finds the bird by the seed the lock records.
    assert finch["isolate_seed"] in cached_isolations(tmp_path / "cache", 12)


def test_references_keeps_a_warm_lock_and_a_painted_species_as_they_are(tmp_path, comfy):
    artist(tmp_path, comfy).paint([result(FINCH, [photo(tmp_path, 12, light=0.6)])])
    artist(tmp_path, comfy).isolate_references([result(PHOEBE, [photo(tmp_path, 21)])])
    before, jobs = (tmp_path / "art.lock.json").read_text(), len(comfy.jobs)

    # A brighter finch photo joins the pack: its reviewed reference stays, and nothing is isolated again.
    chosen = artist(tmp_path, comfy).isolate_references([result(FINCH, [photo(tmp_path, 13), photo(tmp_path, 12, light=0.6, rank=1)]), result(PHOEBE, [photo(tmp_path, 21)])])

    assert chosen == {"haemorhous-mexicanus": 12, "sayornis-nigricans": 21}
    assert len(comfy.jobs) == jobs and (tmp_path / "art.lock.json").read_text() == before


def test_references_takes_a_pin_or_another_photo_when_the_locked_one_left_the_pack(tmp_path, comfy):
    artist(tmp_path, comfy).isolate_references([result(FINCH, [photo(tmp_path, 12)]), result(PHOEBE, [photo(tmp_path, 21)])])

    chosen = artist(tmp_path, comfy, references={"haemorhous-mexicanus": 13}).isolate_references(
        [result(FINCH, [photo(tmp_path, 12), photo(tmp_path, 13, light=0.6, rank=1)]), result(PHOEBE, [photo(tmp_path, 22)])])

    assert chosen == {"haemorhous-mexicanus": 13, "sayornis-nigricans": 22}
    lock = json.loads((tmp_path / "art.lock.json").read_text())["species"]
    assert lock["haemorhous-mexicanus"]["photos"] == [13] and lock["sayornis-nigricans"]["photos"] == [22]


def test_the_build_isolates_its_reference_birds_then_patches_and_silhouettes_come_from_them(tmp_path, comfy):
    from packbuilder import pipeline
    from packbuilder.definition import BoundingBox, PackDefinition
    from packbuilder.detector import Detection
    from packbuilder.patch_art import PatchArtist, PatchLock
    from packbuilder.silhouettes import SilhouetteLock, SilhouetteMaker, sources
    from tests.test_pipeline import FakeMetadata

    class Detector:
        def detect(self, image):
            return [Detection(box=BIRD, score=0.9)]

    def fetch(candidate, cache_dir, size):
        return photo(tmp_path, candidate.photo_id).original

    definition = PackDefinition(id="us-ca-la", name="Los Angeles", region="LA", version=1, place_ids=(1,), bounding_box=BoundingBox(0, 0, 1, 1), species=[FINCH])
    metadata = FakeMetadata([make_candidate(photo_id=photo_id, observation_id=photo_id, taxon_id=FINCH.inat_taxon_id, width=1200, height=1600) for photo_id in (12, 13)])
    options = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "pack", fetch=fetch, min_photos=1)
    (tmp_path / "overrides.json").write_text(json.dumps({FINCH.scientific_name: {"include": [12, 13]}}))
    picker = artist(tmp_path, comfy)
    patches = PatchArtist(picker.client, pack_id="us-ca-la", lock=PatchLock.load(tmp_path / "patch.lock.json"), art_lock=picker.lock, cache_dir=tmp_path / "cache")
    silhouettes = SilhouetteMaker(pack_id="us-ca-la", lock=SilhouetteLock.load(tmp_path / "silhouette.lock.json"), cache_dir=tmp_path / "cache",
                                  sources=lambda: sources(PatchLock.load(tmp_path / "patch.lock.json"), ArtLock.load(tmp_path / "art.lock.json"), {}))

    pipeline.build_pack(definition, tmp_path / "overrides.json", metadata, Detector(), options, reference_picker=picker, patch_artist=patches,
                        silhouette_maker=silhouettes, art_sheets=tmp_path / "sheets")

    prefixes = [job.filename_prefix for job in comfy.paintings]
    assert prefixes[0] == "birdjournal/bird-isolate" and "birdjournal/patch-art" in prefixes and "birdjournal/pack-art" not in prefixes
    reference = json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    patch = json.loads((tmp_path / "patch.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    silhouette = json.loads((tmp_path / "silhouette.lock.json").read_text())["species"]["haemorhous-mexicanus"]
    assert patch["photos"] == reference["photos"] and patch["isolate_seed"] == reference["isolate_seed"]
    assert silhouette["photos"] == reference["photos"], "derived in the same build, from the bird it has just isolated"
    assert (tmp_path / "sheets" / "patches" / "sheet-01.jpg").exists() and (tmp_path / "sheets" / "silhouettes").is_dir()


def test_exported_references_are_isolated_from_their_crops_alone_as_the_build_would(tmp_path, comfy):
    """The Mac exports the crops; the box, which has no photos, isolates them into the same lock and cache."""
    results = [result(FINCH, [photo(tmp_path, 11, light=0.35), photo(tmp_path, 12, rank=1)]), result(PHOEBE, [photo(tmp_path, 21)]), result(BUSHTIT, [])]

    todo = artist(tmp_path, comfy).export_references(results)

    assert [(item["species"], item["common_name"], item["photo"], item["seed"]) for item in todo] == [
        ("haemorhous-mexicanus", "House Finch", 12, 49), ("sayornis-nigricans", "Black Phoebe", 21, 49)]
    assert todo[0]["url"].endswith("/12/original.jpg") and todo[0]["box"] == [BIRD.x0, BIRD.y0, BIRD.x1, BIRD.y1]
    assert not comfy.jobs and not (tmp_path / "art.lock.json").exists(), "exporting asks ComfyUI for nothing"
    assert (tmp_path / "cache" / "reference-crops" / "12.png").exists()

    assert artist(tmp_path, comfy).isolate_exported(todo) == 2
    jobs = len(comfy.jobs)
    assert artist(tmp_path, comfy).isolate_exported(todo) == 0 and len(comfy.jobs) == jobs, "a resumed run isolates nothing twice"

    # Back on the Mac the build finds every bird, and has nothing left to export.
    assert artist(tmp_path, comfy).export_references(results) == []
    assert artist(tmp_path, comfy).isolate_references(results) == {"haemorhous-mexicanus": 12, "sayornis-nigricans": 21}
    assert len(comfy.jobs) == jobs


def test_the_box_cuts_an_exported_crop_from_the_photo_it_fetches_itself(tmp_path, comfy, monkeypatch):
    """Nothing but the list crosses the tailnet: the box fetches the original and cuts the crop the Mac would have."""
    import shutil

    import packbuilder.pack_art as pack_art

    chosen = photo(tmp_path, 12)
    todo = artist(tmp_path, comfy).export_references([result(FINCH, [chosen])])
    mac_crop = Image.open(tmp_path / "cache" / "reference-crops" / "12.png").convert("RGB")
    shutil.rmtree(tmp_path / "cache")  # the box has none of the Mac's cache
    fetched = []

    def fetch(url, target):
        fetched.append(url)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(chosen.original, target)
        return target

    monkeypatch.setattr(pack_art, "fetch", fetch)
    box = artist(tmp_path, comfy)

    assert box._exported_crop(todo[0]).tobytes() == mac_crop.tobytes()
    assert box.isolate_exported(todo) == 1 and fetched[0].endswith("/12/original.jpg")
    assert json.loads((tmp_path / "art.lock.json").read_text())["species"]["haemorhous-mexicanus"]["photos"] == [12]
