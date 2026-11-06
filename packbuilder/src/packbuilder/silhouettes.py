"""True silhouettes (#150): a bird still out there shows its own shape on a set page, so a goose looks like a goose.

A silhouette comes from the species' reference bird, already isolated on white in the art cache for its patch (`patch.lock.json`,
else `art.lock.json`; `art.silhouette.reference` in `overrides.json` pins another photo with a cached isolation). Nothing
is painted. `derive` takes everything that isn't paper, closes the holes that are plumage and not air, drops specks,
crops tight and smooths the outline. The picture is opaque white on transparency at `SIZE` on its longest side; the app
tints it at draw time.

The isolated bird's background is pure white because its mask put it there, so "not paper" is nearly exact: only plumage
blown to pure white looks like background. A hole in the bird is therefore either that (a Bald Eagle's head) or air (the
gap between a gull's legs, which must stay open). What the hole's surroundings are tells them apart: pale feathers, or
legs.

`silhouette.lock.json` beside the pack definition pins each species' silhouette: its photo and isolation seed, the
version of this recipe, the picture's SHA-256 (its file in `<cache>/art/silhouettes/`), what the recipe noticed, and the
review (pending, approved, rejected or gap, as for patches). The recipe is deterministic, so unlike a painting a rejected
silhouette would come back the same: it stays rejected until the species' reference changes, and until then the app
keeps its glyph. Only approved silhouettes go in the pack, as `silhouette/<species id>.png` with a `silhouette` row.
"""

from __future__ import annotations

import hashlib
import io
import logging
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from packbuilder.contact_sheets import grid
from packbuilder.pack_art import APPROVED, GAP, PENDING, REJECTED, UNPAINTED, ArtLock, _find
from packbuilder.patch_art import cached_isolations

log = logging.getLogger("packbuilder.silhouettes")

LOCK_FILE = "silhouette.lock.json"
VERSION = "silhouette@1"
"""The recipe's version: a new one derives every silhouette again, and one that comes out different is reviewed again."""
SIZE = 180
"""The picture's longest side: a set row's tile is about 67 points, three pixels a point."""
WORKING = SIZE * 4
"""The outline is smoothed at four times the size, so a bird that was small in its photo doesn't come out in steps."""
PAPER = 254
"""A pixel is paper when even its darkest channel reaches this. Anything laxer eats an egret: its plumage is 250 and up."""
SPECK = 0.01
"""A piece of the mask smaller than this share of the bird's biggest is a speck, not a detached toe."""
PINHOLE = 0.002
"""A hole smaller than this share of the bird is a flaw in the mask, whatever is around it."""
PALE = 200
RING = (4, 10)
"""A hole is plumage when the bird in a ring this far out from it (in pixels of the isolated bird, past the mask's soft
edge, which is pale on any bird) is mostly lighter than `PALE`."""
PALE_SHARE = 0.5
SMALL_SOURCE = 300
"""Under this many pixels on its longest side the bird was small in its photo: the sheet says so, as the outline is a guess."""
LEVELS = 16
"""Alpha steps: at 180 px nobody sees more, and it saves about a third of the file."""
TILE, TINT = (22, 57, 63), (168, 196, 190)
"""The set page's tile and tint in the mock, so the sheets show what the birder will see."""


@dataclass(frozen=True)
class Derived:
    """What `derive` makes of an isolated bird."""

    image: Image.Image
    """Opaque white on transparency (LA), tight around the bird, `SIZE` on its longest side."""
    png: bytes
    bird_pixels: int
    """The bird's longest side in the isolated picture."""
    holes_filled: int
    cut: list[str]
    """The sides of the picture the bird runs into: its reference is cut off there."""


@dataclass(frozen=True)
class Silhouette:
    """One species' silhouette as the step has it."""

    species_id: str
    review: str
    file: Path | None
    photos: tuple[int, ...] = ()

    @property
    def ships(self) -> bool:
        return self.review == APPROVED and self.file is not None

    @property
    def settled(self) -> bool:
        return self.ships or self.review == GAP


class SilhouetteLock(ArtLock):
    """`silhouette.lock.json`: per species id, what its silhouette was taken from and its review (see the module)."""

    COMMENT = (
        "True silhouettes (#150), written by `packbuilder silhouettes` and `packbuilder silhouette-review`; review on the contact sheets in "
        "build/pack-art/<pack id>/silhouettes/. Per species: the reference photo and isolation seed, the recipe's version, the picture's SHA-256 (its file in "
        "<cache>/art/silhouettes/), its size, what the recipe noticed (the bird's size in the isolated picture, holes filled, sides the frame cuts) and the review: "
        "pending, approved (in the pack), rejected (it stays out until art.silhouette.reference in overrides.json gives another bird) or gap (no silhouette; the app keeps its glyph; why)."
    )


def derive(bird_on_white: Image.Image) -> Derived:
    """The silhouette of a bird isolated on white. Raises ValueError when the picture is blank."""
    rgb = np.asarray(bird_on_white.convert("RGB")).astype(int)
    lightest = rgb.min(-1)
    bird = lightest < PAPER
    if not bird.any():
        raise ValueError("no bird on the white")
    labels, count = ndimage.label(bird)
    sizes = ndimage.sum(bird, labels, range(1, count + 1))
    bird = np.isin(labels, 1 + np.flatnonzero(sizes >= SPECK * sizes.max()))
    bird, holes = _fill_plumage(bird, lightest)
    ys, xs = np.nonzero(bird)
    height, width = bird.shape
    cut = [side for side, reached in (("top", ys.min() == 0), ("bottom", ys.max() == height - 1), ("left", xs.min() == 0), ("right", xs.max() == width - 1)) if reached]
    crop = bird[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    longest = max(crop.shape)
    image = _smoothed(crop)
    return Derived(image, _png(image), int(longest), holes, cut)


def _fill_plumage(bird: np.ndarray, lightest: np.ndarray) -> tuple[np.ndarray, int]:
    """`bird` with its plumage holes filled and its air holes left open, and how many it filled."""
    enclosed = ndimage.binary_fill_holes(bird) & ~bird
    labels, count = ndimage.label(enclosed)
    filled = bird.copy()
    done = 0
    area = bird.sum()
    # Each hole's own small window, not the whole picture: there can be a dozen, and the picture is 1536 px tall.
    margin = RING[1] + 1
    for number, window in enumerate(ndimage.find_objects(labels), start=1):
        y0, y1 = max(window[0].start - margin, 0), window[0].stop + margin
        x0, x1 = max(window[1].start - margin, 0), window[1].stop + margin
        hole = labels[y0:y1, x0:x1] == number
        if hole.sum() >= PINHOLE * area:
            near = ndimage.binary_dilation(hole, iterations=RING[0])
            far = ndimage.binary_dilation(near, iterations=RING[1] - RING[0])
            ring = far & ~near & bird[y0:y1, x0:x1]
            if not ring.any() or (lightest[y0:y1, x0:x1][ring] > PALE).mean() < PALE_SHARE:
                continue
        filled[y0:y1, x0:x1] |= hole
        done += 1
    return filled, done


def _smoothed(crop: np.ndarray) -> Image.Image:
    """The cropped mask with a smooth outline, in LA at `SIZE`, a pixel of margin keeping the antialiased edge whole."""
    scale = (WORKING - 8) / max(crop.shape)
    size = (max(round(crop.shape[1] * scale), 1), max(round(crop.shape[0] * scale), 1))
    grown = np.asarray(Image.fromarray((crop * 255).astype(np.uint8)).resize(size, Image.Resampling.BICUBIC)).astype(float) / 255
    padded = np.pad(grown, 4)
    outline = ndimage.gaussian_filter(padded, 2.0) > 0.5
    shape = Image.fromarray((outline * 255).astype(np.uint8)).resize((round(padded.shape[1] / 4), round(padded.shape[0] / 4)), Image.Resampling.LANCZOS)
    steps = LEVELS - 1
    alpha = shape.point(lambda value: round(value * steps / 255) * 255 // steps)
    return Image.merge("LA", (Image.new("L", shape.size, 255), alpha))


def _png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def sources(patch_lock: ArtLock, art_lock: ArtLock, pins: dict[str, int]) -> dict[str, tuple[int, int | None, str]]:
    """Each species' bird as (photo id, isolation seed, common name): its pin, with whichever isolation is cached; else
    its patch's reference; else its pack art's. A species painted from text has no bird."""
    found = {}
    for species_id in {*art_lock.species, *patch_lock.species}:
        entry = patch_lock.species.get(species_id) or art_lock.species[species_id]
        name = entry.get("common_name", species_id)
        if species_id in pins:
            found[species_id] = (pins[species_id], None, name)
        elif entry.get("photos"):
            found[species_id] = (entry["photos"][0], entry.get("isolate_seed"), name)
    return found


@dataclass
class SilhouetteMaker:
    """Derives what the lock lacks for one pack. `cache_dir` is the art cache (isolated birds in `isolated/`, silhouettes
    written to `silhouettes/`)."""

    pack_id: str
    lock: SilhouetteLock
    sources: dict[str, tuple[int, int | None, str]]
    cache_dir: Path
    derived: int = field(default=0, init=False)

    def __post_init__(self):
        self.cache_dir = Path(self.cache_dir)

    def make(self, species_ids: list[str]) -> dict[str, Silhouette]:
        """Every species' silhouette, deriving only what the lock lacks; one species' failure never stops the rest."""
        made = {}
        self.derived = 0
        for species_id in species_ids:
            try:
                made[species_id] = self._species(species_id)
            except (KeyError, ValueError, OSError) as error:
                log.error("  silhouette for %s failed: %s", species_id, error)
                made[species_id] = Silhouette(species_id, UNPAINTED, None)
        self.lock.write()
        log.info("silhouettes: %d derived, %d approved, %d to review, %d rejected, %d gaps", self.derived,
                 *(sum(s.review == state for s in made.values()) for state in (APPROVED, PENDING, REJECTED, GAP)))
        return made

    def _species(self, species_id: str) -> Silhouette:
        entry = self.lock.species.get(species_id)
        if entry is not None and entry["review"] == GAP:
            return Silhouette(species_id, GAP, None)
        if species_id not in self.sources:
            raise KeyError(f"{species_id}: its art was painted from text, so there is no bird to take a shape from")
        photo_id, seed, name = self.sources[species_id]
        same = entry is not None and entry["workflow"] == VERSION and entry["photos"] == [photo_id] and (seed is None or entry["isolate_seed"] == seed)
        if same and entry["review"] == REJECTED:
            return Silhouette(species_id, REJECTED, self._file(entry["sha256"]), (photo_id,))
        if same and self._file(entry["sha256"]).exists():
            return Silhouette(species_id, entry["review"], self._file(entry["sha256"]), (photo_id,))
        isolations = cached_isolations(self.cache_dir, photo_id)
        seed = min(isolations) if seed is None and isolations else seed
        if seed not in isolations:
            raise KeyError(f"{species_id}: no isolated bird for photo {photo_id} seed {seed} in {self.cache_dir / 'isolated'}")
        with Image.open(isolations[seed]) as bird:
            made = derive(bird)
        digest = hashlib.sha256(made.png).hexdigest()
        target = self._file(digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(made.png)
        self.derived += 1
        review_state = APPROVED if same and entry["review"] == APPROVED and entry["sha256"] == digest else PENDING
        self.lock.species[species_id] = {
            "common_name": name, "photos": [photo_id], "isolate_seed": seed, "workflow": VERSION, "sha256": digest,
            "width": made.image.width, "height": made.image.height, "bytes": len(made.png),
            "measure": {"bird_pixels": made.bird_pixels, "holes_filled": made.holes_filled, "cut": made.cut},
            "review": review_state,
        }
        return Silhouette(species_id, review_state, target, (photo_id,))

    def _file(self, digest: str) -> Path:
        return self.cache_dir / "silhouettes" / f"{digest}.png"

    def sheets(self, species_ids: list[str], made: dict[str, Silhouette], out_dir: Path, per_sheet: int = 20) -> list[Path]:
        """Contact sheets for the review: each species' isolated bird beside its silhouette in the app's tile, numbered
        as in the pack, what the recipe noticed under it, plus one overview of every silhouette."""
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        for old in [*out_dir.glob("sheet-*.jpg"), out_dir / "overview.jpg"]:
            old.unlink(missing_ok=True)
        cells = []
        for number, species_id in enumerate(species_ids, start=1):
            entry = self.lock.species.get(species_id, {})
            name = entry.get("common_name") or self.sources.get(species_id, (0, 0, species_id))[2]
            silhouette = made.get(species_id)
            picture = _in_tile(silhouette.file) if silhouette and silhouette.file and silhouette.file.exists() else None
            cells.append(((self._bird(species_id, entry), f"{number:03d} {name}\n{(silhouette.review if silhouette else UNPAINTED).upper()}"),
                          (picture, _noticed(entry))))
        sheets = []
        for start in range(0, len(cells), per_sheet):
            chunk = cells[start:start + per_sheet]
            rows = [[cell for pair in chunk[i:i + 5] for cell in pair] for i in range(0, len(chunk), 5)]
            target = out_dir / f"sheet-{start // per_sheet + 1:02d}.jpg"
            grid(rows, f"{self.pack_id} silhouettes {start + 1}-{start + len(chunk)} of {len(cells)}: the isolated bird, then its silhouette as a set page tints it", [], cell=(200, 200)).save(target, quality=88)
            sheets.append(target)
        overview = [[(cell[1][0], cell[0][1].split("\n")[0]) for cell in cells[i:i + 16]] for i in range(0, len(cells), 16)]
        if overview:
            target = out_dir / "overview.jpg"
            grid(overview, f"{self.pack_id} silhouettes, all {len(cells)}", [], cell=(120, 120)).save(target, quality=88)
            sheets.append(target)
        return sheets

    def _bird(self, species_id: str, entry: dict) -> Image.Image | None:
        """The isolated bird cropped close, so the sheet compares like with like."""
        photo_id, seed = (entry["photos"][0], entry["isolate_seed"]) if entry.get("photos") else self.sources.get(species_id, (None, None, ""))[:2]
        path = cached_isolations(self.cache_dir, photo_id).get(seed) if photo_id else None
        if path is None:
            return None
        with Image.open(path) as opened:
            bird = opened.convert("RGB")
        ys, xs = np.nonzero(np.asarray(bird).min(-1) < PAPER)
        return bird.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)) if len(xs) else bird


def _in_tile(path: Path, size: int = 200) -> Image.Image:
    """The silhouette tinted on the set page's tile, with the tile's margin."""
    with Image.open(path) as opened:
        alpha = opened.getchannel("A")
    side = round(size * 0.84)
    alpha.thumbnail((side, side), Image.Resampling.LANCZOS)
    if max(alpha.size) < side:
        scale = side / max(alpha.size)
        alpha = alpha.resize((round(alpha.width * scale), round(alpha.height * scale)), Image.Resampling.LANCZOS)
    tile = Image.new("RGB", (size, size), TILE)
    tile.paste(Image.new("RGB", alpha.size, TINT), ((size - alpha.width) // 2, (size - alpha.height) // 2), alpha)
    return tile


def _noticed(entry: dict) -> str:
    """What the recipe noticed, for the sheet: only what a reviewer should look at."""
    measure = entry.get("measure")
    if not measure:
        return "no silhouette"
    notes = []
    if measure["cut"]:
        notes.append(f"CUT BY FRAME: {', '.join(measure['cut'])}")
    if measure["bird_pixels"] < SMALL_SOURCE:
        notes.append(f"small bird: {measure['bird_pixels']} px")
    if entry.get("why"):
        notes.append(entry["why"])
    return " · ".join(notes) or f"{entry['bytes'] / 1024:.1f} KB"


def review(lock: SilhouetteLock, approve: list[str] = (), reject: list[str] = (), gap: list[str] = (), approve_all: bool = False, why: str | None = None) -> None:
    """Records the maintainer's review. `approve_all` approves whatever is still pending once the rest are recorded, so
    one answer can reject a few by name and approve the rest. Names are checked before anything changes."""
    resolved = {name: _find(lock, name) for name in (*approve, *reject, *gap)}
    for name in reject:
        entry = lock.species[resolved[name]]
        entry["review"] = REJECTED
        if why:
            entry["why"] = why
    for name in gap:
        entry = lock.species[resolved[name]]
        entry["review"] = GAP
        if why:
            entry["why"] = why
    for name in approve:
        entry = lock.species[resolved[name]]
        entry["review"] = APPROVED
        entry.pop("why", None)
    if approve_all:
        for entry in lock.species.values():
            if entry["review"] == PENDING:
                entry["review"] = APPROVED
    lock.write()
