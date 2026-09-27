"""The build of one species end to end, through its seams: a metadata source, a detector and a photo fetcher."""

import pytest

from packbuilder import pipeline
from packbuilder.definition import SpeciesEntry
from packbuilder.detector import Detection
from packbuilder.geometry import Box
from packbuilder.selection import Overrides
from tests.conftest import make_candidate, synthetic_photo

ENTRY = SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013)
BIG = Box(0.2, 0.2, 0.8, 0.8)


class FakeMetadata:
    def __init__(self, candidates):
        self.candidates = candidates

    def candidates_for(self, taxon_id):
        return [c for c in self.candidates if c.taxon_id == taxon_id]


class FakeDetector:
    """Detects a big bird in every photo except those whose width is in `blind` (the fetcher encodes the photo id
    in the width)."""

    def __init__(self, blind=()):
        self.blind = {400 + photo_id for photo_id in blind}

    def detect(self, image):
        return [] if image.size[0] in self.blind else [Detection(box=BIG, score=0.9)]


class Photos:
    """Synthetic photos written on demand: `specs[photo_id]` are `synthetic_photo` keyword arguments."""

    def __init__(self, root):
        self.root = root
        self.specs = {}

    def fetch(self, candidate, cache_dir, size):
        path = self.root / size / f"{candidate.photo_id}.jpg"
        path.parent.mkdir(exist_ok=True, parents=True)
        synthetic_photo(size=(400 + candidate.photo_id, 300), bird_box=BIG, **self.specs[candidate.photo_id]).save(path)
        return path


@pytest.fixture
def photos(tmp_path):
    return Photos(tmp_path / "photos")


def options(tmp_path, photos, **kwargs):
    return pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "out", fetch=photos.fetch, **kwargs)


def chosen_ids(result):
    return [chosen.candidate.photo_id for chosen in result.photos]


def test_species_build_filters_detects_scores_and_selects(tmp_path, photos):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 7)]
    candidates.append(make_candidate(photo_id=7, observation_id=70, license="cc-by-sa"))
    for i in range(1, 7):
        photos.specs[i] = {"background": 30}
    photos.specs[3] = {"background": 30, "blur": 8}  # too blurred to keep

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(blind=[5]), options(tmp_path, photos))

    assert set(chosen_ids(result)) == {1, 2, 4, 6}, "3 is blurred, 5 has no bird, 7 is share-alike"
    assert result.candidates == 7 and result.rejected == {"license": 1}
    assert result.detected == 5
    assert not result.gap


def test_override_include_forces_a_photo_without_a_detection(tmp_path, photos):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 4)]
    for i in range(1, 4):
        photos.specs[i] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(include=[2]), FakeMetadata(candidates), FakeDetector(blind=[2]), options(tmp_path, photos))

    assert chosen_ids(result)[0] == 2
    assert result.photos[0].scored.box == pipeline.FULL_FRAME


def test_candidate_limit_caps_the_shortlist_but_not_overrides(tmp_path, photos):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 9)]
    for i in range(1, 9):
        photos.specs[i] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(include=[8]), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos, candidate_limit=3))

    assert chosen_ids(result)[0] == 8
    assert set(chosen_ids(result)) == {8, 1, 2, 3}, "only the first three cleared candidates were considered"


def test_gap_when_too_few_photos(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos.specs[1] = {"background": 30}
    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))
    assert result.gap and len(result.photos) == 1


def test_small_birds_in_the_original_are_skipped(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10, width=300, height=200), make_candidate(photo_id=2, observation_id=20)]
    photos.specs[1] = photos.specs[2] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))

    assert chosen_ids(result) == [2], "a 180-pixel bird cannot fill a 260-pixel lens crop"
    assert pipeline.bird_pixels(candidates[1], (1024, 683), BIG) == pytest.approx(0.6 * 2048)
    assert pipeline.bird_pixels(make_candidate(width=None, height=None), (1024, 683), BIG) == pytest.approx(0.6 * 2048)
