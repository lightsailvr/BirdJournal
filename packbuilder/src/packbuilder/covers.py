"""Set covers (issue #114): one illustrated landscape per regional set, for the Atlas tiles and the Listen tab's ready
state (design guide pages 3-4 and 14).

A cover is painted on comfybox with FLUX.3 Image Klein from text alone (`set-cover` workflow) in the set's
edition theme (`set.json`'s `edition.theme`), from the template in `art/cover-prompts.json`: a landscape with no bird in
focus, no text, no map and no location marker. It is illustrative, never evidence of where a sighting was. The canvas
is painted a little larger than the cover and cropped to its middle, which trims the ragged paper edge or white margin
the watercolour often ends in.

Each round paints `CANDIDATES` covers from consecutive seeds, and the contact sheet (`cover.jpg` in
`build/pack-art/<pack id>/`, beside the pack art's sheets) numbers them. `cover.lock.json` beside the pack definition
pins the round: the theme, workflow, prompts version and model it was painted with, each candidate's seed and SHA-256
(its file in the cover cache), and the maintainer's review:

- `pending`: painted, not chosen yet. Nothing ships.
- `approved`: candidate `chosen` ships, in the pack as `cover.avif` and in the pack index as a thumbnail.
- `rejected`: the next run paints a new round from new seeds (the rejected seeds and the reason stay in the lock).

Approval (`packbuilder cover-review --approve <n>`) writes `cover-thumbnail.jpg` beside the lock from the cached
painting and records its SHA-256; the pack index (`index.py`) carries that file, so the Atlas can show a set before
its pack is downloaded, without the publisher needing the cover cache. A run whose lock is warm (the same inputs, the
paintings cached) paints nothing; one whose cache is gone repaints from the locked seeds, which give the same picture,
and a repaint that differs goes back to review.
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import logging
import zlib
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw

from packbuilder.art import ART_DIR, Workflow
from packbuilder.comfy import ComfyClient, PaintingFailed
from packbuilder.contact_sheets import grid
from packbuilder.painting import png

log = logging.getLogger("packbuilder.covers")

LOCK_FILE = "cover.lock.json"
THUMBNAIL_FILE = "cover-thumbnail.jpg"
SHEET_FILE = "cover.jpg"
PENDING, APPROVED, REJECTED = "pending", "approved", "rejected"
UNPAINTED = "unpainted"
"""Not in the lock: painting failed (ComfyUI unreachable). Never in the pack."""
CANDIDATES = 4
"""Covers painted per round, for the maintainer to choose from."""
COVER_SIZE = (1536, 864)
"""16:9: the Atlas tiles (about 2.4:1) and the Listen header (about 3:2) crop it from the middle."""
CANVAS_SIZE = (1664, 944)
"""What the `set-cover` workflow paints (multiples of 16), cropped to the middle COVER_SIZE: 64 px off each side and
40 px off the top and bottom, past the paper edge FLUX.3's watercolours often end in."""
THUMBNAIL_SIZE = (480, 270)
THUMBNAIL_QUALITY = 72
BUNDLED_QUALITY = 90
"""About 480 KB a cover, the five about 2.4 MB together in the app (issue #150)."""
BUNDLE_FILE = "covers.json"
"""The index's thumbnail: about 30 KB of JPEG (40 KB in base64) per set, since the phone fetches the index (84 KB before
covers) on every refresh; enough for an Atlas tile until the pack, and its full cover, is downloaded. 512 x 288 at
quality 78 was 39 KB."""
MODEL = "FLUX.3 Image Klein"
CROP_GUIDES = (("Atlas", 2.4), ("Listen", 1.5))
"""The app's crops of a cover, as width over height, drawn faintly on the contact sheet."""


@dataclass(frozen=True)
class CoverPrompts:
    version: int
    template: str

    @classmethod
    def load(cls, path: Path = ART_DIR / "cover-prompts.json") -> "CoverPrompts":
        data = json.loads(Path(path).read_text())
        return cls(version=data["version"], template=data["template"])

    def render(self, theme: str) -> str:
        if not theme:
            raise ValueError("a cover is painted in its set's edition theme")
        return self.template.format(edition_theme=theme)


@dataclass(frozen=True)
class Cover:
    """A set's cover as the build has it."""

    review: str
    file: Path | None
    """The chosen painting in the cover cache; None while none is chosen or when painting failed."""
    seed: int | None = None
    workflow: str = ""
    """The workflow and prompts versions, as the pack's `cover.workflow_version`: "set-cover@1 cover-prompts@1"."""
    theme: str = ""
    model: str = MODEL

    @property
    def ships(self) -> bool:
        return self.review == APPROVED and self.file is not None


class CoverLock:
    """`cover.lock.json`: the set's latest round of covers and its review (see the module); `cover` is None before the
    first round."""

    COMMENT = (
        "The set's cover (issue #114), written by `packbuilder cover` or `packbuilder build` and by `packbuilder cover-review`; "
        "review on build/pack-art/<pack id>/cover.jpg. The edition theme, workflow, prompts version and model the round was "
        "painted with, each candidate's seed and SHA-256 (the cover cache's file name), and the review: pending, approved "
        "(candidate `chosen`, numbered from 1 as on the sheet, ships; `thumbnail` is the index's copy beside this file) or "
        "rejected (a new round of seeds next run)."
    )

    def __init__(self, path: Path, cover: dict | None):
        self.path, self.cover = Path(path), cover

    @classmethod
    def load(cls, path: Path) -> "CoverLock":
        path = Path(path)
        if not path.exists():
            return cls(path, None)
        document = json.loads(path.read_text())
        return cls(path, {key: value for key, value in document.items() if key != "comment"})

    def write(self) -> None:
        self.path.write_text(json.dumps({"comment": self.COMMENT, **(self.cover or {})}, indent=2, ensure_ascii=False) + "\n")

    @property
    def thumbnail_path(self) -> Path:
        return self.path.parent / THUMBNAIL_FILE


def round_seed(pack_id: str, round_: int) -> int:
    """The first seed of a round; its candidates take it and the next ones."""
    return zlib.crc32(f"{pack_id}/cover/{round_}".encode())


def workflow_version(entry: dict) -> str:
    return f"{entry['workflow']} cover-prompts@{entry['prompts']}"


def painting_path(cache_dir: Path, digest: str) -> Path:
    return Path(cache_dir) / f"{digest}.png"


@dataclass
class CoverPainter:
    """Paints what the lock lacks for one set and keeps the lock; `cache_dir` holds the paintings by SHA-256."""

    client: ComfyClient
    pack_id: str
    theme: str
    lock: CoverLock
    cache_dir: Path
    prompts: CoverPrompts = field(default_factory=CoverPrompts.load)
    candidates: int = CANDIDATES

    def __post_init__(self):
        self.cache_dir = Path(self.cache_dir)
        self.workflow = Workflow.load("set-cover")
        self.painted = 0

    def paint(self) -> Cover:
        """The set's cover, painting only what the lock lacks; a failure is logged and leaves the set without one."""
        try:
            cover = self._cover()
        except (PaintingFailed, OSError) as error:  # never stops the build: the pack ships without a cover
            log.error("  the %s cover failed: %s", self.pack_id, error)
            return Cover(UNPAINTED, None, theme=self.theme)
        log.info("set cover: %d painted, %s", self.painted, cover.review)
        return cover

    def _inputs(self) -> dict:
        """What a cover depends on, beside its seed: a locked round with other inputs is painted again."""
        return {"theme": self.theme, "workflow": self.workflow.tag, "prompts": self.prompts.version, "model": MODEL}

    def _cover(self) -> Cover:
        entry = self.lock.cover
        same = entry is not None and all(entry.get(key) == value for key, value in self._inputs().items())
        if same and entry["review"] == APPROVED:
            chosen = entry["candidates"][entry["chosen"] - 1]
            if not painting_path(self.cache_dir, chosen["sha256"]).exists():
                log.info("  the approved %s cover isn't cached; repainting it from its seed", self.pack_id)
                repainted = self._paint(chosen["seed"])
                if repainted != chosen["sha256"]:
                    log.warning("  the repainted %s cover differs from the locked one; back to review", self.pack_id)
                    entry["review"], entry["chosen"], chosen["sha256"] = PENDING, None, repainted
                    entry.pop("thumbnail", None)
                    self.lock.thumbnail_path.unlink(missing_ok=True)
                    self.lock.write()
            return self._as_cover(entry)
        if same and entry["review"] == PENDING:
            for candidate in entry["candidates"]:
                if not painting_path(self.cache_dir, candidate["sha256"]).exists():
                    candidate["sha256"] = self._paint(candidate["seed"])
                    self.lock.write()
            return self._as_cover(entry)

        # A first round, a rejected one, or one painted from other inputs (its review no longer applies).
        rejected = list(entry.get("rejected_seeds", [])) if entry else []
        round_ = entry["round"] + 1 if entry and entry["review"] == REJECTED else (entry or {}).get("round", 0)
        first = round_seed(self.pack_id, round_)
        fresh = {**self._inputs(), "round": round_, "candidates": [], "review": PENDING, "chosen": None}
        if rejected:
            fresh["rejected_seeds"] = rejected
        if entry and entry.get("why"):
            fresh["why"] = entry["why"]
        if entry and entry.get("thumbnail"):
            self.lock.thumbnail_path.unlink(missing_ok=True)  # the old choice no longer ships
        self.lock.cover = fresh
        for seed in range(first, first + self.candidates):
            fresh["candidates"].append({"seed": seed, "sha256": self._paint(seed)})
            self.lock.write()  # after each, so an interrupted run resumes
        return self._as_cover(fresh)

    def _paint(self, seed: int) -> str:
        painting = self.client.paint(self.workflow, images=[], prompt=self.prompts.render(self.theme), seed=seed)
        image = Image.open(io.BytesIO(painting.image)).convert("RGB")
        if image.size != CANVAS_SIZE:
            raise PaintingFailed(f"the {self.pack_id} cover came back {image.size[0]} x {image.size[1]}, not {CANVAS_SIZE[0]} x {CANVAS_SIZE[1]}")
        left, top = (CANVAS_SIZE[0] - COVER_SIZE[0]) // 2, (CANVAS_SIZE[1] - COVER_SIZE[1]) // 2
        data = png(image.crop((left, top, left + COVER_SIZE[0], top + COVER_SIZE[1])))
        digest = hashlib.sha256(data).hexdigest()
        target = painting_path(self.cache_dir, digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.painted += 1
        log.info("  %s cover: painted seed %d in %.1f s", self.pack_id, seed, painting.seconds)
        return digest

    def _as_cover(self, entry: dict) -> Cover:
        chosen = entry["candidates"][entry["chosen"] - 1] if entry["review"] == APPROVED and entry.get("chosen") else None
        return Cover(
            entry["review"], painting_path(self.cache_dir, chosen["sha256"]) if chosen else None, chosen["seed"] if chosen else None,
            workflow_version(entry), entry["theme"], entry["model"],
        )

    def sheet(self, out_dir: Path, edition: str = "") -> Path | None:
        """The contact sheet: the round's candidates numbered as `cover-review --approve` takes them, with the app's
        crops drawn faintly, the chosen one marked; None before any round."""
        entry = self.lock.cover
        if not entry or not entry["candidates"]:
            return None
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        cells = []
        for number, candidate in enumerate(entry["candidates"], start=1):
            path = painting_path(self.cache_dir, candidate["sha256"])
            image = _with_guides(path) if path.exists() else None
            state = "APPROVED" if entry["review"] == APPROVED and entry.get("chosen") == number else entry["review"].upper()
            cells.append((image, f"{number} · seed {candidate['seed']}\n{state}{'' if image else ' · not cached'}"))
        rows = [cells[i:i + 2] for i in range(0, len(cells), 2)]
        definition = f"packs/{self.pack_id}"
        footer = [
            f"Approve one: cd packbuilder && uv run packbuilder cover-review {definition} --approve <number>",
            f"None of them: uv run packbuilder cover-review {definition} --reject --why \"...\"  (then uv run packbuilder cover {definition} paints a new round)",
            "Guides: the middle 2.4:1 band (Atlas tiles) and the middle 3:2 (Listen header). No bird in focus, no text, map or marker.",
        ]
        title = f"{self.pack_id} cover{f', {edition}' if edition else ''}: \"{entry['theme']}\""
        footer.insert(0, f"Round {entry['round']}, {workflow_version(entry)}, {entry['model']}; 1536 x 864, cropped from the middle of the painted canvas.")
        target = out_dir / SHEET_FILE
        grid(rows, title, footer, cell=(768, 432)).save(target, quality=88)
        return target


def _with_guides(path: Path) -> Image.Image:
    with Image.open(path) as opened:
        image = opened.convert("RGB")
    draw = ImageDraw.Draw(image, "RGBA")
    width, height = image.size
    for _, ratio in CROP_GUIDES:
        crop_width, crop_height = min(width, height * ratio), min(height, width / ratio)
        left, top = (width - crop_width) / 2, (height - crop_height) / 2
        draw.rectangle((left, top, left + crop_width - 1, top + crop_height - 1), outline=(255, 252, 240, 150), width=4)
    return image


def review(lock: CoverLock, cache_dir: Path, approve: int | None = None, reject: bool = False, why: str | None = None) -> None:
    """Records the maintainer's choice: `approve` is a candidate's number on the sheet (from 1), which writes the
    index's thumbnail beside the lock from the cached painting; `reject` turns the whole round down, so the next run
    paints a new one. Raises ValueError for no round, a number out of range, both at once, or a painting not cached."""
    entry = lock.cover
    if not entry or not entry.get("candidates"):
        raise ValueError(f"{lock.path} has no cover yet: paint one with `packbuilder cover`")
    if (approve is None) == (not reject):
        raise ValueError("approve one candidate or reject the round")
    if approve is not None:
        if not 1 <= approve <= len(entry["candidates"]):
            raise ValueError(f"the round has candidates 1 to {len(entry['candidates'])}, not {approve}")
        if entry["review"] == REJECTED:
            raise ValueError("the round was rejected: paint a new one first")
        painting = painting_path(cache_dir, entry["candidates"][approve - 1]["sha256"])
        if not painting.exists():
            raise ValueError(f"candidate {approve} isn't in the cover cache ({painting}): run `packbuilder cover` to repaint it from its seed")
        entry["review"], entry["chosen"] = APPROVED, approve
        entry["thumbnail"] = {"file": THUMBNAIL_FILE, "sha256": write_thumbnail(painting, lock.thumbnail_path)}
        entry.pop("why", None)
    else:
        if entry["review"] != REJECTED:  # rejecting twice before a repaint skips no round
            entry["rejected_seeds"] = [*entry.get("rejected_seeds", []), *(c["seed"] for c in entry["candidates"])]
            entry["review"], entry["chosen"] = REJECTED, None
            entry.pop("thumbnail", None)
            lock.thumbnail_path.unlink(missing_ok=True)
        if why:
            entry["why"] = why
    lock.write()


def write_thumbnail(painting: Path, target: Path) -> str:
    """The index's thumbnail of a cover: THUMBNAIL_SIZE JPEG with no metadata; returns its SHA-256."""
    with Image.open(painting) as opened:
        image = opened.convert("RGB").resize(THUMBNAIL_SIZE, Image.Resampling.LANCZOS)
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=THUMBNAIL_QUALITY, optimize=True, progressive=True)
    data = buffer.getvalue()
    Path(target).write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def bundle_covers(definitions_dir: Path, cache_dir: Path, out_dir: Path, quality: int = BUNDLED_QUALITY) -> dict:
    """The approved covers the app ships (issue #150, slice 6), so the Listen painting works before a set's pack is on the
    phone and offline: `<pack id>.jpg` at the pack cover's size, and `covers.json` with each one's credit and the painting it
    came from. JPEG rather than the pack's AVIF, since AV1 decodes hold their thread and this one is decoded at launch. A set
    with no approved cover is left out; a chosen painting gone from the cache stops the run, rather than ship less."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    covers = {}
    for lock_path in sorted(Path(definitions_dir).glob(f"*/{LOCK_FILE}")):
        entry = CoverLock.load(lock_path).cover
        if not entry or entry.get("review") != APPROVED:
            continue
        chosen = entry["candidates"][entry["chosen"] - 1]
        painting = painting_path(cache_dir, chosen["sha256"])
        if not painting.exists():
            raise FileNotFoundError(f"{painting}: the approved cover of {lock_path.parent.name} isn't in the cache (`packbuilder cover {lock_path.parent}` paints it again from its seed)")
        with Image.open(painting) as opened:
            image = opened.convert("RGB")
        if image.size != COVER_SIZE:
            image = image.resize(COVER_SIZE, Image.Resampling.LANCZOS)
        file = f"{lock_path.parent.name}.jpg"
        image.save(out_dir / file, "JPEG", quality=quality, optimize=True, progressive=True)
        covers[lock_path.parent.name] = {
            "file": file, "model": entry["model"], "workflowVersion": workflow_version(entry), "seed": chosen["seed"], "painting": chosen["sha256"],
        }
    (out_dir / BUNDLE_FILE).write_text(json.dumps(covers, indent=2) + "\n")
    return covers


class StaleThumbnail(ValueError):
    pass


def index_cover(definition_dir: Path) -> dict | None:
    """The pack index's `cover` for a set: the approved cover's thumbnail (base64 JPEG) and its credit; None when the
    set has no approved cover. Raises StaleThumbnail when the committed thumbnail is missing or isn't the one the lock
    approved, so the index never shows a cover the review didn't choose."""
    lock = CoverLock.load(Path(definition_dir) / LOCK_FILE)
    entry = lock.cover
    if not entry or entry.get("review") != APPROVED:
        return None
    thumbnail = entry.get("thumbnail") or {}
    path = lock.path.parent / thumbnail.get("file", THUMBNAIL_FILE)
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != thumbnail.get("sha256"):
        raise StaleThumbnail(f"{path} is missing or isn't the approved cover's thumbnail: run `packbuilder cover-review {Path(definition_dir)} --approve {entry.get('chosen')}` again")
    chosen = entry["candidates"][entry["chosen"] - 1]
    return {
        "thumbnail": base64.b64encode(path.read_bytes()).decode("ascii"),
        "width": THUMBNAIL_SIZE[0], "height": THUMBNAIL_SIZE[1],
        "model": entry["model"], "workflowVersion": workflow_version(entry), "seed": chosen["seed"],
    }
