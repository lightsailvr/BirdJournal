"""The mascot patches (issue #150, slice 11): the app's six birds in glasses, and the House Finch on its branch for the
places `PerchedBirdDrawing` is today, as embroidered patches in the language of the real ones (`packbuilder.patch_art`).

A mascot patch is painted on comfybox with the committed `mascot-patch` workflow from the app icon's bird, cut out of the
icon's ground with BiRefNet and laid on white, with the template in `art/mascot-prompts.json`. Each round paints a few
candidates per bird, in the looks the prompts' `round` lists, and cuts each from the card (`cut_from_card`, at 1024 px, the
size of an app icon). Nothing here measures the bird against its icon: a thread rendering of a 3D cartoon is meant to move
from it, and the patches' own measure only ever ranked. The maintainer picks from the numbered contact sheets.

`art/mascot/mascot.lock.json` pins each bird's latest round: the icon's SHA-256, the workflow and prompts versions, each
candidate's number (unique across rounds, so a number on an old sheet never means another painting), look, seed and
SHA-256 (its file in `<cache>/mascot/patches/`), and the review:

- `pending`: painted, not chosen yet. Nothing ships.
- `approved`: candidate `chosen` ships. `packbuilder mascot-review --approve <number>` writes it, its pale rim trimmed, to
  `art/mascot/approved/<bird>.png`, the one place the app takes a mascot from, and records its SHA-256; `approved` reads
  them back, and refuses a file that isn't the one the review chose.
- `rejected`: the next run paints a new round from new seeds with the current templates.

A warm lock paints nothing. A candidate no longer in the cache is painted again from its seed, which gives the same
picture on the same prompts version. A new icon or workflow starts a new round, since the review no longer applies; new
prompts don't, because the review is the costly part.
"""

from __future__ import annotations

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
from packbuilder.contact_sheets import font, grid
from packbuilder.covers import APPROVED, PENDING, REJECTED
from packbuilder.fidelity import on_white
from packbuilder.painting import Painter, png
from packbuilder.patch_art import PEEL_ATTEMPTS, PEEL_LIMIT, cut_from_card, peeled, trim_rim

log = logging.getLogger("packbuilder.mascot_art")

REPO = ART_DIR.parent
LOCK_PATH = ART_DIR / "mascot" / "mascot.lock.json"
APPROVED_FOLDER = "approved"
SIZE = 1024
"""The cut patch's longest side: an app icon's."""
BIRDS_PER_SHEET = 4
CELL = (340, 340)
FELT = (63, 72, 58)
"""The ground of the sheet's patches: a felt like the board's, since a patch is seen on felt and not on the card."""
RIM_MINIMUM = 0.002
"""The thinnest rim `trim_rim` takes here. A mascot's cord is saturated and big on an icon, so a thin crescent of card
that a pack's patch can keep still shows."""
ICON_INSET = 90
"""The size of the sheet's inset, which shows each patch as small as a home-screen icon reads (60 pt at 1.5x)."""


@dataclass(frozen=True)
class MascotBird:
    id: str
    title: str
    icon: str
    """The app icon's picture, relative to the repository."""
    markings: str
    round: tuple[tuple[str, str], ...]
    """What a round paints: (composition, ground) per candidate."""
    compositions: dict[str, str] = field(default_factory=dict)
    """A composition this bird swaps for its own."""


@dataclass(frozen=True)
class MascotPrompts:
    version: int
    template: str
    grounds: dict[str, dict[str, str]]
    compositions: dict[str, str]
    birds: tuple[MascotBird, ...]

    @classmethod
    def load(cls, path: Path = ART_DIR / "mascot-prompts.json") -> "MascotPrompts":
        data = json.loads(Path(path).read_text())
        default = data["round"]
        birds = tuple(MascotBird(bird["id"], bird["title"], bird["icon"], bird["markings"], tuple(map(tuple, bird.get("round", default))), bird.get("compositions", {}))
                      for bird in data["birds"])
        return cls(data["version"], data["template"], data["grounds"], data["compositions"], birds)

    def bird(self, bird_id: str) -> MascotBird:
        return next(bird for bird in self.birds if bird.id == bird_id)

    def render(self, bird: MascotBird, composition: str, ground: str) -> str:
        words = self.compositions[bird.compositions.get(composition, composition)]
        return self.template.format(twill=self.grounds[ground]["twill"], cord=self.grounds[ground]["cord"], markings=f" {bird.markings}", composition=words)


class MascotLock:
    """`mascot.lock.json`: per bird, its latest round and its review (see the module)."""

    COMMENT = (
        "The mascot patches (issue #150, slice 11), written by `packbuilder mascot` and `packbuilder mascot-review`; review on the contact sheets in "
        "build/mascot/. Per bird: the icon's SHA-256, the workflow and prompts versions, the round, each candidate's number (as on the sheet, never reused), "
        "composition, ground, seed and SHA-256 (its file in <cache>/mascot/patches/), and the review: pending, approved (candidate number `chosen` ships as "
        "`approved.file` beside this lock) or rejected (a new round from new seeds next run)."
    )

    def __init__(self, path: Path, birds: dict[str, dict], next_number: int = 1):
        self.path, self.birds, self.next_number = Path(path), birds, next_number

    @classmethod
    def load(cls, path: Path = LOCK_PATH) -> "MascotLock":
        path = Path(path)
        if not path.exists():
            return cls(path, {})
        document = json.loads(path.read_text())
        return cls(path, document["birds"], document["next_number"])

    def write(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps({"comment": self.COMMENT, "next_number": self.next_number, "birds": self.birds}, indent=2, ensure_ascii=False) + "\n")

    def approved_path(self, bird_id: str) -> Path:
        return self.path.parent / APPROVED_FOLDER / f"{bird_id}.png"


def _patch_file(cache_dir: Path, digest: str) -> Path:
    return Path(cache_dir) / "patches" / f"{digest}.png"


@dataclass
class MascotArtist:
    """Paints what the lock lacks. `cache_dir` holds the references and the patches; `repo` is where the icons are."""

    client: ComfyClient
    lock: MascotLock
    cache_dir: Path
    prompts: MascotPrompts = field(default_factory=MascotPrompts.load)
    repo: Path = REPO

    def __post_init__(self):
        self.cache_dir, self.repo = Path(self.cache_dir), Path(self.repo)
        self.painter = Painter(self.client)
        self.workflow = Workflow.load("mascot-patch")
        self.painted = 0

    def paint(self, only: list[str] = ()) -> None:
        """Every bird's round, painting only what the lock lacks; the lock is written after each painting, so a run resumes."""
        for bird in self.prompts.birds:
            if only and bird.id not in only:
                continue
            try:
                self._bird(bird)
            except (PaintingFailed, ValueError, OSError) as error:  # one bird's failure never stops the run
                log.error("  %s failed: %s", bird.id, error)
        log.info("mascot: %d painted", self.painted)

    def reference(self, bird: MascotBird) -> Image.Image:
        """The icon's bird on white, cut out once per icon."""
        icon = (self.repo / bird.icon).read_bytes()
        target = self.cache_dir / "references" / f"{hashlib.sha256(icon).hexdigest()}.png"
        if target.exists():
            return Image.open(target).convert("RGB")
        image = Image.open(io.BytesIO(icon)).convert("RGB")
        reference = on_white(image, self.painter.mask(image))
        target.parent.mkdir(parents=True, exist_ok=True)
        reference.save(target)
        return reference

    def _inputs(self, bird: MascotBird) -> dict:
        """What a reviewed round is painted again for. The prompts aren't among them: see the module."""
        return {"icon_sha256": hashlib.sha256((self.repo / bird.icon).read_bytes()).hexdigest(), "workflow": self.workflow.tag}

    def _bird(self, bird: MascotBird) -> None:
        entry = self.lock.birds.get(bird.id)
        inputs = self._inputs(bird)
        same = entry is not None and all(entry.get(key) == value for key, value in inputs.items())
        if same and entry["review"] == APPROVED:
            return  # the approved patch is committed; the other candidates are no longer needed
        if not same or entry["review"] == REJECTED:
            entry = self._new_round(bird, inputs, entry)
        reference = None
        for index, (composition, ground) in enumerate(self._planned(bird, entry)):
            have = entry["candidates"][index] if index < len(entry["candidates"]) else None
            if have is not None and _patch_file(self.cache_dir, have["sha256"]).exists():
                continue
            reference = reference or self.reference(bird)
            if have is not None:  # no longer cached: the same picture from its seed, with no second try
                have.update(self._paint(bird, reference, have["composition"], have["ground"], have["seed"], attempts=1))
            else:
                seed = zlib.crc32(f"mascot/{bird.id}/{entry['round']}/{index}".encode())
                number = self.lock.next_number
                self.lock.next_number += 1
                entry["candidates"].append({"number": number, "composition": composition, "ground": ground, **self._paint(bird, reference, composition, ground, seed)})
            self.lock.write()

    def _planned(self, bird: MascotBird, entry: dict) -> list[tuple[str, str]]:
        """The round's looks: those painted, then what the prompts plan beyond them for a round that was interrupted."""
        painted = [(candidate["composition"], candidate["ground"]) for candidate in entry["candidates"]]
        return painted + list(bird.round[len(painted):])

    def _new_round(self, bird: MascotBird, inputs: dict, entry: dict | None) -> dict:
        """A first round, one after a rejection, or one painted from other inputs (its review no longer applies)."""
        rejected = list(entry.get("rejected_seeds", [])) if entry else []
        round_ = entry["round"] + 1 if entry else 0
        fresh = {"title": bird.title, **inputs, "prompts": self.prompts.version, "round": round_, "candidates": [], "review": PENDING, "chosen": None}
        if rejected:
            fresh["rejected_seeds"] = rejected
        if entry and entry.get("why"):
            fresh["why"] = entry["why"]
        self.lock.approved_path(bird.id).unlink(missing_ok=True)  # any old choice no longer ships
        self.lock.birds[bird.id] = fresh
        self.lock.write()
        return fresh

    def _paint(self, bird: MascotBird, reference: Image.Image, composition: str, ground: str, seed: int, attempts: int = PEEL_ATTEMPTS) -> dict:
        """Paints the candidate with `seed`, then the next seeds while a corner of the card peels into the cut, keeping the
        cleanest, as for the patches."""
        prompt = self.prompts.render(bird, composition, ground)
        best = None
        for attempt in range(attempts):
            painting = self.client.paint(self.workflow, images=[(f"mascot-{bird.id}.png", png(reference))], prompt=prompt, seed=seed + attempt)
            raw = Image.open(io.BytesIO(painting.image)).convert("RGB")
            self.painted += 1
            cut = cut_from_card(raw, SIZE)
            card = peeled(cut)
            if best is None or card < best[0]:
                best = (card, seed + attempt, raw, cut, attempt + 1)
            if card <= PEEL_LIMIT:
                break
        card, seed, raw, cut, tries = best
        digest = self._store(cut, raw)
        log.info("  %s %s on %s: seed %d, %.1f s, card at edge %.3f", bird.id, composition, ground, seed, painting.seconds, card)
        return {"seed": seed, "sha256": digest, "card_at_edge": round(card, 4), "attempts": tries}

    def _store(self, cut: Image.Image, raw: Image.Image) -> str:
        data = png(cut)
        digest = hashlib.sha256(data).hexdigest()
        target = _patch_file(self.cache_dir, digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        raw.save(target.with_name(f"{digest}-raw.png"))
        return digest

    def sheets(self, out_dir: Path, per_sheet: int = BIRDS_PER_SHEET) -> list[Path]:
        return draw_sheets(self.lock, self.cache_dir, out_dir, self.prompts, self.repo, per_sheet)


def draw_sheets(lock: MascotLock, cache_dir: Path, out_dir: Path, prompts: MascotPrompts | None = None, repo: Path = REPO, per_sheet: int = BIRDS_PER_SHEET) -> list[Path]:
    """The contact sheets (`sheet-1.jpg`, ...): a row per bird, the icon first and then its candidates on felt, each with
    its number and an inset at home-screen size. Paints nothing."""
    prompts = prompts or MascotPrompts.load()
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("sheet-*.jpg"):
        old.unlink()
    rows = []
    for bird in prompts.birds:
        entry = lock.birds.get(bird.id)
        if entry is None:
            continue
        icon = repo / bird.icon
        cells = [(Image.open(icon).convert("RGB") if icon.exists() else None, f"{bird.title}\nthe app icon today")]
        for candidate in entry["candidates"]:
            path = _patch_file(cache_dir, candidate["sha256"])
            state = "APPROVED" if entry.get("chosen") == candidate["number"] else entry["review"].upper()
            edge = " · CARD AT EDGE" if candidate.get("card_at_edge", 0) > PEEL_LIMIT else ""
            cells.append((_sheet_picture(path, candidate["number"]) if path.exists() else None,
                          f"{candidate['number']}: {candidate['composition']} on {candidate['ground']}\n{state}{edge}{'' if path.exists() else ' · not cached'}"))
        rows.append(cells)
    made = []
    for start in range(0, len(rows), per_sheet):
        page = len(made) + 1
        target = out_dir / f"sheet-{page}.jpg"
        footer = [
            "Choose by number, one per bird: cd packbuilder && uv run packbuilder mascot-review --approve <number> --approve <number> ...",
            "None of a bird's: uv run packbuilder mascot-review --reject <bird> --why \"...\"  (then uv run packbuilder mascot paints it a new round). "
            f"Birds: {', '.join(bird.id for bird in prompts.birds)}.",
            "Inset: the patch at the size a home-screen icon is seen. Nothing ships until it is approved.",
        ]
        grid(rows[start:start + per_sheet], f"Mascot patches, sheet {page}: mascot prompts v{prompts.version}, FLUX.3 Image Klein", footer, cell=CELL).save(target, quality=90)
        made.append(target)
    return made


def shipped(patch: Image.Image) -> Image.Image:
    """A cut candidate as it would ship: without the pale rim of card along its side, which the sheets must show gone or not."""
    return trim_rim(patch.convert("RGBA"), SIZE, RIM_MINIMUM)


def _sheet_picture(path: Path, number: int) -> Image.Image:
    """The patch as it would ship, on felt, with its number in a corner and the small inset in the corner opposite. The
    circle leaves both free."""
    with Image.open(path) as opened:
        patch = shipped(opened)
    width, height = CELL
    canvas = Image.new("RGBA", CELL, (*FELT, 255))
    large = patch.copy()
    large.thumbnail((width - 16, height - 16), Image.Resampling.LANCZOS)
    canvas.alpha_composite(large, ((width - large.width) // 2, (height - large.height) // 2))
    small = patch.copy()
    small.thumbnail((ICON_INSET, ICON_INSET), Image.Resampling.LANCZOS)
    canvas.alpha_composite(small, (width - small.width - 2, height - small.height - 2))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((0, 0, 58, 40), fill=(248, 245, 237, 255))
    draw.text((6, 3), str(number), fill=(38, 51, 41), font=font(30))
    return canvas.convert("RGB")


def review(lock: MascotLock, cache_dir: Path, approve: list[int] = (), reject: list[str] = (), why: str | None = None) -> None:
    """Records the maintainer's choice: `approve` are candidates' numbers on the sheets, at most one per bird, each writing
    that bird's approved patch; `reject` turns a bird's round down, so the next run paints a new one. Raises ValueError,
    changing nothing, for a number not in a current round, a painting not cached, or two picks for one bird."""
    by_number = {candidate["number"]: bird_id for bird_id, entry in lock.birds.items() for candidate in entry["candidates"]}
    picks: dict[str, dict] = {}
    for number in approve:
        if number not in by_number:
            raise ValueError(f"no bird's current round has a candidate {number}; the numbers are on the sheets in build/mascot/")
        bird_id = by_number[number]
        entry = lock.birds[bird_id]
        if entry["review"] == REJECTED:
            raise ValueError(f"{bird_id}'s round was rejected: paint a new one with `packbuilder mascot` first")
        if bird_id in picks or bird_id in reject:
            raise ValueError(f"{bird_id} was given more than one answer")
        candidate = next(c for c in entry["candidates"] if c["number"] == number)
        if not _patch_file(cache_dir, candidate["sha256"]).exists():
            raise ValueError(f"candidate {number} isn't in the cache ({_patch_file(cache_dir, candidate['sha256'])}): run `packbuilder mascot` to paint it again from its seed")
        picks[bird_id] = candidate
    for bird_id in reject:
        if bird_id not in lock.birds:
            raise ValueError(f"no bird {bird_id} in {lock.path}")
    for bird_id, candidate in picks.items():
        entry = lock.birds[bird_id]
        with Image.open(_patch_file(cache_dir, candidate["sha256"])) as opened:
            patch = shipped(opened)
        target = lock.approved_path(bird_id)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(png(patch))
        entry["review"], entry["chosen"] = APPROVED, candidate["number"]
        entry["approved"] = {"file": f"{APPROVED_FOLDER}/{target.name}", "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}
        entry.pop("why", None)
    for bird_id in reject:
        entry = lock.birds[bird_id]
        if entry["review"] != REJECTED:  # rejecting twice before a repaint skips no round
            entry["rejected_seeds"] = [*entry.get("rejected_seeds", []), *(c["seed"] for c in entry["candidates"])]
            entry["review"], entry["chosen"] = REJECTED, None
            entry.pop("approved", None)
            lock.approved_path(bird_id).unlink(missing_ok=True)
        if why:
            entry["why"] = why
    lock.write()


class StaleApproval(ValueError):
    pass


def approved(lock: MascotLock) -> dict[str, Path]:
    """The patches that may ship, by bird. Raises StaleApproval when a file is missing or isn't the one the review chose."""
    patches = {}
    for bird_id, entry in lock.birds.items():
        if entry["review"] != APPROVED:
            continue
        path = lock.path.parent / entry["approved"]["file"]
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["approved"]["sha256"]:
            raise StaleApproval(f"{path} is missing or isn't {bird_id}'s approved patch: run `packbuilder mascot-review --approve {entry['chosen']}` again")
        patches[bird_id] = path
    return patches
