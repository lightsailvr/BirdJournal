from packbuilder.candidates import Rejection, attribution_name, filter_candidates, rejection_reason
from tests.conftest import make_candidate


def test_valid_candidate_is_kept(candidate):
    assert rejection_reason(candidate) is None
    assert filter_candidates([candidate]).kept == [candidate]


def test_disallowed_licenses_are_rejected():
    for raw in ["cc-by-sa", "cc-by-nd", "cc-by-nc-sa", "cc-by-nc-nd", "", None]:
        assert rejection_reason(make_candidate(license=raw)) == Rejection.LICENSE


def test_non_research_grade_is_rejected():
    assert rejection_reason(make_candidate(quality_grade="needs_id")) == Rejection.QUALITY
    assert rejection_reason(make_candidate(quality_grade="casual")) == Rejection.QUALITY


def test_missing_attribution_is_rejected():
    assert rejection_reason(make_candidate(observer_name=None, observer_login=None)) == Rejection.ATTRIBUTION
    assert rejection_reason(make_candidate(observation_id=None, observation_uuid=None)) == Rejection.ATTRIBUTION


def test_login_stands_in_for_a_missing_name():
    assert attribution_name(make_candidate(observer_name=None)) == "jbirder"
    assert attribution_name(make_candidate(observer_name="  ")) == "jbirder"
    assert attribution_name(make_candidate()) == "Jane Birder"


def test_filter_reports_counts():
    result = filter_candidates([
        make_candidate(photo_id=1),
        make_candidate(photo_id=2, license="cc-by-sa"),
        make_candidate(photo_id=3, quality_grade="casual"),
    ])
    assert [c.photo_id for c in result.kept] == [1]
    assert result.rejected == {Rejection.LICENSE: 1, Rejection.QUALITY: 1}


def test_source_url_points_at_the_observation():
    assert make_candidate(observation_id=5001).source_url == "https://www.inaturalist.org/observations/5001"
    uuid_only = make_candidate(observation_id=None, observation_uuid="7b5a8b1e-0000-4000-8000-000000000001")
    assert uuid_only.source_url == "https://www.inaturalist.org/observations/7b5a8b1e-0000-4000-8000-000000000001"


def test_photo_url_is_the_open_data_bucket():
    assert make_candidate(photo_id=70367476, extension="jpeg").photo_url() == (
        "https://inaturalist-open-data.s3.amazonaws.com/photos/70367476/original.jpeg"
    )
