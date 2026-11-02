"""The content filter's real model (ADR-0007), when it has been downloaded (scripts/download-filter.sh); skipped
otherwise. Only the benign side is tested here: no explicit image is committed to this public repository."""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from PIL import Image

from artworker.content_filter import NsfwFilter
from tests.conftest import comfy_stub

MODEL = Path(os.environ.get("ART_FILTER_MODEL", Path(__file__).resolve().parents[1] / "models" / "nsfw_image_detection.onnx"))
LA_REFERENCES = Path(__file__).resolve().parents[2] / "build" / "art-references" / "us-ca-la"

pytestmark = pytest.mark.skipif(not MODEL.exists(), reason="the content filter isn't downloaded (artworker/scripts/download-filter.sh)")


@pytest.fixture(scope="module")
def nsfw() -> NsfwFilter:
    return NsfwFilter(MODEL)


def test_a_bird_on_a_card_passes(nsfw: NsfwFilter) -> None:
    card = comfy_stub.bird_on(Image.new("RGB", (864, 1152), (230, 220, 190)))
    assert nsfw.nsfw_probability(card) < 0.1
    assert nsfw.allows(card)


@pytest.mark.skipif(not LA_REFERENCES.exists(), reason="no exported Los Angeles reference birds (packbuilder art-references)")
def test_real_reference_birds_pass(nsfw: NsfwFilter) -> None:
    birds = sorted(LA_REFERENCES.glob("*.png"))[:12]
    scores = {bird.stem: nsfw.nsfw_probability(Image.open(bird)) for bird in birds}
    assert all(score < 0.5 for score in scores.values()), scores
