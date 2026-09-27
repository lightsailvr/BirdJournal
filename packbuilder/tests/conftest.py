from __future__ import annotations

import numpy as np
import pytest
from PIL import Image

from packbuilder.candidates import PhotoCandidate


def make_candidate(**overrides) -> PhotoCandidate:
    """A research-grade CC BY candidate with full attribution; override fields to make it invalid."""
    fields = dict(
        photo_id=101,
        extension="jpg",
        license="CC BY",
        observer_name="Jane Birder",
        observer_login="jbirder",
        observation_id=5001,
        observation_uuid="7b5a8b1e-0000-4000-8000-000000000001",
        taxon_id=17013,
        quality_grade="research",
        width=2048,
        height=1365,
        position=0,
    )
    fields.update(overrides)
    return PhotoCandidate(**fields)


def synthetic_photo(
    size=(400, 300),
    bird_box=(0.3, 0.3, 0.7, 0.7),
    background=40,
    blur=0,
    seed=1,
) -> Image.Image:
    """A photo-like image: a textured rectangle (the bird) on a flat background.

    `bird_box` is normalized (x0, y0, x1, y1), a tuple or a `Box`; `background` is the background grey level; `blur` is a box-blur
    radius applied to the whole image (0 for sharp).
    """
    from PIL import ImageFilter

    width, height = size
    rng = np.random.default_rng(seed)
    array = np.full((height, width, 3), background, dtype=np.uint8)
    if hasattr(bird_box, "x0"):
        bird_box = (bird_box.x0, bird_box.y0, bird_box.x1, bird_box.y1)
    x0, y0, x1, y1 = (int(round(v * s)) for v, s in zip(bird_box, (width, height, width, height)))
    texture = rng.integers(60, 220, size=(y1 - y0, x1 - x0, 3), dtype=np.uint8)
    array[y0:y1, x0:x1] = texture
    image = Image.fromarray(array, "RGB")
    if blur:
        image = image.filter(ImageFilter.BoxBlur(blur))
    return image


@pytest.fixture
def candidate():
    return make_candidate()
