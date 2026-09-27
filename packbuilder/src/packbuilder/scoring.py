"""Scores a bird crop for the lens: bird area, background darkness and sharpness (DECISIONS.md, "Species pack")."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from PIL import Image

from packbuilder.crops import lens_crop_box
from packbuilder.geometry import Box

__all__ = ["Box", "CropScore", "score_crop", "rank_by_score", "laplacian_variance"]

# Weights of the three components in the total; they sum to one.
AREA_WEIGHT = 0.45
DARKNESS_WEIGHT = 0.35
SHARPNESS_WEIGHT = 0.20
# A bird covering this fraction of the frame (or more) earns the full area score.
FULL_AREA_FRACTION = 0.25
# Laplacian variance (on a 256-pixel crop) at which sharpness reaches about 63 % of its maximum.
SHARPNESS_REFERENCE = 200.0
SHARPNESS_CROP_SIZE = 256


@dataclass(frozen=True)
class CropScore:
    bird_area: float
    background_darkness: float
    sharpness: float
    total: float


def score_crop(image: Image.Image, box: Box) -> CropScore:
    """Scores the bird in `box` for the lens card cut around it (see `crops.lens_crop_box`)."""
    box = box.clamped()
    grey = np.asarray(image.convert("L"), dtype=np.float32)
    height, width = grey.shape

    area = min(1.0, box.area / FULL_AREA_FRACTION)

    left, top, right, bottom = lens_crop_box(box, (width, height))
    crop = grey[top:bottom, left:right]
    mask = np.ones(crop.shape, dtype=bool)
    bx0, by0, bx1, by1 = box.pixels((width, height))
    mask[max(by0 - top, 0):max(by1 - top, 0), max(bx0 - left, 0):max(bx1 - left, 0)] = False
    background = crop[mask]
    darkness = 1.0 - float(background.mean()) / 255.0 if background.size else 0.5

    bird = image.convert("L").crop((bx0, by0, max(bx1, bx0 + 1), max(by1, by0 + 1)))
    bird = bird.resize((SHARPNESS_CROP_SIZE, SHARPNESS_CROP_SIZE), Image.Resampling.BILINEAR)
    sharpness = 1.0 - math.exp(-laplacian_variance(np.asarray(bird, dtype=np.float32)) / SHARPNESS_REFERENCE)

    total = AREA_WEIGHT * area + DARKNESS_WEIGHT * darkness + SHARPNESS_WEIGHT * sharpness
    return CropScore(bird_area=area, background_darkness=darkness, sharpness=sharpness, total=total)


def laplacian_variance(grey: np.ndarray) -> float:
    """Variance of the 4-neighbour Laplacian, the usual blur measure."""
    if grey.shape[0] < 3 or grey.shape[1] < 3:
        return 0.0
    laplacian = -4 * grey[1:-1, 1:-1] + grey[:-2, 1:-1] + grey[2:, 1:-1] + grey[1:-1, :-2] + grey[1:-1, 2:]
    return float(laplacian.var())


def rank_by_score(scores: dict[str, CropScore]) -> list[str]:
    """Keys ordered best first (ties keep insertion order)."""
    return [key for key, _ in sorted(scores.items(), key=lambda item: -item[1].total)]
