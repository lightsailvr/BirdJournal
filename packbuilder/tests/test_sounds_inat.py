"""iNaturalist observation sounds, the fallback for a species xeno-canto left without a clip."""

from packbuilder.definition import SpeciesEntry
from packbuilder.sounds import SOUND
from packbuilder.sounds_inat import INaturalistSoundSource
from packbuilder.http import Pacer
from tests.test_xenocanto import FakeClock, FakeResponse, FakeSession

ENTRY = SpeciesEntry(scientific_name="Pelecanus occidentalis", common_name="Brown Pelican", birdnet_label="Pelecanus occidentalis", inat_taxon_id=4336)


def observation(**overrides):
    data = {
        "id": 456, "user": {"name": "Jane Birder", "login": "jbirder"}, "observed_on": "2025-04-02",
        "sounds": [
            {"id": 123, "license_code": "cc-by", "file_url": "https://static.inaturalist.org/sounds/123.m4a?1700000000"},
            {"id": 124, "license_code": "cc-by-nd", "file_url": "https://static.inaturalist.org/sounds/124.mp3"},
            {"id": 125, "license_code": None, "file_url": "https://static.inaturalist.org/sounds/125.mp3"},
            {"id": 126, "license_code": "cc-by-nc", "file_url": "https://static.inaturalist.org/sounds/126.mp3"},
        ],
    }
    data.update(overrides)
    return data


def source(tmp_path, responses):
    session = FakeSession(responses)
    clock = FakeClock()
    return INaturalistSoundSource(tmp_path, session=session, pacer=Pacer(1.0, clock=clock, minimum=1.0)), session, clock


def test_open_licensed_sounds_become_untyped_candidates(tmp_path):
    inat, session, _ = source(tmp_path, [FakeResponse(payload={"results": [observation()]})])

    candidates = inat.candidates_for(ENTRY)

    assert [c.id for c in candidates] == ["inat-123"], "no-derivatives, NonCommercial and unlicensed sounds are refused"
    c = candidates[0]
    assert c.kind is None and c.license == "CC BY 4.0" and c.recordist == "Jane Birder" and c.extension == "m4a"
    assert c.source_url == "https://www.inaturalist.org/observations/456" and c.catalogue == "iNaturalist sound 123"
    params = session.calls[0][1]
    assert params["taxon_id"] == 4336 and params["sounds"] == "true" and params["quality_grade"] == "research"
    assert params["sound_license"] == "cc0,cc-by,cc-by-sa"


def test_the_search_is_cached(tmp_path):
    inat, _, _ = source(tmp_path, [FakeResponse(payload={"results": [observation()]})])
    inat.candidates_for(ENTRY)
    again, session, _ = source(tmp_path, [])
    assert [c.id for c in again.candidates_for(ENTRY)] == ["inat-123"] and session.calls == []


def test_fetch_is_paced_and_cached(tmp_path):
    inat, session, clock = source(tmp_path, [FakeResponse(payload={"results": [observation()]}), FakeResponse(body=b"audio")])
    candidate = inat.candidates_for(ENTRY)[0]
    path = inat.fetch(candidate)
    assert path.read_bytes() == b"audio" and clock.slept == [1.0]
    assert inat.fetch(candidate) == path and len(session.calls) == 2
