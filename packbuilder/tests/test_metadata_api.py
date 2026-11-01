from packbuilder.metadata_api import _candidates_in, _extension

OBSERVATION = {
    "id": 44384152,
    "uuid": "2ba01ef4-d1ac-4078-860e-2daa138c2356",
    "quality_grade": "research",
    "user": {"login": "diego4nature", "name": "Diego Tamayo"},
    "taxon": {"id": 17013, "name": "Sayornis nigricans"},
    "photos": [
        {"id": 70367476, "license_code": "cc-by-nc", "original_dimensions": {"width": 2048, "height": 1361}, "url": "https://inaturalist-open-data.s3.amazonaws.com/photos/70367476/square.jpeg"},
        {"id": 70367477, "license_code": "cc0", "url": "https://inaturalist-open-data.s3.amazonaws.com/photos/70367477/square.jpg?1700000000"},
    ],
}


def test_api_observation_becomes_one_candidate_per_photo():
    first, second = _candidates_in(OBSERVATION)
    assert (first.photo_id, first.extension, first.license, first.position) == (70367476, "jpeg", "cc-by-nc", 0)
    assert (first.observer_name, first.observer_login) == ("Diego Tamayo", "diego4nature")
    assert first.observation_id == 44384152 and first.observation_uuid == "2ba01ef4-d1ac-4078-860e-2daa138c2356"
    assert first.taxon_id == 17013 and first.quality_grade == "research"
    assert (first.width, first.height) == (2048, 1361)
    assert first.photo_url() == "https://inaturalist-open-data.s3.amazonaws.com/photos/70367476/original.jpeg"
    assert (second.extension, second.width, second.position) == ("jpg", None, 1)


def test_extension_parsing():
    assert _extension("https://x/photos/1/square.jpeg") == "jpeg"
    assert _extension("https://x/photos/1/square.jpg?1.2") == "jpg"
    assert _extension("https://x/photos/1/square") == "jpg"
    assert _extension(None) == "jpg"


def test_missing_fields_do_not_crash():
    candidates = _candidates_in({"photos": [{"id": 5}]})
    assert candidates[0].license is None and candidates[0].taxon_id == -1 and candidates[0].quality_grade is None


def test_annotations_are_carried_and_a_dead_bird_or_a_feather_is_rejected():
    from packbuilder.candidates import Rejection, rejection_reason

    def with_annotations(*pairs):
        observation = OBSERVATION | {"annotations": [{"controlled_attribute_id": a, "controlled_value_id": v} for a, v in pairs]}
        return _candidates_in(observation)[1]  # the CC0 photo

    assert with_annotations((17, 18), (22, 24)).annotations == ((17, 18), (22, 24))
    assert rejection_reason(with_annotations((17, 18), (22, 24))) is None
    assert rejection_reason(with_annotations((17, 19))) is Rejection.NOT_A_LIVE_BIRD
    assert rejection_reason(with_annotations((22, 23))) is Rejection.NOT_A_LIVE_BIRD
    assert rejection_reason(with_annotations((17, 20), (22, 24))) is None


class FakeSession:
    """Answers every observations request with one page holding OBSERVATION, and records the query."""

    def __init__(self):
        self.params = []

    def get(self, url, params, headers, timeout):
        self.params.append(params)

        class Response:
            def raise_for_status(self):
                pass

            def json(self):
                return {"results": [OBSERVATION], "total_results": 1, "page": params["page"]}

        return Response()


def test_the_query_asks_only_for_the_license_set_and_its_cache_is_keyed_by_it(tmp_path, monkeypatch):
    from packbuilder import metadata_api

    fake = FakeSession()
    monkeypatch.setattr(metadata_api, "session", lambda: fake)

    def source(licenses):
        return metadata_api.APIMetadata((962,), tmp_path, created_before="2026-09-26", licenses=licenses, pause_seconds=0)

    open_set = frozenset({"CC0", "CC BY", "CC BY-SA"})
    source(open_set).candidates_for(17013)
    assert fake.params[-1]["photo_license"] == "cc0,cc-by,cc-by-sa"

    source(open_set).candidates_for(17013)
    assert len(fake.params) == 1, "the same set is answered from the cache"

    source(frozenset({"CC0", "CC BY", "CC BY-NC"})).candidates_for(17013)
    assert len(fake.params) == 2, "another set is another cache file"
    assert fake.params[-1]["photo_license"] == "cc0,cc-by,cc-by-nc"
    assert len(list((tmp_path / "api").glob("taxon-17013-*.json"))) == 2
