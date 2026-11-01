"""Painting with the fidelity gate (issues #49 and #57), shared by the bake-off and the pack-art step: the bird cut out
of every picture (BiRefNet), each painting's colours fitted back to its photo's, and an unfaithful painting painted
again with the next seed (`packbuilder.fidelity`). Isolation paints the reference bird alone on white first, so that
pack and scene art paint from the bird and not from its perch."""

from __future__ import annotations

import io
import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from packbuilder.art import Workflow
from packbuilder.comfy import ComfyClient
from packbuilder.fidelity import Fidelity, bird_mask, fit_colours, on_white

log = logging.getLogger("packbuilder.painting")

ATTEMPTS = 3
"""A painting whose bird isn't faithful to its photo is painted again with the next seed, at most this many times in
all; then the closest is kept and marked for review."""
ISOLATE_SEED = 49


@dataclass(frozen=True)
class Attempt:
    """One painting of a bird and how faithful it came out."""

    seed: int
    seconds: float
    raw: Image.Image
    mask: np.ndarray
    fitted: Image.Image
    before: Fidelity
    after: Fidelity


@dataclass(frozen=True)
class Isolation:
    """The reference bird alone on white, its colours fitted to the photo's, and the painting it was cut from."""

    image: Image.Image
    attempt: Attempt
    attempts: int


class Painter:
    """Paints on ComfyUI and measures every bird. Cut-outs are cached as PNGs under `cutouts` by name, when named."""

    def __init__(self, client: ComfyClient, cutouts: Path | None = None):
        self.client, self.cutouts = client, cutouts
        self.cutout = Workflow.load("bird-cutout")
        self.isolate_workflow = Workflow.load("bird-isolate")

    def mask(self, image: Image.Image, name: str | None = None) -> np.ndarray:
        """The bird in `image` (BiRefNet), cached as <cutouts>/<name>.png when named."""
        target = self.cutouts / f"{name}.png" if self.cutouts is not None and name else None
        if target is not None and target.exists():
            return bird_mask(Image.open(target))
        upload = f"cutout-{(name or 'image').replace('/', '-')}.png"
        data = self.client.paint(self.cutout, images=[(upload, png(image))]).image
        if target is not None:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        return bird_mask(Image.open(io.BytesIO(data)))

    def best_of(self, workflow: Workflow, images: list[tuple[str, bytes]], prompt: str, seed: int, photo: Image.Image, photo_mask: np.ndarray,
                name: str, size: tuple[int, int] | None = None, attempts: int = ATTEMPTS) -> tuple[Attempt, int]:
        """Paints with `seed`, then the next seeds, until the bird is faithful to `photo` after its colour fit, at most
        `attempts` times; returns the faithful painting or else the closest, and how many were painted."""
        best = None
        for attempt in range(attempts):
            painting = self.client.paint(workflow, images=images, prompt=prompt, seed=seed + attempt, size=size)
            raw = Image.open(io.BytesIO(painting.image)).convert("RGB")
            mask = self.mask(raw, f"{name}@{seed + attempt}")
            try:
                fitted, before, after = fit_colours(raw, mask, photo, photo_mask)
            except ValueError as error:  # no bird, or none where the photo's is
                log.warning("%s seed %d: %s", name, seed + attempt, error)
                continue
            current = Attempt(seed + attempt, painting.seconds, raw, mask, fitted, before, after)
            if best is None or (after.faithful, -after.dE_mean) > (best.after.faithful, -best.after.dE_mean):
                best = current
            if after.faithful:
                return best, attempt + 1
        if best is None:
            raise ValueError(f"{name}: no painting had a bird to measure")
        return best, attempts

    def isolate(self, crop: Image.Image, crop_mask: np.ndarray, prompt: str, name: str, seed: int = ISOLATE_SEED, attempts: int = ATTEMPTS) -> Isolation:
        """The bird of a reference crop (3:4, multiples of 16) alone on white: bird-isolate at the crop's own size, so
        it stays where it is in the photo with its hidden parts completed, its colours fitted back to the photo's."""
        best, attempts = self.best_of(self.isolate_workflow, [(f"isolate-{name}.png", png(crop))], prompt, seed, crop, crop_mask,
                                      f"isolated/{name}", size=crop.size, attempts=attempts)
        return Isolation(image=on_white(best.fitted, best.mask), attempt=best, attempts=attempts)


def png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()

