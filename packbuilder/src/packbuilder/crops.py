"""Cuts the lens and phone JPEGs around a detected bird.

Lens: a 260-pixel square, tight around the bird, because the Display lays a bundled image out at its pixel size
on the 600-pixel canvas and the name sits beside it (DECISIONS.md, "Toolkit facts"). Phone: a looser crop with
context, at most 1200 pixels on the long side.
"""

from __future__ import annotations

from PIL import Image

from packbuilder.scoring import Box

LENS_SIZE = 260
PHONE_MAX_SIZE = 1200
LENS_PADDING = 0.2
PHONE_PADDING = 0.6
JPEG_QUALITY = 82


def lens_crop_box(box: Box, size: tuple[int, int]) -> tuple[int, int, int, int]:
    """A square in pixels around `box` padded by `LENS_PADDING` on each side, shifted (not shrunk) to stay inside the
    image, and only shrunk when the image itself is smaller than the square."""
    width, height = size
    box = box.clamped()
    bx0, by0, bx1, by1 = box.pixels(size)
    bird_side = max(bx1 - bx0, by1 - by0, 1)
    side = min(int(round(bird_side * (1 + 2 * LENS_PADDING))), width, height)
    cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
    left = int(round(cx - side / 2))
    top = int(round(cy - side / 2))
    left = min(max(left, 0), width - side)
    top = min(max(top, 0), height - side)
    return left, top, left + side, top + side


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


def render_lens(image: Image.Image, box: Box) -> Image.Image:
    crop = image.convert("RGB").crop(lens_crop_box(box, image.size))
    return crop.resize((LENS_SIZE, LENS_SIZE), Image.Resampling.LANCZOS)


def render_phone(image: Image.Image, box: Box) -> Image.Image:
    crop = image.convert("RGB").crop(phone_crop_box(box, image.size))
    crop.thumbnail((PHONE_MAX_SIZE, PHONE_MAX_SIZE), Image.Resampling.LANCZOS)
    return crop
