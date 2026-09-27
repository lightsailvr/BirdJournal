import pytest

from packbuilder.geometry import Box
from packbuilder.scoring import rank_by_score, score_crop
from tests.conftest import synthetic_photo

BIG = Box(0.2, 0.2, 0.8, 0.8)
SMALL = Box(0.45, 0.45, 0.55, 0.55)


def test_scoring_order_on_fixture_crops():
    """Big bird on a dark, sharp background first; then a big bird on a bright background; then a blurry big bird
    on a dark background; a tiny bird last."""
    ideal = score_crop(synthetic_photo(bird_box=BIG, background=30), BIG)
    bright = score_crop(synthetic_photo(bird_box=BIG, background=230), BIG)
    blurry = score_crop(synthetic_photo(bird_box=BIG, background=30, blur=6), BIG)
    tiny = score_crop(synthetic_photo(bird_box=SMALL, background=30), SMALL)

    assert ideal.background_darkness > bright.background_darkness
    assert ideal.sharpness > blurry.sharpness
    assert ideal.bird_area > tiny.bird_area

    ordered = rank_by_score({"ideal": ideal, "bright": bright, "blurry": blurry, "tiny": tiny})
    assert ordered[0] == "ideal"
    assert ordered[-1] == "tiny"
    assert set(ordered[1:3]) == {"bright", "blurry"}


def test_components_are_bounded():
    score = score_crop(synthetic_photo(bird_box=BIG, background=0), BIG)
    for value in (score.bird_area, score.background_darkness, score.sharpness, score.total):
        assert 0.0 <= value <= 1.0


def test_box_helpers():
    assert Box(0.2, 0.2, 0.8, 0.8).area == pytest.approx(0.36)
    clamped = Box(-0.1, 0.5, 1.2, 0.9).clamped()
    assert (clamped.x0, clamped.x1) == (0.0, 1.0)
