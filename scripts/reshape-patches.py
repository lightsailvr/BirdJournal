"""One shape for every patch of an edition (#58, the maintainer on Orlando, 2026-11-12: "it should be a 100% match on
each patch. 018 has a very clean stitch and shape").

    cd packbuilder && uv run --quiet python ../scripts/reshape-patches.py us-fl-orlando mimus-polyglottos --trial OUT 31 142   # look first
    cd packbuilder && uv run --quiet python ../scripts/reshape-patches.py us-fl-orlando mimus-polyglottos                      # every patch

Environment: RESHAPE_CACHE (the builder's cache; default packbuilder/cache in this checkout), RESHAPE_COMFY (the
painter; default http://comfybox:8189), RESHAPE_CARD (how much card may show at the edge, for a pale scene at a thin
cord), RESHAPE_INSET (pixels more to take off an old patch's edge, for one with a pale line inside its cord).

The canon is one patch's outline and cord (here 018's). Each other patch keeps its embroidery: its picture, without its
own border, is laid inside the canon's blank shield, the model stitches the badge again from that mock-up (filling the
bare cloth between the picture and the new border), and the result is drawn out to the canon's outline exactly, moving
only its outer ring, so every patch has the same alpha to the pixel. A reshaped patch is pending again: the model made
the bird again, however closely. The old file stays in the cache and its hash in the entry (`reshaped_from`).
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.spatial import ConvexHull

from packbuilder.art import Workflow
from packbuilder.comfy import ComfyClient
from packbuilder.patch_art import SIZE, cut_from_card, peeled, trim_rim

CACHE = Path(os.environ.get("RESHAPE_CACHE", Path(__file__).resolve().parents[1] / "packbuilder" / "cache"))
COMFY = os.environ.get("RESHAPE_COMFY", "http://comfybox:8189")
"""On the painting box itself: RESHAPE_CACHE=cache RESHAPE_COMFY=http://127.0.0.1:8189, run from its packbuilder folder; the
tailnet dropped a run from the Mac after twenty patches."""
VERSION = 2
"""The mock-up's recipe, kept in each reshaped entry (`reshape_version`): an entry of this version is left alone, an
older one is made again from its original. 2: the old picture fades into cloth of its own twill colour."""
SEEDS = (0, 1, 2, 500, 501, 900, 901, 2000, 3000, 4000, 5000, 6000)
"""Seed offsets tried in turn until a result is close enough: the model sometimes zooms into the badge instead."""
CANVAS = (864, 1152)
CORD = 26          # the canon's cord, at SIZE
OLD_CORD = 36      # what is cut off an old patch where its cord can't be found by its colour
FEATHER = 14       # pixels over which the old picture fades into the bare cloth
ASPECT_SLACK, LEAST_FIT = 0.05, 0.94


def png(image: Image.Image) -> bytes:
    data = io.BytesIO()
    image.save(data, "PNG")
    return data.getvalue()


def mask_of(patch: Image.Image) -> np.ndarray:
    return np.asarray(patch.convert("RGBA"))[..., 3] > 128


def cropped(patch: Image.Image) -> Image.Image:
    """The patch cropped to its alpha, scaled to SIZE high."""
    alpha = mask_of(patch)
    rows, columns = np.flatnonzero(alpha.any(1)), np.flatnonzero(alpha.any(0))
    patch = patch.convert("RGBA").crop((columns[0], rows[0], columns[-1] + 1, rows[-1] + 1))
    return patch.resize((round(patch.width * SIZE / patch.height), SIZE), Image.LANCZOS)


class Canon:
    """The edition's shape: one patch's outline, its cord and a blank of its twill."""

    def __init__(self, patch: Image.Image):
        self.patch = cropped(trim_rim(patch))
        self.mask = self._hull(mask_of(self.patch))
        self.size = self.patch.size
        self.dist = ndimage.distance_transform_edt(self.mask)
        self.inner = self.dist > CORD
        rgb = np.asarray(self.patch)[..., :3].astype(float)
        # Where the hull is wider than the patch's own alpha, take the nearest pixel of the patch.
        nearest = ndimage.distance_transform_edt(~mask_of(self.patch), return_distances=False, return_indices=True)
        rgb = rgb[nearest[0], nearest[1]]
        pale = (self.dist > CORD + 12) & (rgb.min(-1) > 185)
        self.twill = np.median(rgb[pale], axis=0)
        weave = ndimage.gaussian_filter(np.random.default_rng(3).normal(0, 5, self.mask.shape), 0.8)
        blank = rgb.copy()
        blank[self.inner] = np.clip(self.twill + weave[self.inner][:, None], 0, 255)
        self.blank = blank
        soft = np.clip(ndimage.gaussian_filter(self.mask.astype(float), 0.9) * 1.4 - 0.2, 0, 1)
        self.alpha = (soft * 255).astype(np.uint8)
        self.centre = (self.size[0] / 2, self.size[1] / 2)
        self.radius = self._radii(self.mask)

    @staticmethod
    def _hull(mask: np.ndarray) -> np.ndarray:
        ys, xs = np.nonzero(ndimage.binary_erosion(mask) ^ mask)
        points = np.column_stack([xs, ys])
        hull = points[ConvexHull(points).vertices]
        drawn = Image.new("L", (mask.shape[1], mask.shape[0]), 0)
        ImageDraw.Draw(drawn).polygon([tuple(p) for p in hull], fill=255)
        return np.asarray(drawn) > 0

    def _radii(self, mask: np.ndarray, steps: int = 720) -> np.ndarray:
        """The outline's distance from the centre at `steps` angles."""
        cx, cy = self.centre
        reach = np.arange(0, max(mask.shape) * 1.2, 0.5)
        out = np.zeros(steps)
        for i, angle in enumerate(np.linspace(0, 2 * np.pi, steps, endpoint=False)):
            xs = np.round(cx + reach * np.cos(angle)).astype(int)
            ys = np.round(cy + reach * np.sin(angle)).astype(int)
            ok = (xs >= 0) & (xs < mask.shape[1]) & (ys >= 0) & (ys < mask.shape[0])
            inside = np.zeros(len(reach), bool)
            inside[ok] = mask[ys[ok], xs[ok]]
            out[i] = reach[np.flatnonzero(inside)[-1]] if inside.any() else 0
        return out

    def fit(self, patch: Image.Image) -> tuple[float, float]:
        """The patch's overlap with the canon in its own box, and its width over height against the canon's."""
        alpha = mask_of(cropped(patch))
        mine = np.asarray(Image.fromarray(self.mask).resize((alpha.shape[1], alpha.shape[0]))) > 0
        return float((alpha & mine).sum() / (alpha | mine).sum()), (alpha.shape[1] / alpha.shape[0]) / (self.size[0] / self.size[1])

    def mockup(self, old: Image.Image) -> Image.Image:
        """The old patch's picture, without its border, as large as fits inside the canon's blank, under the canon's cord."""
        old = cropped(trim_rim(old))
        rgba = np.asarray(old).astype(float)
        art = picture_inside_cord(old)
        rows, columns = np.flatnonzero(art.any(1)), np.flatnonzero(art.any(0))
        art_image = Image.fromarray(np.dstack([rgba[..., :3], art * 255]).astype(np.uint8), "RGBA").crop((columns[0], rows[0], columns[-1] + 1, rows[-1] + 1))
        room = self.dist > CORD + 2
        best = None
        for scale in np.arange(1.3, 0.6, -0.02):
            size = (round(art_image.width * scale), round(art_image.height * scale))
            if size[0] > self.size[0] or size[1] > self.size[1]:
                continue
            small = np.asarray(art_image.resize(size, Image.LANCZOS))[..., 3] > 128
            for dy in (0, -12, 12, -24, 24, -36):
                x, y = (self.size[0] - size[0]) // 2, (self.size[1] - size[1]) // 2 + dy
                if y < 0 or y + size[1] > self.size[1]:
                    continue
                outside = (small & ~room[y:y + size[1], x:x + size[0]]).sum() / small.sum()
                if outside < 0.004:
                    best = (scale, x, y, size)
                    break
            if best:
                break
        scale, x, y, size = best
        # The bare cloth takes the old patch's own twill colour, and the picture fades into it over a few pixels: a hard
        # edge between two creams was stitched as a seam (a Least Bittern, a wigeon).
        old_rgb = rgba[..., :3]
        own = art & (old_rgb.min(-1) > 185) & (old_rgb.max(-1) - old_rgb.min(-1) < 40)
        blank = self.blank.copy()
        if own.sum() > 500:
            blank[self.inner] += np.median(old_rgb[own], axis=0) - self.twill
        picture = Image.fromarray(np.clip(blank, 0, 255).astype(np.uint8)).convert("RGBA")
        placed = art_image.resize(size, Image.LANCZOS)
        solid = (np.asarray(placed)[..., 3] > 128) & room[y:y + size[1], x:x + size[0]]
        fade = np.clip(ndimage.distance_transform_edt(solid) / FEATHER, 0, 1)
        clip = Image.fromarray((fade * 255).astype(np.uint8))
        picture.paste(placed.convert("RGB"), (x, y), clip)
        picture.putalpha(Image.fromarray(self.alpha))
        return picture

    def exactly(self, patch: Image.Image) -> Image.Image:
        """The patch drawn out to the canon's outline: its box scaled to the canon's, then each ray from the centre
        stretched or squeezed over its outer third only, so the middle (the bird) does not move."""
        patch = cropped(patch).resize(self.size, Image.LANCZOS)
        rgba = np.asarray(patch).astype(float)
        actual = self._radii(mask_of(patch))
        ys, xs = np.mgrid[0:self.size[1], 0:self.size[0]].astype(float)
        dx, dy = xs - self.centre[0], ys - self.centre[1]
        r = np.hypot(dx, dy)
        steps = len(self.radius)
        index = (np.arctan2(dy, dx) % (2 * np.pi)) / (2 * np.pi) * steps
        low = np.floor(index).astype(int) % steps
        part = index - np.floor(index)
        want = self.radius[low] * (1 - part) + self.radius[(low + 1) % steps] * part
        have = actual[low] * (1 - part) + actual[(low + 1) % steps] * part
        t = np.clip(r / np.maximum(want, 1), 0, 1.3)
        weight = np.clip((t - 0.66) / 0.34, 0, 1) ** 2 * (3 - 2 * np.clip((t - 0.66) / 0.34, 0, 1))
        source = r * (1 + (have / np.maximum(want, 1) - 1) * weight)
        ratio = np.where(r > 0, source / np.maximum(r, 1e-6), 1)
        sx, sy = self.centre[0] + dx * ratio, self.centre[1] + dy * ratio
        channels = [ndimage.map_coordinates(rgba[..., c], [sy, sx], order=1, mode="nearest") for c in range(3)]
        return Image.fromarray(np.dstack([*channels, self.alpha]).astype(np.uint8), "RGBA")


def cordlike(rgb: np.ndarray) -> np.ndarray:
    """Thread of the cord's kind: saturated, not pale, green and blue together well over red (deep teal). Foliage has
    little blue, stitched water is pale or far bluer than green."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    return (g > r + 25) & (b > r + 25) & (np.abs(g - b) < 55) & (rgb.max(-1) < 220) & (rgb.max(-1) - rgb.min(-1) > 50)


def picture_inside_cord(patch: Image.Image, steps: int = 720, margin: float = 9) -> np.ndarray:
    """The patch's picture without its border: along each ray from the centre, everything inside the outermost run of
    cord-coloured thread (a teal bird further in is no cord), so a thick cord, or one with a pale rim outside it, goes
    whole. Where a ray finds no cord, `OLD_CORD` in from the edge. The radii are smoothed round the patch."""
    rgba = np.asarray(patch.convert("RGBA")).astype(float)
    inside = rgba[..., 3] > 128
    cord = cordlike(rgba[..., :3]) & inside
    height, width = inside.shape
    cx, cy = width / 2, height / 2
    reach = np.arange(0, max(height, width), 1.0)
    radii = np.zeros(steps)
    for i, angle in enumerate(np.linspace(0, 2 * np.pi, steps, endpoint=False)):
        xs = np.round(cx + reach * np.cos(angle)).astype(int)
        ys = np.round(cy + reach * np.sin(angle)).astype(int)
        ok = (xs >= 0) & (xs < width) & (ys >= 0) & (ys < height)
        within = np.zeros(len(reach), bool)
        within[ok] = inside[ys[ok], xs[ok]]
        if not within.any():
            continue
        edge = np.flatnonzero(within)[-1]
        thread = np.zeros(len(reach), bool)
        thread[ok] = cord[ys[ok], xs[ok]]
        radius, gap, found = edge - OLD_CORD, 0, False
        for step in range(edge, max(edge - 130, 0), -1):  # inward from the edge: a rim, then the cord, then the picture
            if thread[step]:
                found, gap, radius = True, 0, step
            elif found:
                gap += 1
                if gap > 10:  # a cord's sheen is pale thread for a few pixels
                    break
        radii[i] = radius - margin
    radii = ndimage.minimum_filter1d(ndimage.median_filter(radii, 21, mode="wrap"), 9, mode="wrap")
    ys, xs = np.mgrid[0:height, 0:width].astype(float)
    r = np.hypot(xs - cx, ys - cy)
    index = ((np.arctan2(ys - cy, xs - cx) % (2 * np.pi)) / (2 * np.pi) * steps).astype(int) % steps
    art = inside & (r < radii[index])
    # What cord is left touches the picture's edge: take off cord-coloured thread joined to it, a little way in.
    depth = ndimage.distance_transform_edt(art)
    left = cord & art & (depth <= 45)
    joined = ndimage.binary_propagation(left & (depth <= 4), mask=left)
    art &= ~ndimage.binary_dilation(joined, iterations=3)
    art = ndimage.binary_opening(art, iterations=3)
    # Clear of whatever lies along the old cord's inner edge; RESHAPE_INSET takes more, for an old patch with a pale
    # line stitched inside its cord (a Least Bittern), which the model otherwise stitches again as a seam.
    art = ndimage.binary_erosion(art, iterations=6 + int(os.environ.get("RESHAPE_INSET", "0")))
    labels, count = ndimage.label(art)
    if count > 1:
        art = labels == (np.argmax(ndimage.sum(art, labels, range(1, count + 1))) + 1)
    return art


def on_card(patch: Image.Image, width: float = 0.74) -> Image.Image:
    card = Image.new("RGB", CANVAS, (250, 250, 248))
    scale = CANVAS[0] * width / patch.width
    patch = patch.resize((round(patch.width * scale), round(patch.height * scale)), Image.LANCZOS)
    card.paste(patch, ((CANVAS[0] - patch.width) // 2, (CANVAS[1] - patch.height) // 2), patch)
    return card


def prompt(edition: dict) -> str:
    return (
        "A product photograph of the embroidered merit badge in <ref_image_0>, photographed again from directly above, lying flat in the middle of plain white card "
        "under soft, even, diffuse light, with only a faint shadow. The badge has exactly the outline, the size and the border of the one in <ref_image_0>: the same shield, "
        f"with its thick raised merrowed border of overlocked {edition['cord']} thread all the way around its edge and nothing outside that border but white card. "
        "The embroidered bird is exactly as in <ref_image_0>: the same bird in the same place and pose, the same feather pattern, colours and markings, the same bill, eye, legs and feet, "
        "and whatever it stands, swims or perches on, nothing added and nothing taken away, every stitch visible. The stitched scene behind it is the same too, and it carries on, "
        f"in the same thread and the same hand, across any bare band of cloth between the scene and the border, so that {edition['twill']} and the scene's {edition['motif']} "
        "reach the border evenly all the way round with no seam, no step and no pale band. The whole badge is in the frame with a margin of white card all around it, in sharp focus. "
        "No text, letters, numbers or logos anywhere. No other birds, animals or people."
    )


def main() -> None:
    pack, canon_id, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    trial = None
    if rest[:1] == ["--trial"]:
        trial, rest = Path(rest[1]), rest[2:]
        trial.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[1]
    definition = json.loads((root / "packbuilder" / "packs" / pack / "pack.json").read_text())["species"]
    ids = [s["scientific_name"].lower().replace(" ", "-") for s in definition]
    names = {i: s["common_name"] for i, s in zip(ids, definition)}
    lock_path = root / "packbuilder" / "packs" / pack / "patch.lock.json"
    document = json.loads(lock_path.read_text())
    lock = document["species"]
    edition = json.loads((root / "art" / "patch-prompts.json").read_text())["editions"][pack]
    patches = CACHE / "art" / "patches"
    canon = Canon(Image.open(patches / f"{lock[canon_id].get('reshaped_from') or lock[canon_id]['sha256']}.png"))
    workflow = Workflow.load("patch-art", root / "art" / "workflows")
    client = ComfyClient(COMFY)
    text = prompt(edition)
    wanted = [ids[int(n) - 1] for n in rest] if rest else ids
    for number, species_id in enumerate(ids, start=1):
        entry = lock.get(species_id)
        if species_id not in wanted or entry is None or not entry.get("sha256") or entry["review"] == "rejected" or (entry.get("reshaped_from") and (entry.get("reshape_version") == VERSION or entry["review"] == "approved") and not trial):  # an approved reshape is never made again
            continue
        old_hash = entry.get("reshaped_from") or entry["sha256"]
        old = Image.open(patches / f"{old_hash}.png")
        mockup = on_card(canon.mockup(old))
        best = None
        if species_id == canon_id:  # the canon is its own shape: only its alpha becomes the hull's
            cut = cropped(trim_rim(old))
            best = ((False, -1.0), None, cut, 1.0, 1.0, peeled(cut), 0)
        for attempt, offset in enumerate(() if best else SEEDS[:3] if trial else SEEDS):
            for wait in (0, 30, 60, 120, 240):  # a dropped link costs a wait, not the run
                time.sleep(wait)
                try:
                    painting = client.paint(workflow, images=[(f"reshape-{pack}-{old_hash[:12]}.png", png(mockup))], prompt=text, seed=entry["seed"] + 101 + offset)
                    break
                except Exception as error:  # noqa: BLE001
                    print(f"  {names[species_id]}: {type(error).__name__}, trying again", flush=True)
            else:
                raise SystemExit(f"{names[species_id]}: the painter did not answer")
            raw = Image.open(io.BytesIO(painting.image)).convert("RGB")
            try:
                cut = trim_rim(cut_from_card(raw))
            except ValueError:  # nothing on the card
                continue
            fit, aspect = canon.fit(cut)
            card = peeled(cut)
            # RESHAPE_CARD: for a patch whose pale scene runs up to a thin cord (sand, sky), which reads as card at the edge.
            bad = fit < LEAST_FIT or abs(aspect - 1) > ASPECT_SLACK or card > float(os.environ.get("RESHAPE_CARD", "0.015"))
            if best is None or (bad, -fit) < best[0]:
                best = ((bad, -fit), raw, cut, fit, aspect, card, attempt + 1)
            if not bad:
                break
        if best is None:
            print(f"{number:03d} {names[species_id]}: no badge in any attempt NOT CLOSE ENOUGH", flush=True)
            continue
        (bad, _), raw, cut, fit, aspect, card, attempts = best
        exact = canon.exactly(cut)
        print(f"{number:03d} {names[species_id]}: fit {fit:.3f}, aspect {aspect:.3f}, card {card:.3f}, {attempts} attempt(s){' NOT CLOSE ENOUGH' if bad else ''}", flush=True)
        if trial:
            sheet = Image.new("RGB", (4 * 660, 740), (150, 150, 150))
            for i, picture in enumerate((cropped(trim_rim(old)), cropped(canon.mockup(old)), cropped(cut), exact)):
                picture = picture.convert("RGBA")
                sheet.paste(picture, (i * 660 + (660 - picture.width) // 2, 10), picture)
            sheet.save(trial / f"{number:03d}.jpg", quality=88)
            continue
        if bad:
            continue
        data = png(exact)
        digest = hashlib.sha256(data).hexdigest()
        (patches / f"{digest}.png").write_bytes(data)
        if raw is not None:
            raw.save(patches / f"{digest}-raw.png")
        document = json.loads(lock_path.read_text())  # read again: a review may have been recorded meanwhile
        lock = document["species"]
        lock[species_id].update({"sha256": digest, "reshaped_from": old_hash, "reshape_version": VERSION, "reshaped_fit": round(fit, 3), "card_at_edge": round(card, 4), "review": "pending"})
        lock_path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
