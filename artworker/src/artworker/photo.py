"""Photo art (issue #69): the birder's own photo of the bird, embellished into card art.

Unlike scene art there is no reference bird: the birder confirmed on the phone that the bird in the photo is the card's
species (there is no automatic ID check), so the photo is the bird's identity and the painting must keep its markings.

- The bird is found in the photo (BiRefNet, the same cut-out the fidelity gate uses) and the photo is cropped to 3:4
  around it with room for its setting (`PHOTO_PADDING`, the #49 bake-off's), at most 1536 px a side. A photo with no
  bird to find fails `no_bird`.
- The committed `photo-art` workflow paints from that crop alone (`<ref_image_0>`), with `prompts.json`'s photo
  template in the card's edition light and the Legendary light for a Legendary card. No prompt names the species.
- The fidelity gate measures the painted bird against the bird in the birder's own crop (ΔE ≤ 10, IoU ≥ 0.65 after the
  colour fit, three seeds at most), so the markings are judged against the photo, not a pack's reference. A painting
  that never passes fails the job (`painting_failed`); the birder still has the original and can Try again.
"""

from __future__ import annotations

import io
import zlib
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageOps

from artworker.scene import JPEG_QUALITY, MODEL, Unfaithful, edition_prompt
from packbuilder.art import MAX_INPUT_SIDE, ArtPrompts, Workflow, photo_crop
from packbuilder.geometry import Box
from packbuilder.painting import ATTEMPTS, Painter, png

PHOTO_PADDING = 0.8
"""Photo art keeps more of the photo around the bird than a reference crop: the place is part of the picture (the
bake-off's `PHOTO_PADDING`)."""
MIN_BIRD_FRACTION = 0.002
"""A cut-out smaller than this share of the photo is a speck, not a bird to paint."""


class NoBird(Exception):
    """Nothing in the photo the cut-out takes for a bird."""


@dataclass(frozen=True)
class PhotoArt:
    jpeg: bytes
    provenance: str
    seed: int


class PhotoPainter:
    def __init__(self, painter: Painter, prompts: ArtPrompts | None = None):
        self.painter = painter
        self.prompts = prompts or ArtPrompts.load()
        self.workflow = Workflow.load("photo-art")

    def crop(self, job_id: str, photo: Image.Image) -> Image.Image:
        """The 3:4 crop around the bird in the photo."""
        photo = photo.copy()
        photo.thumbnail((MAX_INPUT_SIDE, MAX_INPUT_SIDE), Image.Resampling.LANCZOS)
        mask = self.painter.mask(photo, f"photo/{job_id}/whole")
        if mask.mean() < MIN_BIRD_FRACTION:
            raise NoBird()
        rows, columns = np.flatnonzero(mask.any(axis=1)), np.flatnonzero(mask.any(axis=0))
        height, width = mask.shape
        box = Box(columns[0] / width, rows[0] / height, (columns[-1] + 1) / width, (rows[-1] + 1) / height)
        return photo_crop(photo, box, padding=PHOTO_PADDING)

    def paint(self, job_id: str, photo_jpeg: bytes, scientific_name: str, edition: str | None, legendary: bool) -> PhotoArt:
        photo = ImageOps.exif_transpose(Image.open(io.BytesIO(photo_jpeg))).convert("RGB")
        crop = self.crop(job_id, photo)
        crop_mask = self.painter.mask(crop, f"photo/{job_id}/crop")
        if crop_mask.mean() < MIN_BIRD_FRACTION:
            raise NoBird()
        prompt = edition_prompt(self.prompts, "photo", edition, legendary, scientific_name)
        # A seed per job, so Try again (a new job) paints a new picture.
        seed = zlib.crc32(job_id.encode())
        best, tries = self.painter.best_of(
            self.workflow, [(f"photo-{job_id}.png", png(crop))], prompt, seed, crop, crop_mask, f"photo/{job_id}", attempts=ATTEMPTS
        )
        if not best.after.faithful:
            raise Unfaithful(best.after)
        output = io.BytesIO()
        best.fitted.save(output, "JPEG", quality=JPEG_QUALITY, optimize=True)
        provenance = (
            f"{MODEL}; {self.workflow.tag} prompts@{self.prompts.version}; from the birder's photo; "
            f"seed {best.seed}, {tries} painting(s); dE {best.after.dE_mean} against the photo, IoU {best.after.iou}"
        )
        return PhotoArt(output.getvalue(), provenance, best.seed)
