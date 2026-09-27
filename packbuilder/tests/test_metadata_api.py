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
