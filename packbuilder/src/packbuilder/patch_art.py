"""Patch art (issue #133, of #131, design guide 2.0): one embroidered patch per species per edition, the only painting
in the app. Each set's patch has its own shape, cord, twill and stitched motif (`art/patch-prompts.json`).

A patch is painted on comfybox with the committed `patch-art` workflow from the species' reference bird isolated on
white, the same bird its pack art was painted from: the pack-art lock (`art.lock.json`) names its photo and isolation
seed, and the isolated bird is in the art cache (`packbuilder.pack_art`). `overrides.json` can pin another of the pack's
photos (`art.patch.reference`, isolated here when the cache lacks it) and give the plumage facts the thread keeps getting
wrong (`art.patch.markings`); the bird stands where it lives (`art.setting`). The painting lies flat on white card under
even light, so the app does the lighting; the step cuts the patch from the card (`cut_from_card`: every edition's shape
is convex) and measures the bird inside it against its reference (`measure`). The measure ranks and flags, it doesn't
decide: in the samples thread colour moved a good House Finch about as far from its photo (ΔE ~20) as a failed Black
Phoebe (~23), so every patch is reviewed by the maintainer on the contact sheets, and a rejected one is painted again
with the next seed. There is no colour fit: the bird's mask inside a patch can take in the leaves beside it, and a fit
would recolour them.

`patch.lock.json` beside the pack definition pins each species' patch: its reference photo, isolation seed, workflow,
prompts version, setting, markings and edition, its seed, the cut patch's SHA-256 (its file in `<cache>/patches/`), the measure and the
review (pending, approved, rejected or gap, as for pack art). A new reference, workflow or edition paints a patch again;
new prompts don't, since the review is the costly part: a rejected patch takes the current templates. `layers` turns an approved patch into what the app lights
and animates: the colour on transparency, a height map, the cord's mask and the stitch order.
"""

from __future__ import annotations

import hashlib
import io
import json
import logging
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage
from scipy.spatial import ConvexHull

from packbuilder.art import ART_DIR, Workflow, reference_crop
from packbuilder.comfy import ComfyClient, PaintingFailed
from packbuilder.contact_sheets import grid
from packbuilder.crops import upright
from packbuilder.fidelity import lab, measure as measure_bird
from packbuilder.geometry import Box
from packbuilder.painting import ISOLATE_SEED, Painter, png
from packbuilder.pack_art import APPROVED, GAP, PENDING, REJECTED, UNPAINTED, ArtLock

log = logging.getLogger("packbuilder.patch_art")

LOCK_FILE = "patch.lock.json"
SIZE = 720
"""The cut patch's longest side."""
PEEL_LIMIT = 0.015
"""The share of the patch's outer band (45 px at `SIZE`) that may be bare card: above it, a corner of the card has peeled up
into the cut (FLUX.3 sometimes paints a lifted corner, about one patch in fifteen on the Los Angeles run), and the patch
is painted again with the next seed."""
PEEL_ATTEMPTS = 3
CORD_DEPTH = 25.0
# How deep a rim of card can reach, and how much of a patch it can be (the Los Angeles patches' run from 2% to 7%).
RIM_DEPTH = 60
RIM_MINIMUM = 0.015
RIM_LIMIT = 0.12
"""How far the merrowed cord runs in from the patch's edge at `SIZE`: measured on every edition's samples, the cord
ends in a dark groove about 25 px in, whatever the shape."""


DEFAULT_SETTING = "perch"


@dataclass(frozen=True)
class PatchPin:
    """What `overrides.json` says of one species' patch: its setting (`art.setting`), the pack photo to paint from instead
    of its pack art's (`art.patch.reference`), and the plumage facts to state (`art.patch.markings`)."""

    setting: str = DEFAULT_SETTING
    reference: int | None = None
    markings: str | None = None
    box: tuple[float, float, float, float] | None = None
    """The bird in the pinned photo as fractions of its width and height (x0, y0, x1, y1), for a bird the detector can't
    see: a poorwill on bark mulch."""

    @classmethod
    def from_art(cls, art: dict) -> "PatchPin":
        patch = art.get("patch") or {}
        box = patch.get("box")
        return cls(art.get("setting") or DEFAULT_SETTING, patch.get("reference"), patch.get("markings"), tuple(box) if box else None)


@dataclass(frozen=True)
class PatchSpec:
    """One edition's patch."""

    shape: str
    cord: str
    twill: str
    motif: str

    def as_dict(self) -> dict:
        return {"shape": self.shape, "cord": self.cord, "twill": self.twill, "motif": self.motif}


@dataclass(frozen=True)
class PatchPrompts:
    version: int
    template: str
    dark: str
    dark_lightness: float
    editions: dict[str, PatchSpec]
    settings: dict[str, str]

    @classmethod
    def load(cls, path: Path = ART_DIR / "patch-prompts.json") -> "PatchPrompts":
        data = json.loads(Path(path).read_text())
        return cls(data["version"], data["template"], data["dark"], data["dark_lightness"],
                   {pack: PatchSpec(**spec) for pack, spec in data["editions"].items()}, data["settings"])

    def render(self, spec: PatchSpec, dark: bool, setting: str = DEFAULT_SETTING, markings: str | None = None) -> str:
        return self.template.format(shape=spec.shape, cord=spec.cord, twill=spec.twill, motif=spec.motif, dark=self.dark if dark else "",
                                    setting=self.settings[setting], markings=f" {markings}" if markings else "")


@dataclass(frozen=True)
class Patch:
    """One species' patch as the step has it."""

    species_id: str
    review: str
    file: Path | None
    """The cut patch (RGBA PNG) in the cache; None for a gap or a patch that failed."""
    photos: tuple[int, ...] = ()
    """The iNaturalist ids of the photos its reference bird was isolated from."""

    @property
    def ships(self) -> bool:
        return self.review == APPROVED and self.file is not None

    @property
    def settled(self) -> bool:
        return self.ships or self.review == GAP


class PatchLock(ArtLock):
    """`patch.lock.json`: per species id, what its patch was painted from and its review (see the module)."""

    COMMENT = (
        "Patch art (issue #133, of #131), written by `packbuilder patches` and `packbuilder patch-review`; review on the contact sheets in "
        "build/pack-art/<pack id>/patches/. Per species: the reference photo and isolation seed (from art.lock.json, or art.patch.reference), the "
        "workflow and patch prompts versions, the setting and any markings it was painted with, the edition's patch, the seed, the cut patch's SHA-256 (its file in <cache>/patches/), the bird's measure against its "
        "reference, whether the dark-bird clause was used, and the review: pending, approved (in the pack), rejected (painted again with the next "
        "seed by the next run) or gap (no patch; why)."
    )


@dataclass(frozen=True)
class Reference:
    """A species' reference bird, isolated on white, from its pack art."""

    photo_id: int
    isolate_seed: int
    image: Image.Image


@dataclass
class PatchArtist:
    """Paints what the patch lock lacks for one pack. `art_lock` is the pack's pack-art lock, which names each species'
    reference; `cache_dir` is the art cache (isolated birds in `isolated/`, patches written to `patches/`)."""

    client: ComfyClient
    pack_id: str
    lock: PatchLock
    art_lock: ArtLock
    cache_dir: Path
    prompts: PatchPrompts = field(default_factory=PatchPrompts.load)
    pins: dict[str, PatchPin] = field(default_factory=dict)
    originals: Path | None = None
    """The downloaded originals (`<photo id>.<extension>`), which a pinned reference is isolated from when the cache lacks it."""
    find_bird: Callable[[Image.Image], Box] | None = None
    """The bird's box in an original, for that isolation."""

    def __post_init__(self):
        self.cache_dir = Path(self.cache_dir)
        self.painter = Painter(self.client)
        self.workflow = Workflow.load("patch-art")
        self.spec = self.prompts.editions[self.pack_id]
        self.painted = 0

    def paint(self, species_ids: list[str]) -> dict[str, Patch]:
        """Every species' patch, painting only what the lock lacks; the lock is written after each, so a run resumes."""
        patches = {}
        for number, species_id in enumerate(species_ids, start=1):
            try:
                patches[species_id] = self._species(species_id, number, len(species_ids))
            except (PaintingFailed, ValueError, OSError, KeyError) as error:  # one species' failure never stops the run
                log.error("  patch for %s failed: %s", species_id, error)
                patches[species_id] = Patch(species_id, UNPAINTED, None)
        log.info("patches: %d painted, %d approved, %d to review, %d gaps", self.painted,
                 *(sum(p.review == state for p in patches.values()) for state in (APPROVED, PENDING, GAP)))
        return patches

    def reference(self, species_id: str) -> Reference:
        """The isolated bird the species' pack art was painted from. Raises KeyError when the pack art has none."""
        art = self.art_lock.species[species_id]
        pinned = self.pins.get(species_id, PatchPin()).reference
        if pinned is not None:
            return self._isolated(pinned, self.pins[species_id].box)
        if not art.get("photos"):
            raise KeyError(f"{species_id}: its pack art was painted from text; a patch needs a reference bird")
        photo_id, seed = art["photos"][0], art.get("isolate_seed") or ISOLATE_SEED
        found = cached_isolations(self.cache_dir, photo_id)
        if seed in found:
            return Reference(photo_id, seed, Image.open(found[seed]).convert("RGB"))
        raise KeyError(f"{species_id}: no isolated bird for photo {photo_id} seed {seed} in {self.cache_dir / 'isolated'}; run the pack build to make it")

    def _isolated(self, photo_id: int, box: tuple[float, float, float, float] | None = None) -> Reference:
        """A pinned photo's isolated bird, from the cache or isolated now from its original, as pack art does."""
        found = cached_isolations(self.cache_dir, photo_id)
        if found:
            seed = min(found)
            return Reference(photo_id, seed, Image.open(found[seed]).convert("RGB"))
        # The originals keep the extension iNaturalist gave them: .jpg, .jpeg, .png.
        original = next(iter(sorted(self.originals.glob(f"{photo_id}.*"))), None) if self.originals is not None else None
        if original is None or (self.find_bird is None and box is None):
            raise KeyError(f"photo {photo_id}: no isolated bird in the cache and no original to isolate it from")
        with Image.open(original) as opened:
            image = upright(opened).convert("RGB")
        crop = reference_crop(image, Box(*box) if box else self.find_bird(image))
        from packbuilder.art import ArtPrompts

        prompt = ArtPrompts.load().isolate
        isolation = self.painter.isolate(crop, self.painter.mask(crop), prompt, str(photo_id), seed=ISOLATE_SEED)
        key = f"{photo_id}-s{ISOLATE_SEED}-{self.painter.isolate_workflow.tag}-i{hashlib.sha256(prompt.encode()).hexdigest()[:10]}"
        path = self.cache_dir / "isolated" / f"{key}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        isolation.image.save(path)
        path.with_suffix(".json").write_text(json.dumps({"seed": isolation.attempt.seed, "attempts": isolation.attempts, "fitted": isolation.attempt.after.as_dict()}) + "\n")
        log.info("  photo %d: isolated, seed %d", photo_id, isolation.attempt.seed)
        return Reference(photo_id, isolation.attempt.seed, isolation.image.convert("RGB"))

    def _inputs(self, reference: Reference) -> dict:
        """What a reviewed patch is painted again for. The prompts aren't among them: see the module."""
        return {"photos": [reference.photo_id], "isolate_seed": reference.isolate_seed, "workflow": self.workflow.tag, "edition": self.spec.as_dict()}

    def _species(self, species_id: str, number: int, total: int) -> Patch:
        entry = self.lock.species.get(species_id)
        if entry is not None and entry["review"] == GAP:
            return Patch(species_id, GAP, None)
        reference = self.reference(species_id)
        inputs = self._inputs(reference)
        same = entry is not None and all(entry.get(key) == value for key, value in inputs.items())
        if same and entry["review"] in (PENDING, APPROVED) and self._file(entry["sha256"]).exists():
            return Patch(species_id, entry["review"], self._file(entry["sha256"]), tuple(entry["photos"]))
        rejected = list(entry.get("rejected_seeds", [])) if entry else []
        seed = zlib.crc32(f"{self.pack_id}/{species_id}/patch-art/{len(rejected)}".encode())
        if same and entry["review"] in (PENDING, APPROVED):
            seed = entry["seed"]  # the locked patch isn't cached: paint it again from its seed
        common = self.art_lock.species[species_id].get("common_name", species_id)
        pin = self.pins.get(species_id, PatchPin())
        fresh = self._render(reference, seed, f"{species_id}", common, pin)
        fresh.update(inputs)
        fresh.update({"prompts": self.prompts.version, "setting": pin.setting})
        if pin.markings:
            fresh["markings"] = pin.markings
        if same and entry["review"] == APPROVED and fresh["sha256"] == entry["sha256"]:
            fresh["review"] = APPROVED
        else:
            fresh["review"] = PENDING
        for key in ("rejected_seeds", "why"):
            if entry and entry.get(key):
                fresh[key] = entry[key]
        self.lock.species[species_id] = fresh
        self.lock.write()
        log.info("  %03d/%03d %s: seed %d, dE %s, iou %s%s", number, total, common, seed,
                 fresh["measure"] and f"{fresh['measure']['dE_mean']:.1f}", fresh["measure"] and f"{fresh['measure']['iou']:.2f}",
                 " (dark clause)" if fresh["dark"] else "")
        return Patch(species_id, fresh["review"], self._file(fresh["sha256"]), tuple(fresh["photos"]))

    def _render(self, reference: Reference, seed: int, name: str, common_name: str, pin: PatchPin = PatchPin()) -> dict:
        """Paints the patch with `seed`, then the next seeds while a corner of the card peels into the cut, at most
        `PEEL_ATTEMPTS` times, keeping the cleanest; then measures its bird."""
        dark = is_dark(reference.image, self.prompts.dark_lightness)
        prompt = self.prompts.render(self.spec, dark, pin.setting, pin.markings)
        best = None
        for attempt in range(PEEL_ATTEMPTS):
            painting = self.client.paint(self.workflow, images=[(f"patch-bird-{reference.photo_id}.png", png(reference.image))], prompt=prompt, seed=seed + attempt)
            raw = Image.open(io.BytesIO(painting.image)).convert("RGB")
            self.painted += 1
            cut = cut_from_card(raw)
            card = peeled(cut)
            if best is None or card < best[0]:
                best = (card, seed + attempt, raw, cut, attempt + 1)
            if card <= PEEL_LIMIT:
                break
        card, seed, raw, cut, attempts = best
        result = {"common_name": common_name, "seed": seed, "dark": dark, "measure": None, "card_at_edge": round(card, 4), "attempts": attempts}
        try:
            interior_image = interior(cut)
            bird = self.painter.mask(interior_image, None)
            reference_mask = self.painter.mask(reference.image, None)
            result["measure"] = measure_bird(interior_image, bird, reference.image, reference_mask).as_dict()
        except ValueError as error:  # no bird found: the review sees it unmeasured
            log.warning("  %s: not measured: %s", name, error)
        result["sha256"] = self._store(cut, raw)
        return result

    def _store(self, cut: Image.Image, raw: Image.Image) -> str:
        data = png(cut)
        digest = hashlib.sha256(data).hexdigest()
        target = self._file(digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        raw.save(target.with_name(f"{digest}-raw.png"))
        return digest

    def _file(self, digest: str) -> Path:
        return self.cache_dir / "patches" / f"{digest}.png"

    def sheets(self, species_ids: list[str], patches: dict[str, Patch], out_dir: Path, per_sheet: int = 12) -> list[Path]:
        """Contact sheets for the review: each species' reference bird beside its patch, with its state and measure,
        numbered in the set's order, plus one overview of every patch."""
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        for old in [*out_dir.glob("sheet-*.jpg"), out_dir / "overview.jpg"]:
            old.unlink(missing_ok=True)
        cells = []
        for number, species_id in enumerate(species_ids, start=1):
            patch = patches.get(species_id)
            entry = self.lock.species.get(species_id, {})
            common = entry.get("common_name") or self.art_lock.species.get(species_id, {}).get("common_name", species_id)
            try:
                bird = self.reference(species_id).image.copy()
                bird.thumbnail((576, 768))
            except (KeyError, ValueError):  # one species' missing reference never stops the sheets
                bird = None
            measured = entry.get("measure")
            line = f"dE {measured['dE_mean']:.1f} iou {measured['iou']:.2f}" if measured else "not measured"
            if entry.get("card_at_edge", 0) > PEEL_LIMIT:
                line += " · CARD AT EDGE"
            state = (patch.review if patch else UNPAINTED).upper()
            picture = _on_card(patch.file) if patch and patch.file and patch.file.exists() else None
            cells.append(((bird, f"{number:03d} {common}\nreference"), (picture, f"{state}{' · dark clause' if entry.get('dark') else ''}\n{line}")))
        made = []
        for start in range(0, len(cells), per_sheet):
            chunk = cells[start:start + per_sheet]
            rows = [[cell for pair in chunk[i:i + 3] for cell in pair] for i in range(0, len(chunk), 3)]
            target = out_dir / f"sheet-{start // per_sheet + 1:02d}.jpg"
            grid(rows, f"{self.pack_id} patches {start + 1}-{start + len(chunk)} of {len(cells)}: patch prompts v{self.prompts.version}, {self.spec.shape}, {self.spec.cord} cord", []).save(target, quality=88)
            made.append(target)
        overview = [[pair[1] for pair in cells[i:i + 10]] for i in range(0, len(cells), 10)]
        if overview:
            target = out_dir / "overview.jpg"
            grid(overview, f"{self.pack_id} patches, all {len(cells)}", [], cell=(144, 192)).save(target, quality=85)
            made.append(target)
        return made


def cached_isolations(cache_dir: Path, photo_id: int) -> dict[int, Path]:
    """The photo's isolated birds in the art cache by the seed each was kept with. The cache is keyed by the isolation's
    first seed; the lock keeps the seed of the attempt that was kept (49 and its retries, 59 and its after a rejection),
    which the cached isolation's info records."""
    isolate = hashlib.sha256(_isolate_prompt().encode()).hexdigest()[:10]
    suffix = f"-{Workflow.load('bird-isolate').tag}-i{isolate}"
    found = {}
    for image in sorted((Path(cache_dir) / "isolated").glob(f"{photo_id}-s*{suffix}.png")):
        info = image.with_suffix(".json")
        # Without its info, the seed in its name: an isolation kept on its first attempt.
        seed = json.loads(info.read_text())["seed"] if info.exists() else int(image.name.split("-s", 1)[1].split("-", 1)[0])
        found[seed] = image
    return found


def _isolate_prompt() -> str:
    from packbuilder.art import ArtPrompts
    return ArtPrompts.load().isolate


def _on_card(path: Path, size: tuple[int, int] = (576, 768)) -> Image.Image:
    """A cut patch on a mid grey card for the sheets, loaded small and closed."""
    with Image.open(path) as opened:
        patch = opened.convert("RGBA")
    patch.thumbnail(size)
    card = Image.new("RGBA", patch.size, (150, 150, 150, 255))
    return Image.alpha_composite(card, patch).convert("RGB")


def peeled(patch: Image.Image) -> float:
    """The share of the cut patch's outer band (45 px in) that is bare card, light and unsaturated: a peeled corner."""
    rgba = np.asarray(patch.convert("RGBA")).astype(float)
    rgb, inside = rgba[..., :3], rgba[..., 3] > 128
    band = inside & (ndimage.distance_transform_edt(inside) < 45)
    card = (rgb.mean(-1) > 200) & ((rgb.max(-1) - rgb.min(-1)) < 28)
    return float((card & band).sum() / max(band.sum(), 1))


def is_dark(bird_on_white: Image.Image, threshold: float) -> bool:
    """Whether the isolated bird's median lightness (L*) is under `threshold`: a black or sooty bird."""
    lightness = lab(bird_on_white.convert("RGB"))[..., 0]
    rgb = np.asarray(bird_on_white.convert("RGB")).astype(int)
    bird = ~np.all(rgb > 235, axis=-1)
    return bool(bird.any() and float(np.median(lightness[bird])) < threshold)


def cut_from_card(painting: Image.Image) -> Image.Image:
    """The patch cut from the white card it lies on, cropped to it and scaled to `SIZE` on its longest side. The card
    is what connects to the picture's edge and stays close to the card's colour; the soft shadow, card-coloured but
    darker, is dropped by keeping only what is clearly off the card, then the convex hull of that (every edition's shape
    is convex) puts back a pale cord's edge. BiRefNet is no use here: it takes the bird as often as the patch. Raises
    ValueError when nothing is on the card."""
    rgb = np.asarray(painting.convert("RGB")).astype(float)
    height, width, _ = rgb.shape
    edge = np.concatenate([rgb[:8].reshape(-1, 3), rgb[-8:].reshape(-1, 3), rgb[:, :8].reshape(-1, 3), rgb[:, -8:].reshape(-1, 3)])
    card = np.median(edge, axis=0)
    diff = np.linalg.norm(rgb - card, axis=-1)
    saturation = rgb.max(-1) - rgb.min(-1)
    cardlike = (diff < 34) | ((rgb.mean(-1) > 150) & (saturation < 22) & (diff < 70))
    labels, _ = ndimage.label(cardlike)
    border = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    badge = ndimage.binary_fill_holes(~np.isin(labels, border[border > 0]))
    core = ndimage.binary_opening(badge & ((diff > 60) | (saturation > 30)), iterations=3)
    labels, count = ndimage.label(core)
    if count == 0:
        raise ValueError("no patch on the card")
    if count > 1:
        core = labels == (np.argmax(ndimage.sum(core, labels, range(1, count + 1))) + 1)
    ys, xs = np.nonzero(ndimage.binary_erosion(core) ^ core)
    points = np.column_stack([xs, ys])
    hull = points[ConvexHull(points).vertices]
    outline = Image.new("L", (width, height), 0)
    ImageDraw.Draw(outline).polygon([tuple(p) for p in hull], fill=255)
    shape = ndimage.binary_erosion(np.asarray(outline) > 0, iterations=3)
    alpha = np.clip(ndimage.gaussian_filter(shape.astype(float), 0.9) * 1.4 - 0.2, 0, 1)
    cut = Image.fromarray(np.dstack([rgb, alpha * 255]).astype(np.uint8), "RGBA")
    ys, xs = np.nonzero(alpha > 0.1)
    pad = 6
    cut = cut.crop((max(xs.min() - pad, 0), max(ys.min() - pad, 0), min(xs.max() + pad, width), min(ys.max() + pad, height)))
    scale = SIZE / max(cut.size)
    return cut.resize((round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS)


def trim_rim(patch: Image.Image) -> Image.Image:
    """The cut patch without the pale crescent `cut_from_card` can leave along one side: the card under its soft shadow,
    which is why it never showed on the white review sheets, and on felt reads as a paper disc under the patch. It grows
    in from the edge through what is smooth and unsaturated, so a stitched cord stops it however pale its thread: thread
    has grain, shadow has none. The convex hull of the rest is the patch, as in the cut. A patch it would take less than
    `RIM_MINIMUM` or more than `RIM_LIMIT` of comes back whole: it has no rim, or that isn't one. Cropped to the result and
    scaled to `SIZE` again."""
    rgba = np.asarray(patch.convert("RGBA")).astype(float)
    rgb, alpha = rgba[..., :3], rgba[..., 3]
    inside = alpha > 128
    saturation = rgb.max(-1) - rgb.min(-1)
    dist = ndimage.distance_transform_edt(inside)
    outermost = inside & (dist <= 2)
    # What's under the transparency is no part of the grain: outside takes the nearest pixel of the patch.
    nearest = ndimage.distance_transform_edt(~inside, return_distances=False, return_indices=True)
    lightness = rgb.mean(-1)[nearest[0], nearest[1]]
    grain = ndimage.maximum_filter(np.abs(lightness - ndimage.gaussian_filter(lightness, 1.5)), 3)
    smooth = inside & (saturation < 40) & (grain < 9) & (lightness > 85)
    rim = ndimage.binary_propagation(outermost, mask=smooth | outermost) & (dist <= RIM_DEPTH)
    keep = ndimage.binary_opening(inside & ~rim, iterations=5)
    labels, count = ndimage.label(keep)
    if count == 0:
        return patch
    if count > 1:
        keep = labels == (np.argmax(ndimage.sum(keep, labels, range(1, count + 1))) + 1)
    ys, xs = np.nonzero(ndimage.binary_erosion(keep) ^ keep)
    hull = np.column_stack([xs, ys])
    hull = hull[ConvexHull(hull).vertices]
    outline = Image.new("L", patch.size, 0)
    ImageDraw.Draw(outline).polygon([tuple(p) for p in hull], fill=255)
    shape = np.asarray(outline) > 0
    if not RIM_MINIMUM * inside.sum() < (inside & ~shape).sum() < RIM_LIMIT * inside.sum():
        return patch
    trimmed_alpha = np.clip(ndimage.gaussian_filter(shape.astype(float), 0.9) * 1.4 - 0.2, 0, 1) * alpha
    cut = Image.fromarray(np.dstack([rgb, trimmed_alpha]).astype(np.uint8), "RGBA")
    ys, xs = np.nonzero(trimmed_alpha > 25)
    pad = 4
    cut = cut.crop((max(xs.min() - pad, 0), max(ys.min() - pad, 0), min(xs.max() + pad, patch.width), min(ys.max() + pad, patch.height)))
    scale = SIZE / max(cut.size)
    return cut.resize((round(cut.width * scale), round(cut.height * scale)), Image.LANCZOS)


def interior(patch: Image.Image) -> Image.Image:
    """Inside the cord, with everything else filled with the twill's colour and cropped to it: a picture in which the
    bird is the one object, so BiRefNet finds the bird and not the patch (it can take in leaves beside it)."""
    rgba = np.asarray(patch.convert("RGBA")).astype(float)
    rgb, inside = rgba[..., :3], rgba[..., 3] > 128
    dist = ndimage.distance_transform_edt(inside)
    inner = dist > CORD_DEPTH + 15
    if not inner.any():
        raise ValueError("no room inside the cord")
    ground = np.median(rgb[(dist > CORD_DEPTH + 5) & (dist < CORD_DEPTH + 20)], axis=0)
    filled = np.where(inner[..., None], rgb, ground).astype(np.uint8)
    ys, xs = np.nonzero(inner)
    return Image.fromarray(filled).crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


@dataclass(frozen=True)
class Layers:
    """What the app lights and animates (guide 2.0 page 13): the patch's colour on transparency, its height (thread
    relief plus the raised cord, 0..255), the cord's mask, the stitch order (0..255: one thread colour at a time,
    largest first, the cord last; `bounds` are the layers' starts) and the ground colour (the bare twill)."""

    colour: Image.Image
    height: Image.Image
    cord: Image.Image
    order: Image.Image
    bounds: tuple[int, ...]
    ground: tuple[int, int, int]


def layers(patch: Image.Image, colours: int = 9, seed: int = 3) -> Layers:
    """A cut patch's layers; deterministic for a patch and a seed."""
    rgba = np.asarray(patch.convert("RGBA")).astype(float)
    rgb, alpha = rgba[..., :3], rgba[..., 3]
    inside = alpha > 128
    dist = ndimage.distance_transform_edt(inside)
    cord = inside & (dist <= CORD_DEPTH)
    lightness = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    relief = lightness - ndimage.gaussian_filter(lightness, 5)
    relief = np.clip(relief / (np.std(relief) * 3 + 1e-3), -1, 1)
    rolled = np.where(dist <= CORD_DEPTH, np.sin(np.clip(dist / CORD_DEPTH, 0, 1) * np.pi), 0.0)
    height = np.where(inside, ndimage.gaussian_filter(0.55 + 0.22 * relief + 0.35 * rolled, 0.6), 0.0)

    quantized = np.asarray(Image.fromarray(rgb.astype(np.uint8)).quantize(colors=colours, method=Image.Quantize.MEDIANCUT))
    body = inside & ~cord
    counts = sorted(((int((quantized[body] == k).sum()), k) for k in range(colours)), reverse=True)
    ranked = [k for count, k in counts if count > 0]
    layer_count = len(ranked) + 1
    rows, cols = np.mgrid[0:rgb.shape[0], 0:rgb.shape[1]]
    sweep = ndimage.gaussian_filter((rows / rgb.shape[0]) * 0.75 + np.random.default_rng(seed).random(rows.shape) * 0.25, 2)
    sweep = (sweep - sweep.min()) / max(np.ptp(sweep), 1e-6)
    order = np.ones(rows.shape)
    for rank, k in enumerate(ranked):
        here = body & (quantized == k)
        order[here] = (rank + sweep[here] * 0.96) / layer_count
    angle = (np.arctan2(cols - rgb.shape[1] / 2, -(rows - rgb.shape[0] / 2)) / (2 * np.pi)) % 1.0
    order[cord] = (layer_count - 1 + angle[cord] * 0.98) / layer_count
    ground = np.median(rgb[(dist > CORD_DEPTH + 5) & (dist < CORD_DEPTH + 17)], axis=0)
    return Layers(
        colour=Image.fromarray(rgba.astype(np.uint8), "RGBA"),
        height=Image.fromarray(np.clip(height * 255, 0, 255).astype(np.uint8), "L"),
        cord=Image.fromarray((ndimage.gaussian_filter(cord.astype(float), 0.8) * 255).astype(np.uint8), "L"),
        order=Image.fromarray(np.clip(order * 255, 0, 255).astype(np.uint8), "L"),
        bounds=tuple(round(255 * r / layer_count) for r in range(layer_count + 1)),
        ground=tuple(int(c) for c in ground),
    )


def review(lock: PatchLock, approve: list[str] = (), reject: list[str] = (), gap: list[str] = (), approve_all: bool = False, why: str | None = None) -> None:
    """Records the maintainer's review, as for pack art; `approve_all` approves every pending patch (the measure only
    ranks, so nothing is held back by it)."""
    from packbuilder.pack_art import _find

    for name in approve:
        lock.species[_find(lock, name)]["review"] = APPROVED
    if approve_all:
        for entry in lock.species.values():
            if entry["review"] == PENDING:
                entry["review"] = APPROVED
    for name in reject:
        entry = lock.species[_find(lock, name)]
        if entry["review"] in (REJECTED, GAP):
            continue
        entry["rejected_seeds"] = [*entry.get("rejected_seeds", []), entry["seed"]]
        entry["review"] = REJECTED
        if why:
            entry["why"] = why
    for name in gap:
        entry = lock.species[_find(lock, name)]
        entry["review"] = GAP
        if why:
            entry["why"] = why
    lock.write()
