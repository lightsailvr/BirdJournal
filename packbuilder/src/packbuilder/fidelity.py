"""How faithful a painted bird is to its photo, and the colour fit that brings it back (issue #49).

The bird's markings are its identification, so a painting must not change them (the maintainer, 2026-10-15). FLUX.3
keeps the pattern but shifts the colour and tone a little, more for a dim photo. To measure it, both birds are cut
out (BiRefNet), the photo's bird is registered onto the painted one (a scale and a shift that maximise the outlines'
IoU, since the painting redraws the bird at its own size and place), and the colours are compared inside both after a
6 px blur: the mean CIE76 dE, where about 2.3 is just noticeable, and its 95th percentile, where an invented cap or
mask would show. The fit then gives the painted bird the photo's colour and tone: each Lab channel's mean and spread
over the painted bird's own interior are matched to the photo's, inside the bird only, so the brushwork stays.
Matching each bird's own statistics needs no pixel-to-pixel alignment; a line fitted pixel by pixel did, and where the
outlines differed it flattened the bird into a silhouette.

A painting is faithful when, after the fit, its bird is within FAITHFUL_DE of the photo's and the outlines overlap by
FAITHFUL_IOU: a colour or exposure shift is fitted away, but a different pattern or shape (FLUX.3 once painted a Great
Egret as a streaked brown bird) is not.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

BLUR = ImageFilter.GaussianBlur(6)
"""Brushwork and feather detail are not colour: compare after a 6 px blur."""
EDGE = 6
"""Pixels within this distance of either outline are left out of the comparison."""
FAITHFUL_DE = 10.0
FAITHFUL_IOU = 0.65
SPREAD = (0.5, 2.0)
"""The fit changes a channel's spread by at most these factors."""


@dataclass(frozen=True)
class Fidelity:
    iou: float
    """The outlines' overlap after registration."""
    dE_mean: float
    dE_p95: float
    dL: float
    """The mean lightness shift, painting minus photo."""
    dC: float
    """The mean chroma shift, painting minus photo."""

    @property
    def faithful(self) -> bool:
        return self.dE_mean <= FAITHFUL_DE and self.iou >= FAITHFUL_IOU

    def as_dict(self) -> dict:
        return {**asdict(self), "faithful": self.faithful}


@dataclass(frozen=True)
class Registration:
    """Photo pixels to painting pixels: x' = scale * x + dx, y' = scale * y + dy."""

    scale: float
    dx: float
    dy: float
    iou: float

    def affine(self) -> tuple[float, ...]:
        """The coefficients `Image.transform` takes, which map the output (the painting) back to the photo."""
        return (1 / self.scale, 0, -self.dx / self.scale, 0, 1 / self.scale, -self.dy / self.scale)


# sRGB (D65) to CIE XYZ and back, and the D65 white. In floating point: PIL's 8-bit LAB mode is up to 34 levels off
# on a round trip, which is noise in a dE.
_RGB_TO_XYZ = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
_XYZ_TO_RGB = np.linalg.inv(_RGB_TO_XYZ)
_WHITE = np.array([0.95047, 1.0, 1.08883])
_EPSILON = 6 / 29


def lab(image: Image.Image) -> np.ndarray:
    """CIE L*a*b* (D65) as floats: L 0-100, a and b about -110-110."""
    rgb = np.asarray(image.convert("RGB"), dtype=np.float64) / 255
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    xyz = linear @ _RGB_TO_XYZ.T / _WHITE
    f = np.where(xyz > _EPSILON**3, np.cbrt(xyz), xyz / (3 * _EPSILON**2) + 4 / 29)
    return np.dstack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])])


def from_lab(values: np.ndarray) -> Image.Image:
    fy = (values[..., 0] + 16) / 116
    f = np.dstack([fy + values[..., 1] / 500, fy, fy - values[..., 2] / 200])
    xyz = np.where(f > _EPSILON, f**3, 3 * _EPSILON**2 * (f - 4 / 29)) * _WHITE
    linear = np.clip(xyz @ _XYZ_TO_RGB.T, 0, 1)
    rgb = np.where(linear <= 0.0031308, 12.92 * linear, 1.055 * linear ** (1 / 2.4) - 0.055)
    return Image.fromarray((rgb * 255).round().clip(0, 255).astype(np.uint8))


def bird_mask(cutout: Image.Image) -> np.ndarray:
    """The bird in a cut-out (RGBA): its largest opaque piece, without loose scraps."""
    solid = np.asarray(cutout.convert("RGBA").getchannel("A")) > 128
    labels, count = ndimage.label(solid)
    if count <= 1:
        return solid
    sizes = ndimage.sum(solid, labels, range(1, count + 1))
    return labels == int(np.argmax(sizes)) + 1


def register(photo_mask: np.ndarray, painted_mask: np.ndarray) -> Registration:
    """The scale and shift that lay the photo's bird over the painted one: first matching their areas and centroids,
    then a coarse-to-fine search of the outlines' IoU on quarter-size masks."""
    if not photo_mask.any() or not painted_mask.any():
        raise ValueError("a mask has no bird")
    py, px = (float(v.mean()) for v in np.nonzero(photo_mask))
    qy, qx = (float(v.mean()) for v in np.nonzero(painted_mask))
    scale = float(np.sqrt(painted_mask.sum() / photo_mask.sum()))
    k = 4
    target = painted_mask[::k, ::k]
    source = Image.fromarray(photo_mask.astype(np.uint8) * 255)
    size = (target.shape[1], target.shape[0])
    span = float(np.sqrt(painted_mask.sum()))

    def iou(s: float, dx: float, dy: float) -> float:
        warped = np.asarray(source.transform(size, Image.Transform.AFFINE, (k / s, 0, -dx / s, 0, k / s, -dy / s), Image.Resampling.BILINEAR)) > 127
        return float((warped & target).sum() / max((warped | target).sum(), 1))

    best = (scale, qx - scale * px, qy - scale * py)
    best_iou = iou(*best)
    for step in (0.04, 0.015, 0.005):
        improved = True
        while improved:
            improved = False
            s, dx, dy = best
            for ds in (-1, 0, 1):
                for ex in (-1, 0, 1):
                    for ey in (-1, 0, 1):
                        candidate = (s * (1 + ds * step), dx + ex * step * span, dy + ey * step * span)
                        value = iou(*candidate)
                        if value > best_iou + 1e-4:
                            best, best_iou, improved = candidate, value, True
    return Registration(*best, iou=best_iou)


def _comparison(painting: Image.Image, painted_mask: np.ndarray, photo: Image.Image, photo_mask: np.ndarray):
    """The registration, the photo's bird laid over the painting, the region compared (inside both birds, away from
    their outlines), and the blurred Lab of the painting and of the registered photo."""
    registration = register(photo_mask, painted_mask)
    warped_photo = photo.convert("RGB").transform(painting.size, Image.Transform.AFFINE, registration.affine(), Image.Resampling.BICUBIC)
    warped_mask = np.asarray(Image.fromarray(photo_mask.astype(np.uint8) * 255).transform(painting.size, Image.Transform.AFFINE, registration.affine(), Image.Resampling.BILINEAR)) > 127
    inside = ndimage.binary_erosion(warped_mask & painted_mask, iterations=EDGE)
    if not inside.any():
        raise ValueError("the painted bird and the photo's don't overlap")
    return registration, warped_mask, inside, lab(painting.convert("RGB").filter(BLUR)), lab(warped_photo.filter(BLUR))


def _measure(painted: np.ndarray, photo: np.ndarray, inside: np.ndarray, iou: float) -> Fidelity:
    a, b = painted[inside], photo[inside]
    de = np.linalg.norm(a - b, axis=-1)
    return Fidelity(
        iou=round(iou, 3), dE_mean=round(float(de.mean()), 1), dE_p95=round(float(np.percentile(de, 95)), 1),
        dL=round(float((a[:, 0] - b[:, 0]).mean()), 1),
        dC=round(float(np.linalg.norm(a[:, 1:], axis=1).mean() - np.linalg.norm(b[:, 1:], axis=1).mean()), 1),
    )


def measure(painting: Image.Image, painted_mask: np.ndarray, photo: Image.Image, photo_mask: np.ndarray) -> Fidelity:
    """How far the painted bird's colours are from the photo's."""
    registration, _, inside, painted, photographed = _comparison(painting, painted_mask, photo, photo_mask)
    return _measure(painted, photographed, inside, registration.iou)


def _interior(mask: np.ndarray) -> np.ndarray:
    """The bird away from its outline, or all of a bird too thin for that."""
    inner = ndimage.binary_erosion(mask, iterations=EDGE)
    return inner if inner.any() else mask


def fit_colours(painting: Image.Image, painted_mask: np.ndarray, photo: Image.Image, photo_mask: np.ndarray) -> tuple[Image.Image, Fidelity, Fidelity]:
    """The painting with the bird given the photo's colour and tone (each Lab channel's mean and spread over the
    painted bird matched to the photo bird's, applied with a 2 px soft edge, so nothing outside the bird changes), and
    the fidelity before and after."""
    registration, warped_mask, inside, painted, photographed = _comparison(painting, painted_mask, photo, photo_mask)
    before = _measure(painted, photographed, inside, registration.iou)
    own, theirs = _interior(painted_mask), _interior(warped_mask)
    original = painting.convert("RGB")
    fitted = lab(original)
    for c in range(3):
        mine, photos = painted[..., c][own], photographed[..., c][theirs]
        spread = float(np.clip(photos.std() / max(mine.std(), 1e-6), *SPREAD))
        fitted[..., c] = (fitted[..., c] - mine.mean()) * spread + photos.mean()
    weight = ndimage.gaussian_filter(painted_mask.astype(np.float64), 2)[..., None]
    blended = weight * np.asarray(from_lab(fitted), dtype=np.float64) + (1 - weight) * np.asarray(original, dtype=np.float64)
    result = Image.fromarray(blended.round().clip(0, 255).astype(np.uint8))
    after = _measure(lab(result.filter(BLUR)), photographed, inside, registration.iou)
    return result, before, after


def on_white(image: Image.Image, mask: np.ndarray) -> Image.Image:
    """The bird alone on white, with a 1 px soft edge."""
    alpha = Image.fromarray((ndimage.gaussian_filter(mask.astype(np.float64), 1) * 255).clip(0, 255).astype(np.uint8))
    out = Image.new("RGB", image.size, "white")
    out.paste(image.convert("RGB"), (0, 0), alpha)
    return out
