"""The xeno-canto source: paced and capped requests, a stop on the first rate-limit answer, an on-disk cache, and
recordings parsed into sound candidates. xeno-canto blocks clients that make too many requests per second or per hour
(their reply to the bulk-download request, issue #41), so these are the tests that keep the builder polite."""

import json

import pytest

from packbuilder.definition import SpeciesEntry
from packbuilder.xenocanto import (
    API, MissingAPIKey, Pacer, RateLimited, RequestBudgetExceeded, XenoCantoBusy, XenoCantoClient, XenoCantoError, XenoCantoSoundSource, kind_of,
    parse_recording, xeno_canto_pacer,
)

ENTRY = SpeciesEntry(scientific_name="Sayornis nigricans", common_name="Black Phoebe", birdnet_label="Sayornis nigricans", inat_taxon_id=17013)


def recording(**overrides):
    fields = {
        "id": "573469", "gen": "Sayornis", "sp": "nigricans", "en": "Black Phoebe", "rec": "Ron Overholtz", "cnt": "United States",
        "type": "call", "stage": "adult", "url": "https://xeno-canto.org/573469", "file": "https://xeno-canto.org/573469/download",
        "file-name": "XC573469-Black Phoebe.mp3", "lic": "https://creativecommons.org/licenses/by-nc-sa/4.0/", "q": "A", "length": "0:13",
        "date": "2020-07-03", "also": [], "playback-used": "no",
    }
    fields.update(overrides)
    return fields


class FakeClock:
    def __init__(self):
        self.now = 1000.0
        self.slept = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


class FakeResponse:
    def __init__(self, status=200, payload=None, body=b"", headers=None):
        self.status_code = status
        self._payload = payload
        self._body = body
        self.headers = headers or {}

    def json(self):
        return self._payload

    def raise_for_status(self):
        import requests

        if self.status_code >= 400:
            raise requests.HTTPError(f"{self.status_code} Client Error for url: https://xeno-canto.org/api/3/recordings?key=secret")

    def close(self):
        pass

    def iter_content(self, size):
        yield self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeSession:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def get(self, url, params=None, headers=None, timeout=None, stream=False, allow_redirects=True):
        self.calls.append((url, dict(params or {}), dict(headers or {})))
        return self.responses.pop(0)


def client(tmp_path, responses, clock=None, key="secret", **kwargs):
    clock = clock or FakeClock()
    session = FakeSession(responses)
    made = XenoCantoClient(cache_dir=tmp_path, api_key=key, session=session, pacer=Pacer(kwargs.pop("interval", 4.0), clock=clock), **kwargs)
    return made, session, clock


def page(recordings, pages=1):
    return FakeResponse(payload={"numRecordings": str(len(recordings)), "numPages": pages, "page": 1, "recordings": recordings})


def test_pacer_spaces_requests_by_the_interval():
    clock = FakeClock()
    pacer = Pacer(4.0, clock=clock)
    pacer.wait()
    clock.now += 1.0
    pacer.wait()
    pacer.wait()
    assert clock.slept == [3.0, 4.0], "the first request goes at once, each later one at least 4 s after the one before"


def test_the_xeno_canto_pacer_refuses_an_interval_that_could_breach_the_hourly_limit():
    with pytest.raises(ValueError):
        xeno_canto_pacer(1.0)
    assert xeno_canto_pacer().interval == 4.0


def test_search_asks_once_with_key_country_and_identifying_user_agent(tmp_path):
    xc, session, _ = client(tmp_path, [page([recording()])])

    results = xc.search('sp:"Sayornis nigricans" cnt:"United States"')

    assert [r["id"] for r in results] == ["573469"]
    url, params, headers = session.calls[0]
    assert url == API
    assert params["query"] == 'sp:"Sayornis nigricans" cnt:"United States"' and params["key"] == "secret" and params["per_page"] == 500
    assert "BirdJournal" in headers["User-Agent"]


def test_search_is_cached_so_a_rebuild_makes_no_request(tmp_path):
    xc, session, _ = client(tmp_path, [page([recording()])])
    xc.search('sp:"Sayornis nigricans"')
    again, again_session, _ = client(tmp_path, [], key=None)

    assert [r["id"] for r in again.search('sp:"Sayornis nigricans"')] == ["573469"]
    assert again_session.calls == [] and again.requests_made == 0


def test_the_cache_never_holds_the_api_key(tmp_path):
    xc, _, _ = client(tmp_path, [page([recording()])])
    xc.search('sp:"Sayornis nigricans"')
    assert not any("secret" in path.read_text() or "secret" in path.name for path in tmp_path.rglob("*") if path.is_file())


def test_only_the_first_result_page_is_fetched(tmp_path):
    """500 recordings are plenty to choose two clips from; the second page of a common species is never asked for."""
    xc, session, _ = client(tmp_path, [page([recording()], pages=7)])
    xc.search('sp:"Turdus migratorius"')
    assert len(session.calls) == 1


@pytest.mark.parametrize("status", [429, 503])
def test_a_rate_limit_answer_stops_the_build_instead_of_retrying(tmp_path, status):
    xc, session, _ = client(tmp_path, [FakeResponse(status=status, headers={"Retry-After": "600"}), page([recording()])])

    with pytest.raises(RateLimited) as raised:
        xc.search('sp:"Sayornis nigricans"')

    assert len(session.calls) == 1, "no second request after xeno-canto asks us to slow down"
    assert "600" in str(raised.value)
    with pytest.raises(RateLimited):
        xc.search('sp:"Calypte anna"')
    assert len(session.calls) == 1, "and none for the rest of the run"


def test_requests_stop_at_the_run_budget(tmp_path):
    xc, session, _ = client(tmp_path, [page([recording()]), page([recording()])], max_requests=1)
    xc.search('sp:"Sayornis nigricans"')
    with pytest.raises(RequestBudgetExceeded):
        xc.search('sp:"Calypte anna"')
    assert len(session.calls) == 1


def test_downloads_share_the_pace_and_the_budget_with_searches(tmp_path):
    xc, session, clock = client(tmp_path, [page([recording()]), FakeResponse(body=b"ID3 audio")], max_requests=2)
    xc.search('sp:"Sayornis nigricans"')
    path = xc.download("https://xeno-canto.org/573469/download", tmp_path / "xc" / "573469.mp3")

    assert path.read_bytes() == b"ID3 audio"
    assert clock.slept == [4.0]
    assert xc.requests_made == 2
    assert "key" not in session.calls[1][1], "the file URL needs no key"


def test_a_cached_download_makes_no_request(tmp_path):
    target = tmp_path / "xc" / "573469.mp3"
    target.parent.mkdir()
    target.write_bytes(b"cached")
    xc, session, _ = client(tmp_path, [], key=None)
    assert xc.download("https://xeno-canto.org/573469/download", target) == target
    assert session.calls == []


def test_a_missing_key_fails_only_when_a_request_is_needed(tmp_path):
    xc, session, _ = client(tmp_path, [], key=None)
    with pytest.raises(MissingAPIKey):
        xc.search('sp:"Sayornis nigricans"')
    assert session.calls == []


@pytest.mark.parametrize(
    "type_field, expected",
    [("song", "song"), ("dawn song", "song"), ("flight song", "song"), ("call", "call"), ("flight call", "call"), ("alarm call", "call"),
     ("call, song", None), ("subsong", None), ("begging call", None), ("drumming", None), ("", None)],
)
def test_kind_of_a_recording(type_field, expected):
    assert kind_of(type_field) == expected


def test_parse_recording_carries_attribution_and_ranking_fields():
    candidate = parse_recording(recording(type="song", also=["Calypte anna"], length="1:05", q="B"))

    assert candidate.id == "xc-573469" and candidate.catalogue == "XC573469"
    assert candidate.kind == "song" and candidate.quality == "B" and candidate.length_seconds == 65
    assert candidate.license == "CC BY-NC-SA 4.0" and candidate.recordist == "Ron Overholtz"
    assert candidate.source_url == "https://xeno-canto.org/573469" and candidate.file_url == "https://xeno-canto.org/573469/download"
    assert candidate.extension == "mp3" and candidate.background_species == 1 and candidate.recorded == "2020-07-03"


def test_parse_recording_refuses_what_the_pack_cannot_use():
    assert parse_recording(recording(lic="https://creativecommons.org/licenses/by-nc-nd/4.0/")) is None, "no derivatives"
    assert parse_recording(recording(rec="")) is None, "no recordist to credit"
    assert parse_recording(recording(stage="juvenile")) is None
    assert parse_recording(recording(**{"playback-used": "yes"})) is None, "a bird answering playback is not its natural voice"


def test_source_asks_worldwide_when_the_country_has_no_usable_song_or_call(tmp_path):
    unusable = [recording(id="1", type="Diving, wing flaps"), recording(id="2", lic="https://creativecommons.org/licenses/by-nc-nd/2.5/")]
    xc, session, _ = client(tmp_path, [page(unusable), page([recording(id="3", cnt="Mexico")])])
    candidates = XenoCantoSoundSource(xc, country="United States").candidates_for(ENTRY)
    assert len(session.calls) == 2 and [c.id for c in candidates] == ["xc-1", "xc-3"]


def test_source_does_not_ask_worldwide_when_the_country_has_a_song_or_call(tmp_path):
    xc, session, _ = client(tmp_path, [page([recording()])])
    XenoCantoSoundSource(xc, country="United States").candidates_for(ENTRY)
    assert len(session.calls) == 1


def test_source_queries_the_pack_country_first_then_worldwide_only_when_empty(tmp_path):
    xc, session, _ = client(tmp_path, [page([]), page([recording(cnt="Mexico")])])
    source = XenoCantoSoundSource(xc, country="United States")

    candidates = source.candidates_for(ENTRY)

    assert [c.id for c in candidates] == ["xc-573469"]
    assert [call[1]["query"] for call in session.calls] == ['sp:"Sayornis nigricans" cnt:"United States"', 'sp:"Sayornis nigricans"']


def test_source_uses_the_override_name_when_xeno_canto_names_the_species_differently(tmp_path):
    xc, session, _ = client(tmp_path, [page([recording()])])
    XenoCantoSoundSource(xc, country="United States", names={"Sayornis nigricans": "Sayornis nigricanus"}).candidates_for(ENTRY)
    assert session.calls[0][1]["query"] == 'sp:"Sayornis nigricanus" cnt:"United States"'


def test_a_second_build_cannot_reach_xeno_canto_while_another_holds_it(tmp_path):
    """The pacer is per process: two builds side by side would double the rate, so the first network request takes a
    lock on the shared cache that a second client cannot get."""
    first, _, _ = client(tmp_path, [page([recording()])])
    first.search('sp:"Sayornis nigricans"')
    second, session, _ = client(tmp_path, [page([recording()])])

    with pytest.raises(XenoCantoBusy):
        second.search('sp:"Calypte anna"')
    assert session.calls == []
    first.close()
    second.search('sp:"Calypte anna"')
    assert len(session.calls) == 1


def test_a_server_error_is_retried_through_the_pacer_and_counted(tmp_path):
    """A retry is a request like any other: paced, counted against the budget, never immediate."""
    xc, session, clock = client(tmp_path, [FakeResponse(status=502), page([recording()])], max_requests=5)

    assert [r["id"] for r in xc.search('sp:"Sayornis nigricans"')] == ["573469"]
    assert len(session.calls) == 2 and xc.requests_made == 2
    assert sum(clock.slept) >= 10.0, "the retry waited the backoff, which is longer than the pacer interval"


def test_a_dropped_connection_is_retried_a_bounded_number_of_times(tmp_path):
    import requests

    class Dropping(FakeSession):
        def get(self, *args, **kwargs):
            self.calls.append(args)
            raise requests.ConnectionError("reset")

    clock = FakeClock()
    xc = XenoCantoClient(cache_dir=tmp_path, api_key="secret", session=Dropping([]), pacer=Pacer(4.0, clock=clock))

    with pytest.raises(XenoCantoError):
        xc.search('sp:"Sayornis nigricans"')
    assert xc.requests_made == 3, "three attempts in all, each paced and counted"


def test_the_session_itself_never_retries():
    from packbuilder.xenocanto import polite_session

    adapter = polite_session().get_adapter("https://xeno-canto.org")
    assert adapter.max_retries.total == 0


def test_redirects_are_followed_one_paced_counted_hop_at_a_time(tmp_path):
    """The file URL may redirect to the file itself: each hop is a request to xeno-canto, so each is paced and counted."""
    xc, session, clock = client(
        tmp_path, [FakeResponse(status=302, headers={"Location": "/sounds/uploaded/ABC/XC1.mp3"}), FakeResponse(body=b"ID3")],
    )

    path = xc.download("https://xeno-canto.org/1/download", tmp_path / "xc" / "1.mp3")

    assert path.read_bytes() == b"ID3"
    assert [call[0] for call in session.calls] == ["https://xeno-canto.org/1/download", "https://xeno-canto.org/sounds/uploaded/ABC/XC1.mp3"]
    assert xc.requests_made == 2 and clock.slept == [4.0]


def test_errors_never_carry_the_api_key(tmp_path):
    import requests

    class Failing(FakeSession):
        def get(self, url, params=None, **kwargs):
            raise requests.ConnectionError(f"Max retries exceeded with url: /api/3/recordings?query=x&key={params['key']}")

    xc = XenoCantoClient(cache_dir=tmp_path, api_key="secret", session=Failing([]), pacer=Pacer(4.0, clock=FakeClock()))
    with pytest.raises(XenoCantoError) as raised:
        xc.search('sp:"Sayornis nigricans"')
    assert "secret" not in str(raised.value) and raised.value.__cause__ is None and raised.value.__suppress_context__


def test_an_http_error_answer_does_not_carry_the_key(tmp_path):
    xc, _, _ = client(tmp_path, [FakeResponse(status=404)])
    with pytest.raises(XenoCantoError) as raised:
        xc.search('sp:"Sayornis nigricans"')
    assert "secret" not in str(raised.value)
