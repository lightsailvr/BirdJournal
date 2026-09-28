"""The build of one species end to end, through its seams: a metadata source, a detector and a photo fetcher."""

import threading

import pytest

from packbuilder import pipeline
from packbuilder.descriptions import Description
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


def test_override_limit_widens_the_shortlist_for_one_species(tmp_path, photos):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 9)]
    for i in range(1, 9):
        photos.specs[i] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides.from_mapping({"limit": 8}), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos, candidate_limit=3))

    assert len(chosen_ids(result)) == 5, "the override's limit, not the build's, bounds the shortlist"


def test_originals_smaller_than_the_lens_crop_are_skipped(tmp_path, photos):
    """A 500 × 400 original would be upscaled into the 552 × 368 card however big the bird is in it."""
    candidates = [make_candidate(photo_id=1, observation_id=10, width=500, height=400), make_candidate(photo_id=2, observation_id=20, width=600, height=300), make_candidate(photo_id=3, observation_id=30)]
    photos.specs[1] = photos.specs[2] = photos.specs[3] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))

    assert chosen_ids(result) == [3]
    forced = pipeline.build_species(ENTRY, Overrides(include=[1]), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))
    assert chosen_ids(forced) == [1, 3], "an override still forces a small original in"


def test_gap_when_too_few_photos(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos.specs[1] = {"background": 30}
    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))
    assert result.gap and len(result.photos) == 1


def test_small_birds_in_the_original_are_skipped(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10, width=300, height=200), make_candidate(photo_id=2, observation_id=20)]
    photos.specs[1] = photos.specs[2] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))

    assert chosen_ids(result) == [2], "a 180-pixel bird cannot fill the lens crop's 368-pixel height"
    assert pipeline.bird_pixels(candidates[1], (1024, 683), BIG) == pytest.approx(0.6 * 2048)
    assert pipeline.bird_pixels(make_candidate(width=None, height=None), (1024, 683), BIG) == pytest.approx(0.6 * 2048)


class FakeDescriptions:
    def __init__(self, by_name, trusted=()):
        self.by_name = by_name
        self.trusted = set(trusted)

    def describe(self, entry, trust_article=False):
        if entry.scientific_name in self.trusted and not trust_article:
            return None
        return self.by_name.get(entry.scientific_name)


PHOEBE = Description(summary="A black flycatcher.", field_marks="Black with a white belly.", size="16 cm", habitat="water, coast", source="https://en.wikipedia.org/w/index.php?title=Black_phoebe&oldid=1")


def test_species_carries_its_description(tmp_path, photos):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 4)]
    for i in range(1, 4):
        photos.specs[i] = {"background": 30}

    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos), descriptions=FakeDescriptions({ENTRY.scientific_name: PHOEBE}))

    assert result.description == PHOEBE


def test_species_without_an_article_has_no_description(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos.specs[1] = {"background": 30}
    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos), descriptions=FakeDescriptions({}))
    assert result.description is None


def test_override_description_fields_replace_the_derived_ones(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos.specs[1] = {"background": 30}
    overrides = Overrides.from_mapping({"description": {"field_marks": "Sooty black, clean white belly; wags its tail.", "habitat": "streams, parks"}})

    result = pipeline.build_species(ENTRY, overrides, FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos), descriptions=FakeDescriptions({ENTRY.scientific_name: PHOEBE}))

    assert result.description.field_marks == "Sooty black, clean white belly; wags its tail."
    assert result.description.habitat == "streams, parks"
    assert result.description.size == "16 cm" and result.description.source == PHOEBE.source


def test_override_trusts_an_article_the_guard_would_refuse(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos.specs[1] = {"background": 30}
    source = FakeDescriptions({ENTRY.scientific_name: PHOEBE}, trusted=[ENTRY.scientific_name])

    refused = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos), descriptions=source)
    trusted = pipeline.build_species(ENTRY, Overrides.from_mapping({"trust_article": True}), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos), descriptions=source)

    assert refused.description is None and trusted.description == PHOEBE


def test_override_description_stands_alone_without_an_article(tmp_path, photos):
    candidates = [make_candidate(photo_id=1, observation_id=10)]
    photos.specs[1] = {"background": 30}
    overrides = Overrides.from_mapping({"description": {"field_marks": "Written by hand."}})

    result = pipeline.build_species(ENTRY, overrides, FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos), descriptions=FakeDescriptions({}))

    assert result.description == Description(summary="", field_marks="Written by hand.", size="", habitat="", source="")


def test_large_photos_are_fetched_in_parallel_before_detection(tmp_path, photos):
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 7)]
    for i in range(1, 7):
        photos.specs[i] = {"background": 30}
    threads = set()
    inner = photos.fetch

    def fetch(candidate, cache_dir, size):
        threads.add(threading.get_ident())
        return inner(candidate, cache_dir, size)

    opts = pipeline.BuildOptions(cache_dir=tmp_path / "cache", out_dir=tmp_path / "out", fetch=fetch, download_workers=3)
    result = pipeline.build_species(ENTRY, Overrides(), FakeMetadata(candidates), FakeDetector(), opts)

    assert len(chosen_ids(result)) == 5
    assert len(threads) > 1, "the large renditions were fetched from a pool"


def test_a_photo_of_two_species_is_chosen_for_neither(tmp_path, photos):
    # Photo 3 is attached to an observation of each species (one picture of an avocet among pintails).
    other = SpeciesEntry(scientific_name="Anas acuta", common_name="Northern Pintail", birdnet_label="Anas acuta", inat_taxon_id=1)
    candidates = [make_candidate(photo_id=i, observation_id=i * 10) for i in range(1, 6)]
    candidates.append(make_candidate(photo_id=3, observation_id=99, taxon_id=1))
    for i in range(1, 6):
        photos.specs[i] = {"background": 30}
    metadata = FakeMetadata(candidates)

    shared = pipeline.shared_photo_ids([ENTRY, other], metadata)
    result = pipeline.build_species(ENTRY, Overrides(), metadata, FakeDetector(), options(tmp_path, photos), shared=shared)

    assert shared == {3}
    assert 3 not in chosen_ids(result)
    assert sorted(chosen_ids(result)) == [1, 2, 4, 5]


def test_an_excluded_photo_takes_the_rest_of_its_observation_with_it(tmp_path, photos):
    # Photos 1 and 2 are one observation (an injured dove on a blanket, twice); excluding 1 drops 2 as well.
    candidates = [make_candidate(photo_id=1, observation_id=10), make_candidate(photo_id=2, observation_id=10)]
    candidates += [make_candidate(photo_id=i, observation_id=i * 10) for i in range(3, 7)]
    for i in range(1, 7):
        photos.specs[i] = {"background": 30}
    result = pipeline.build_species(ENTRY, Overrides(exclude=[1]), FakeMetadata(candidates), FakeDetector(), options(tmp_path, photos))
    assert sorted(chosen_ids(result)) == [3, 4, 5, 6]
