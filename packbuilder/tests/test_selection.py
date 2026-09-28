from packbuilder.selection import Overrides, ScoredPhoto, select_photos
from packbuilder.geometry import Box
from packbuilder.scoring import CropScore
from tests.conftest import make_candidate


def scored(photo_id, total, observation_id=None):
    candidate = make_candidate(photo_id=photo_id, observation_id=observation_id or photo_id * 10)
    score = CropScore(bird_area=total, background_darkness=total, sharpness=total, total=total)
    return ScoredPhoto(candidate=candidate, box=Box(0.2, 0.2, 0.8, 0.8), score=score)


def test_top_scores_win_up_to_the_maximum():
    photos = [scored(i, total=i / 10) for i in range(1, 9)]
    selection = select_photos(photos, Overrides(), minimum=3, maximum=5)
    assert [p.candidate.photo_id for p in selection.chosen] == [8, 7, 6, 5, 4]
    assert not selection.gap


def test_one_photo_per_observation():
    photos = [scored(1, 0.9, observation_id=77), scored(2, 0.8, observation_id=77), scored(3, 0.5)]
    selection = select_photos(photos, Overrides(), minimum=1, maximum=5)
    assert [p.candidate.photo_id for p in selection.chosen] == [1, 3]


def test_one_photo_uploaded_to_two_observations_is_chosen_once():
    photos = [scored(1, 0.9, observation_id=77), scored(1, 0.9, observation_id=78), scored(3, 0.5)]
    selection = select_photos(photos, Overrides(), minimum=1, maximum=5)
    assert [p.candidate.photo_id for p in selection.chosen] == [1, 3]


def test_include_override_goes_first_in_the_given_order():
    photos = [scored(i, total=i / 10) for i in range(1, 9)]
    overrides = Overrides(include=[2, 1])
    selection = select_photos(photos, overrides, minimum=3, maximum=5)
    assert [p.candidate.photo_id for p in selection.chosen] == [2, 1, 8, 7, 6]


def test_exclude_override_removes_a_bad_pick():
    photos = [scored(i, total=i / 10) for i in range(1, 9)]
    selection = select_photos(photos, Overrides(exclude=[8, 6]), minimum=3, maximum=5)
    assert [p.candidate.photo_id for p in selection.chosen] == [7, 5, 4, 3, 2]


def test_gap_is_flagged_below_the_minimum():
    selection = select_photos([scored(1, 0.5), scored(2, 0.4)], Overrides(), minimum=3, maximum=5)
    assert selection.gap
    assert len(selection.chosen) == 2


def test_overrides_parse_from_json_mapping():
    parsed = Overrides.from_mapping({"include": [5], "exclude": [6, 7]})
    assert parsed == Overrides(include=[5], exclude=[6, 7])
    assert Overrides.from_mapping({}) == Overrides()


def test_overrides_carry_description_fields():
    parsed = Overrides.from_mapping({"description": {"field_marks": "Hand-written.", "size": "16 cm", "_why": "ignored"}})
    assert parsed.description == {"field_marks": "Hand-written.", "size": "16 cm"}
    assert Overrides.from_mapping({}).description == {}
    assert Overrides.from_mapping({"trust_article": True}).trust_article and not Overrides.from_mapping({}).trust_article
    assert Overrides.from_mapping({"limit": 150}).candidate_limit == 150 and Overrides.from_mapping({}).candidate_limit is None
