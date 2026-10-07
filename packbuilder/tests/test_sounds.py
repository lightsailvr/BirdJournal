"""Choosing a species' song and call through the seams: sources, fetchers, the clip maker and the BirdNET check."""

import json
from dataclasses import replace

from packbuilder.definition import SpeciesEntry
from packbuilder.sounds import CALL, SONG, SOUND, Clip, SoundCandidate, SoundLock, SoundOverrides, SoundPicker, rank_sounds

ENTRY = SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013)


def sound(number, kind=SONG, source="xeno-canto", **fields):
    defaults = dict(
        id=f"xc-{number}" if source == "xeno-canto" else f"inat-{number}", source=source, catalogue=f"XC{number}", kind=kind,
        file_url=f"https://xeno-canto.org/{number}/download", extension="mp3", recordist="Jane Birder", license="CC BY-NC-SA 4.0",
        source_url=f"https://xeno-canto.org/{number}", quality="A", length_seconds=20.0, recorded="2024-05-01", country="United States",
    )
    defaults.update(fields)
    return SoundCandidate(**defaults)


class FakeSource:
    def __init__(self, name, candidates):
        self.name = name
        self.candidates = candidates
        self.asked = 0

    def candidates_for(self, entry):
        self.asked += 1
        return list(self.candidates)


class Fetches:
    def __init__(self, tmp_path, missing=()):
        self.root = tmp_path / "files"
        self.missing = set(missing)
        self.fetched = []

    def __call__(self, candidate):
        self.fetched.append(candidate.id)
        if candidate.id in self.missing:
            return None
        self.root.mkdir(exist_ok=True)
        path = self.root / f"{candidate.id}.mp3"
        path.write_text(candidate.id)
        return path


class FakeClips:
    def make(self, source, target):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source.read_text())
        return Clip(path=target, duration_ms=8000)


class FakeCheck:
    """Passes every clip except those whose source id is in `heard_as` (mapped to the species BirdNET hears)."""

    def __init__(self, heard_as=None):
        self.heard_as = heard_as or {}

    def check(self, clip, scientific_name):
        top = self.heard_as.get(clip.read_text(), scientific_name)
        return top == scientific_name, 0.8 if top == scientific_name else 0.1, top


def with_fetch(source, fetch):
    source.fetch = fetch
    return source


def picker(tmp_path, sources, check=None, lock=None, **kwargs):
    """`sources` are (FakeSource, Fetches) pairs: the fetcher becomes the source's `fetch`."""
    return SoundPicker(sources=[with_fetch(source, fetch) for source, fetch in sources], clips=FakeClips(), check=check or FakeCheck(), clip_dir=tmp_path / "clips", lock=lock or SoundLock(None), country="United States", **kwargs)


def test_ranking_prefers_graded_open_short_mp3_recordings_from_the_country():
    best = sound(1)
    candidates = [
        sound(2, quality="C", license="CC BY-SA 4.0"),
        sound(3, license="CC BY-SA 4.0", quality="B"),
        sound(4, extension="wav"),
        sound(5, length_seconds=240.0),
        sound(6, background_species=2),
        sound(7, country="Mexico"),
        sound(8, recorded="2010-01-01"),
        best,
        sound(9, kind=CALL),
    ]
    ranked = [c.id for c in rank_sounds(candidates, SONG, country="United States")]
    assert ranked[0] == "xc-3", "an open license beats a better grade within A and B"
    assert ranked[1:] == ["xc-1", "xc-8", "xc-7", "xc-6", "xc-5", "xc-4", "xc-2"]
    assert "xc-9" not in ranked


def test_picks_a_song_and_a_call_from_the_first_source(tmp_path):
    xc = FakeSource("xeno-canto", [sound(1, SONG), sound(2, CALL), sound(3, SONG, quality="B")])
    inat = FakeSource("inaturalist", [sound(9, None, source="inaturalist")])
    fetch = Fetches(tmp_path)

    result = picker(tmp_path, [(xc, fetch), (inat, fetch)]).pick(ENTRY)

    assert [(s.kind, s.id) for s in result.sounds] == [(SONG, "xc-1"), (CALL, "xc-2")]
    assert fetch.fetched == ["xc-1", "xc-2"], "only the chosen files are downloaded"
    assert inat.asked == 0, "iNaturalist is not asked when xeno-canto covered the species"
    assert not result.gap and result.rejections == []


def test_a_clip_birdnet_does_not_hear_as_the_species_falls_through_to_the_next(tmp_path):
    xc = FakeSource("xeno-canto", [sound(1, SONG), sound(2, SONG, quality="B"), sound(3, CALL)])
    result = picker(tmp_path, [(xc, Fetches(tmp_path))], check=FakeCheck({"xc-1": "Calypte anna"})).pick(ENTRY)

    assert [s.id for s in result.sounds] == ["xc-2", "xc-3"]
    assert result.rejections == [{"id": "xc-1", "kind": SONG, "reason": "BirdNET heard Calypte anna"}]


def test_tries_are_capped_per_kind_to_bound_the_downloads(tmp_path):
    xc = FakeSource("xeno-canto", [sound(n, SONG) for n in range(1, 10)])
    fetch = Fetches(tmp_path)
    result = picker(tmp_path, [(xc, fetch)], check=FakeCheck({f"xc-{n}": "Calypte anna" for n in range(1, 10)}), max_tries=3).pick(ENTRY)

    assert len(fetch.fetched) == 3
    assert result.gap


def test_inaturalist_fills_a_species_xeno_canto_left_without_any_clip(tmp_path):
    xc = FakeSource("xeno-canto", [])
    inat = FakeSource("inaturalist", [sound(9, None, source="inaturalist")])
    result = picker(tmp_path, [(xc, Fetches(tmp_path)), (inat, Fetches(tmp_path))]).pick(ENTRY)

    assert [(s.kind, s.id) for s in result.sounds] == [(SOUND, "inat-9")]


def test_inaturalist_is_not_asked_when_xeno_canto_gave_one_kind(tmp_path):
    xc = FakeSource("xeno-canto", [sound(1, CALL)])
    inat = FakeSource("inaturalist", [sound(9, None, source="inaturalist")])
    result = picker(tmp_path, [(xc, Fetches(tmp_path)), (inat, Fetches(tmp_path))]).pick(ENTRY)

    assert [s.kind for s in result.sounds] == [CALL]
    assert inat.asked == 0


def test_overrides_pin_and_exclude(tmp_path):
    xc = FakeSource("xeno-canto", [sound(1, SONG), sound(2, SONG, quality="C"), sound(3, CALL)])
    result = picker(tmp_path, [(xc, Fetches(tmp_path))]).pick(ENTRY, SoundOverrides(song="xc-2", exclude=frozenset({"xc-3"})))

    assert [s.id for s in result.sounds] == ["xc-2"]


def test_an_unavailable_file_is_a_rejection(tmp_path):
    xc = FakeSource("xeno-canto", [sound(1, SONG), sound(2, SONG, quality="B")])
    result = picker(tmp_path, [(xc, Fetches(tmp_path, missing={"xc-1"}))]).pick(ENTRY)
    assert [s.id for s in result.sounds] == ["xc-2"]
    assert result.rejections[0]["reason"] == "unavailable"


def test_a_locked_recording_is_used_without_a_search(tmp_path):
    lock_path = tmp_path / "sounds.lock.json"
    lock_path.write_text(json.dumps({"Sayornis nigricans": {SONG: sound(5, SONG).to_json(), CALL: sound(6, CALL).to_json()}}))
    xc = FakeSource("xeno-canto", [sound(1, SONG), sound(2, CALL)])
    fetch = Fetches(tmp_path)
    lock = SoundLock(lock_path)

    result = picker(tmp_path, [(xc, fetch)], lock=lock).pick(ENTRY)
    lock.write()

    assert [s.id for s in result.sounds] == ["xc-5", "xc-6"]
    assert xc.asked == 0 and fetch.fetched == ["xc-5", "xc-6"]
    assert json.loads(lock_path.read_text())["Sayornis nigricans"][SONG]["id"] == "xc-5"


def test_a_locked_recording_that_fails_is_replaced_by_a_search_and_the_lock_updated(tmp_path):
    lock_path = tmp_path / "sounds.lock.json"
    lock_path.write_text(json.dumps({"Sayornis nigricans": {SONG: sound(5, SONG).to_json()}}))
    xc = FakeSource("xeno-canto", [sound(1, SONG), sound(2, CALL)])
    lock = SoundLock(lock_path)

    result = picker(tmp_path, [(xc, Fetches(tmp_path, missing={"xc-5"}))], lock=lock).pick(ENTRY)
    lock.write()

    assert [s.id for s in result.sounds] == ["xc-1", "xc-2"]
    assert json.loads(lock_path.read_text())["Sayornis nigricans"] == {SONG: sound(1, SONG).to_json(), CALL: sound(2, CALL).to_json()}


def test_candidate_round_trips_through_the_lock_json():
    candidate = sound(1, background_species=2)
    assert SoundCandidate.from_json(json.loads(json.dumps(candidate.to_json()))) == candidate


def test_an_override_accepts_the_sister_species_birdnet_files_the_bird_under(tmp_path):
    """BirdNET+ carries both halves of a split (Numenius hudsonicus and N. phaeopus) and hears an American Whimbrel's
    call as the Eurasian one; the override says that answer is right for this species."""
    xc = FakeSource("xeno-canto", [sound(1, CALL)])
    check = FakeCheck({"xc-1": "Numenius phaeopus"})

    refused = picker(tmp_path, [(xc, Fetches(tmp_path))], check=check).pick(ENTRY)
    accepted = picker(tmp_path, [(xc, Fetches(tmp_path))], check=check).pick(ENTRY, SoundOverrides.from_mapping({"accept": ["Numenius phaeopus"]}))

    assert refused.gap
    assert [s.id for s in accepted.sounds] == ["xc-1"]
