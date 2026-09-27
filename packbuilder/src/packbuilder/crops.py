"""Cuts the lens and phone JPEGs around a detected bird.

Lens: a 552 × 368 (3:2) crop, tight around the bird, because the Display lays a bundled image out at its pixel size
on the 600-pixel canvas: the species card is 24 pixels of padding, the photo across the full width, and the name
under it on the first screenful (DECISIONS.md, "Toolkit facts"; issue #24). Phone: a looser crop with context, at
most 1200 pixels on the long side.
"""

from __future__ import annotations

from PIL import Image, ImageOps

from packbuilder.geometry import Box

LENS_WIDTH = 552
LENS_HEIGHT = 368
LENS_ASPECT = LENS_WIDTH / LENS_HEIGHT
PHONE_MAX_SIZE = 1200
LENS_PADDING = 0.2
# Headroom above a bird too tall for the card, as a fraction of the crop height: the head is what identifies it.
LENS_HEADROOM = 0.06
PHONE_PADDING = 0.6
JPEG_QUALITY = 82


def lens_crop_box(box: Box, size: tuple[int, int]) -> tuple[int, int, int, int]:
    """A card-shaped (`LENS_ASPECT`) box in pixels around `box`, padded by `LENS_PADDING` on each side of the
    bird's tighter axis, shifted (not shrunk) to stay inside the image, and only shrunk when the image itself is
    smaller than the box. A bird taller than the box the image allows keeps its head and loses its tail."""
    width, height = size
    box = box.clamped()
    bx0, by0, bx1, by1 = box.pixels(size)
    # The height the bird needs once padded, whichever axis binds under the card's shape.
    needed_height = max(by1 - by0, (bx1 - bx0) / LENS_ASPECT, 1)
    crop_height = min(int(round(needed_height * (1 + 2 * LENS_PADDING))), height, int(width / LENS_ASPECT))
    crop_width = min(int(round(crop_height * LENS_ASPECT)), width)
    cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
    left = int(round(cx - crop_width / 2))
    if by1 - by0 > crop_height:
        top = by0 - int(round(crop_height * LENS_HEADROOM))
    else:
        top = int(round(cy - crop_height / 2))
    left = min(max(left, 0), width - crop_width)
    top = min(max(top, 0), height - crop_height)
    return left, top, left + crop_width, top + crop_height


def phone_crop_box(box: Box, size: tuple[int, int]) -> tuple[int, int, int, int]:
    """The bird box padded by `PHONE_PADDING` on each side, clamped to the image."""
    width, height = size
    box = box.clamped()
    bx0, by0, bx1, by1 = box.pixels(size)
    pad_x = (bx1 - bx0) * PHONE_PADDING
    pad_y = (by1 - by0) * PHONE_PADDING
    left = max(0, int(round(bx0 - pad_x)))
    top = max(0, int(round(by0 - pad_y)))
    right = min(width, int(round(bx1 + pad_x)))
    bottom = min(height, int(round(by1 + pad_y)))
    return left, top, max(right, left + 1), max(bottom, top + 1)


def upright(image: Image.Image) -> Image.Image:
    """The image with its EXIF orientation applied, so boxes and crops agree with what the photographer saw."""
    return ImageOps.exif_transpose(image) or image


def render_lens(image: Image.Image, box: Box) -> Image.Image:
    crop = image.convert("RGB").crop(lens_crop_box(box, image.size))
    return crop.resize((LENS_WIDTH, LENS_HEIGHT), Image.Resampling.LANCZOS)


def render_phone(image: Image.Image, box: Box) -> Image.Image:
    crop = image.convert("RGB").crop(phone_crop_box(box, image.size))
    crop.thumbnail((PHONE_MAX_SIZE, PHONE_MAX_SIZE), Image.Resampling.LANCZOS)
    return crop
