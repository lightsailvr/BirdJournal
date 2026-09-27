"""The build of one species end to end, with a fake metadata source and detector and synthetic photos on disk."""

import json

import pytest

from packbuilder import pipeline
from packbuilder.definition import SpeciesEntry
from packbuilder.detector import Detection
from packbuilder.scoring import Box
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
    """Detects a big bird in every photo except the ids listed in `blind`."""

    def __init__(self, blind=()):
        self.blind = set(blind)
        self.seen = []

    def detect(self, image):
        self.seen.append(image.size)
        return [] if image.size in self.blind else [Detection(box=BIG, score=0.9)]


@pytest.fixture
def photos_on_disk(tmp_path, monkeypatch):
    """Synthetic photos keyed by photo id; the size encodes the id so the fake detector can tell them apart."""
    specs = {}

    def fetch(candidate, cache_dir, size="original"):
        spec = specs[candidate.photo_id]
        path = tmp_path / size / f"{candidate.photo_id}.jpg"
        path.parent.mkdir(exist_ok=True)
        synthetic_photo(size=(400 + candidate.photo_id, 300), bird_box=BIG, **spec).save(path)
        return path

    monkeypatch.setattr(pipeline, "fetch_photo", fetch)
    return specs


def options(tmp_path, **kwargs):
    return pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "out", candidate_limit=kwargs.pop("limit", 10), **kwargs)


def test_species_build_filters_detects_scores_and_selects(tmp_path, photos_on_disk):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 7)]
    candidates.append(make_candidate(photo_id=7, observation_id=70, license="cc-by-sa"))
    for i in range(1, 7):
        photos_on_disk[i] = {"background": 30}
    photos_on_disk[3] = {"background": 30, "blur": 8}  # too blurred to keep
    detector = FakeDetector(blind={(400 + 5, 300)})  # photo 5 has no bird

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), detector, options(tmp_path))

    chosen = {p.candidate.photo_id for p, _ in result.photos}
    assert chosen == {1, 2, 4, 6}
    assert 3 not in chosen and 5 not in chosen and 7 not in chosen
    assert result.candidates == 7 and list(result.rejected.values()) == [1]
    assert result.detected == 5
    assert not result.gap
    assert len(detector.seen) == 6, "only license-cleared candidates reach the detector"


def test_override_include_forces_a_photo_without_a_detection(tmp_path, photos_on_disk):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 4)]
    for i in range(1, 4):
        photos_on_disk[i] = {"background": 30}
    detector = FakeDetector(blind={(400 + 2, 300)})

    result = pipeline.build_species(ENTRY, Overrides(include=[2]), FakeMetadata(candidates), detector, options(tmp_path))

    first, _ = result.photos[0]
    assert first.candidate.photo_id == 2
    assert first.box == Box(0.0, 0.0, 1.0, 1.0)


def test_candidate_limit_caps_downloads_but_not_overrides(tmp_path, photos_on_disk):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 9)]
    for i in range(1, 9):
        photos_on_disk[i] = {"background": 30}
    detector = FakeDetector()

    result = pipeline.build_species(ENTRY, Overrides(include=[8]), FakeMetadata(candidates), detector, options(tmp_path, limit=3))

    assert len(detector.seen) == 4
    assert [p.candidate.photo_id for p, _ in result.photos][0] == 8


def test_gap_when_too_few_photos(tmp_path, photos_on_disk):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos_on_disk[1] = {"background": 30}
    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path))
    assert result.gap and len(result.photos) == 1


def test_small_birds_in_the_original_are_skipped(tmp_path, photos_on_disk):
    candidates = [make_candidate(photo_id=1, observation_id=10, width=300, height=200), make_candidate(photo_id=2, observation_id=20)]
    photos_on_disk[1] = photos_on_disk[2] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path))

    assert [p.candidate.photo_id for p, _ in result.photos] == [2], "a 180-pixel bird cannot fill a 260-pixel lens crop"
    assert pipeline.bird_pixels(candidates[1], (1024, 683), BIG) == pytest.approx(0.6 * 2048)
    assert pipeline.bird_pixels(make_candidate(width=None, height=None), (1024, 683), BIG) == pytest.approx(0.6 * 2048)
