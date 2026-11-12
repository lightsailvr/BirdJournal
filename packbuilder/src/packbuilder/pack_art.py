"""Pack art (issue #57): one painting per species per pack, so that every card has art the moment it exists.

The build paints on comfybox over the tailnet with the committed `pack-art` workflow (`art/`), in the set's edition
theme (`sets.Edition.theme`). The reference is the species' best-lit photo among the pack's open-license photos
(`lighting`; the lens score favours a dark background, and the colour fit makes a dim reference a dim bird), or the one
`overrides.json` pins as `art.reference`. The bird is isolated on white first and every painting goes through the
fidelity gate (`packbuilder.painting`). A species with no photo is painted from text alone (`pack-art-text`).

`art.lock.json` beside the pack definition pins each species' painting: its source photo, workflow, prompts and theme,
its seeds, the painting's SHA-256 and the maintainer's review. A painting is in the art cache under its SHA-256, so a
rebuild whose lock is warm (the same inputs, the painting cached) paints nothing; one whose cache is gone repaints
from the locked seeds, which give the same picture. The review happens on the contact sheets the build draws:

- `pending`: painted, not reviewed yet. Only `approved` art goes into the pack.
- `approved`: in the pack.
- `rejected`: painted again by the next build with the next round of seeds (the rejected seeds and the reason stay
  in the lock).
- `gap`: the maintainer gave up on it; its cards show another pack's art of the species, else the reference photo.
  Listed in report.json's `gaps.art`; it stays a gap until its lock entry is deleted.

`--approve-all` approves only faithful paintings from a photo: a painting from text, or one the gate flagged, needs an
`--approve` of its own.

Since the patch is the only painting (#131, #137), a pack whose edition has a patch paints no pack art.
`isolate_references` does the half of this step its patches and silhouettes still need (#58): it picks each species' reference the same
way, isolates the bird on white into the same cache and pins it in the same lock, as a `reference` entry with no
painting.
"""

from __future__ import annotations

import hashlib
import io
import json
import logging
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import requests
from PIL import Image

from packbuilder.art import ArtPrompts, ArtSetting, Species, Workflow, length_cm, reference_crop
from packbuilder.comfy import ComfyClient, PaintingFailed
from packbuilder.contact_sheets import grid
from packbuilder.crops import upright
from packbuilder.download import fetch
from packbuilder.fidelity import lab
from packbuilder.geometry import Box
from packbuilder.painting import ATTEMPTS, ISOLATE_SEED, Painter, png
from packbuilder.writer import ChosenPhoto, SpeciesResult

log = logging.getLogger("packbuilder.pack_art")

LOCK_FILE = "art.lock.json"
PENDING, APPROVED, REJECTED, GAP = "pending", "approved", "rejected", "gap"
UNPAINTED = "unpainted"
"""Not in the lock: the painting failed (ComfyUI unreachable, no bird to measure). Never in the pack."""
REFERENCE = "reference"
"""A reference bird alone: picked and isolated for the species' patch and silhouette, with no painting (`isolate_references`)."""
ISOLATE_ROUND = 10
"""A rejected painting's next isolation starts this many seeds on, past the previous round's retries."""
CROPS = "reference-crops"
"""The cache folder of exported reference crops, `<photo id>.png` (`export_references`)."""


@dataclass(frozen=True)
class Artwork:
    """One species' pack art as the build has it."""

    species_id: str
    review: str
    file: Path | None
    """The painting, colours fitted, in the art cache; None for a gap or a painting that failed."""
    photos: tuple[int, ...] = ()
    """The iNaturalist ids of the photos it was painted from; empty for a painting from text."""
    workflow: str = ""
    """The workflow, isolation and prompts versions, as the pack's `pack_art.workflow_version`: "pack-art@3
    bird-isolate@1 prompts@8"."""
    faithful: bool | None = None
    """Whether the bird passed the fidelity gate; None for a painting from text, which has no photo to match."""

    @property
    def ships(self) -> bool:
        return self.review == APPROVED and self.file is not None

    @property
    def is_gap(self) -> bool:
        return self.review == GAP

    @property
    def settled(self) -> bool:
        """Shipped or a listed gap: nothing left to review."""
        return self.ships or self.is_gap


class ArtLock:
    """`art.lock.json`: per species id, what its pack art was painted from and its review (see the module)."""

    COMMENT = (
        "Pack art (issue #57), written by `packbuilder build` and `packbuilder art-review`; review on the contact sheets in "
        "build/pack-art/<pack id>/. Per species: the source photo ids, the workflow, isolation and prompts versions and the "
        "set's edition theme it was painted with, the seeds, the painting's SHA-256 (the art cache's file name), its fidelity, "
        "and the review: pending, approved (in the pack), rejected (repainted with new seeds by the next build) or gap (no art; why)."
    )

    def __init__(self, path: Path, species: dict[str, dict]):
        self.path, self.species = Path(path), species

    @classmethod
    def load(cls, path: Path) -> "ArtLock":
        path = Path(path)
        return cls(path, json.loads(path.read_text())["species"] if path.exists() else {})

    def write(self) -> None:
        document = {"comment": self.COMMENT, "species": dict(sorted(self.species.items()))}
        self.path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")


def lighting(image: Image.Image, box: Box) -> float:
    """How well lit the bird in `box` is, from 0 to 1: the light on the bird (the 75th percentile of L* over the middle
    of its box, full marks from L* 60), less when the frame around it is much brighter than the bird (backlit, a
    silhouette against the sky) and less for blown highlights. It compares one species' photos with each other, so a
    sooty bird is not held against a white one."""
    small = image.convert("RGB")
    small.thumbnail((512, 512))
    lightness = lab(small)[..., 0]
    height, width = lightness.shape
    x0, y0, x1, y1 = box.clamped().pixels((width, height))
    bird_width, bird_height = max(x1 - x0, 1), max(y1 - y0, 1)
    middle = lightness[y0 + bird_height // 4: max(y1 - bird_height // 4, y0 + 1), x0 + bird_width // 4: max(x1 - bird_width // 4, x0 + 1)]
    around = lightness[max(0, y0 - bird_height // 2): min(height, y1 + bird_height // 2), max(0, x0 - bird_width // 2): min(width, x1 + bird_width // 2)]
    ring_pixels = around.size - lightness[y0:y1, x0:x1].size
    ring = (around.sum() - lightness[y0:y1, x0:x1].sum()) / ring_pixels if ring_pixels > 0 else 0.0
    bird = float(np.percentile(middle, 75))
    exposure = min(1.0, bird / 60)
    backlight = float(np.clip(1 - max(0.0, ring - bird - 10) / 50, 0.2, 1.0))
    blown = float((middle > 97).mean())
    return exposure * backlight * (1 - blown)


def pick_reference(photos: list[ChosenPhoto], pinned: int | None = None) -> ChosenPhoto | None:
    """The photo to paint from: the pinned one while the pack has it, else the best lit (the pack's order breaks a
    tie)."""
    if not photos:
        return None
    for chosen in photos:
        if chosen.candidate.photo_id == pinned:
            return chosen
    scores = []
    for rank, chosen in enumerate(photos):
        with Image.open(chosen.original) as opened:
            scores.append((lighting(upright(opened), chosen.scored.box), -rank))
    return photos[max(range(len(photos)), key=lambda i: scores[i])]


@dataclass
class PackArtist:
    """Paints what the lock lacks for one pack and keeps the lock: `cache_dir` holds the paintings (by SHA-256) and the
    isolated reference birds; `references` pins a species' reference photo by species id (`art.reference`)."""

    client: ComfyClient
    pack_id: str
    theme: str
    lock: ArtLock
    cache_dir: Path
    references: dict[str, int] = field(default_factory=dict)
    settings: dict[str, ArtSetting] = field(default_factory=dict)
    """Each species' setting by species id (`art.setting` and `art.length_cm`); a species without one lets the model
    choose, and takes its length from its description."""
    prompts: ArtPrompts = field(default_factory=ArtPrompts.load)

    def __post_init__(self):
        self.cache_dir = Path(self.cache_dir)
        self.painter = Painter(self.client)
        self.workflow = Workflow.load("pack-art")
        self.text_workflow = Workflow.load("pack-art-text")
        self.painted = 0

    def paint(self, results: list[SpeciesResult]) -> dict[str, Artwork]:
        """Every species' art, painting only what the lock lacks; the lock is written after each painting, so an
        interrupted run resumes."""
        art = {}
        for result in results:
            try:
                art[result.entry.id] = self._species(result)
            except (PaintingFailed, ValueError, OSError, KeyError) as error:  # one species' failure never stops the run
                log.error("  pack art for %s failed: %s", result.entry.common_name, error)
                art[result.entry.id] = Artwork(result.entry.id, UNPAINTED, None)
        log.info("pack art: %d painted, %d approved, %d to review, %d gaps", self.painted,
                 *(sum(a.review == state for a in art.values()) for state in (APPROVED, PENDING, GAP)))
        return art

    def isolate_references(self, results: list[SpeciesResult]) -> dict[str, int]:
        """Each species' reference photo by species id, isolating the bird of every species whose lock entry names no
        photo of the pack or whose isolated bird left the cache, and painting nothing (#58). The lock is written after
        each, so an interrupted run resumes. A species with no photo gets no reference, and so no patch."""
        chosen: dict[str, int] = {}
        isolated = 0
        for result in results:
            try:
                reference, seed = self._pick(result)
                if reference is not None and seed is not None:
                    self._isolate(result.entry.id, result.entry.common_name, reference.candidate.photo_id, _reference_crop(reference), seed)
                    isolated += 1
            except (PaintingFailed, ValueError, OSError, KeyError) as error:  # one species' failure never stops the run
                log.error("  reference bird for %s failed: %s", result.entry.common_name, error)
                continue
            if reference is not None:
                chosen[result.entry.id] = reference.candidate.photo_id
        log.info("reference birds: %d isolated, %d in all, %d species without one", isolated, len(chosen), len(results) - len(chosen))
        return chosen

    def export_references(self, results: list[SpeciesResult]) -> list[dict]:
        """The reference birds still to isolate, each with its photo's Open Data address and the bird's box in it: all
        that `isolate_exported` needs, so the isolations can run where ComfyUI is, on a machine with neither the pack's
        photos nor the detector. The tailnet relays at 60 to 400 KB/s and an isolation sends and fetches several
        pictures, so the box fetches the photo itself and cuts the same crop. The crop is also saved in the cache's
        `reference-crops/`, which `isolate_exported` takes first when it is run on this machine."""
        todo = []
        for result in results:
            reference, seed = self._pick(result)
            if reference is None or seed is None:
                continue
            candidate, box = reference.candidate, reference.scored.box
            target = self.cache_dir / CROPS / f"{candidate.photo_id}.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            _reference_crop(reference).save(target)
            todo.append({"species": result.entry.id, "common_name": result.entry.common_name, "photo": candidate.photo_id, "seed": seed,
                         "url": candidate.photo_url("original"), "extension": candidate.extension, "box": [box.x0, box.y0, box.x1, box.y1]})
        log.info("reference birds: %d to isolate, their crops in %s", len(todo), self.cache_dir / CROPS)
        return todo

    def isolate_exported(self, todo: list[dict]) -> int:
        """Isolates the birds `export_references` listed, from their crops in the cache, and pins them in the lock;
        how many it isolated. One that is already there (a run resumed) is left alone."""
        isolated = 0
        for item in todo:
            entry = self.lock.species.get(item["species"])
            if entry and entry.get("photos") == [item["photo"]] and self._has_isolation(item["photo"], entry.get("isolate_seed") or ISOLATE_SEED):
                continue
            try:
                self._isolate(item["species"], item["common_name"], item["photo"], self._exported_crop(item), item["seed"])
                isolated += 1
            except (PaintingFailed, ValueError, OSError, KeyError, requests.RequestException) as error:
                log.error("  reference bird for %s failed: %s", item["common_name"], error)
        log.info("reference birds: %d isolated of %d listed", isolated, len(todo))
        return isolated

    def _exported_crop(self, item: dict) -> Image.Image:
        """An exported reference's crop: the one in the cache, else cut from the photo's original, fetched from the Open
        Data bucket into the cache's `photos/original/` beside the art cache, by the box the export recorded."""
        saved = self.cache_dir / CROPS / f"{item['photo']}.png"
        if saved.exists():
            with Image.open(saved) as opened:
                return opened.convert("RGB")
        original = fetch(item["url"], self.cache_dir.parent / "photos" / "original" / f"{item['photo']}.{item['extension']}")
        with Image.open(original) as opened:
            return reference_crop(upright(opened), Box(*item["box"]))

    def _pick(self, result: SpeciesResult) -> tuple[ChosenPhoto | None, int | None]:
        """The species' reference photo, and the seed its isolation starts from when its bird is still to isolate (None
        when the lock names it and the cache has it). The locked photo is kept while the pack has it, as a painting's
        is, unless `art.reference` pins another of the pack's photos."""
        name, entry = result.entry.common_name, self.lock.species.get(result.entry.id)
        pinned = self.references.get(result.entry.id)
        if pinned is not None and all(chosen.candidate.photo_id != pinned for chosen in result.photos):
            log.warning("  %s: art.reference %d is not one of the pack's photos; taking the best-lit one", name, pinned)
        locked = entry["photos"][0] if entry and entry.get("photos") else None
        reference = pick_reference(result.photos, pinned if pinned is not None else locked)
        if reference is None:
            log.warning("  %s: no photo, so no reference bird and no patch", name)
            return None, None
        photo_id = reference.candidate.photo_id
        if photo_id == locked and self._has_isolation(photo_id, entry.get("isolate_seed") or ISOLATE_SEED):
            return reference, None
        if locked is not None and photo_id != locked:
            log.info("  %s: its reference was photo %d; now photo %d, so its patch is painted again", name, locked, photo_id)
        return reference, self._first_seed(entry) if photo_id == locked else ISOLATE_SEED

    def _isolate(self, species_id: str, name: str, photo_id: int, crop: Image.Image, seed: int) -> None:
        """Isolates one reference bird from its crop and pins it in the lock as a `reference` entry."""
        isolation = self._isolated(photo_id, crop, self.painter.mask(crop), seed, ATTEMPTS)
        flag = "" if isolation.fitted["faithful"] else "  REVIEW: not faithful"
        log.info("  %s: photo %d isolated, seed %d, dE %.1f, iou %.2f%s", name, photo_id, isolation.seed, isolation.fitted["dE_mean"], isolation.fitted["iou"], flag)
        self.lock.species[species_id] = {
            "common_name": name, "photos": [photo_id], "isolate": self.painter.isolate_workflow.tag, "first_isolate_seed": seed, "isolate_seed": isolation.seed,
            "faithful": isolation.fitted["faithful"], "fidelity": {"isolated": isolation.fitted}, "review": REFERENCE,
        }
        self.lock.write()

    @staticmethod
    def _first_seed(entry: dict | None) -> int:
        """The seed an entry's isolation started from, which names its file in the cache: a reference entry records it;
        a painting's is the default for its round (its `isolate_seed` is the attempt that was kept)."""
        if entry is None:
            return ISOLATE_SEED
        if "first_isolate_seed" in entry:
            return entry["first_isolate_seed"]
        return ISOLATE_SEED + ISOLATE_ROUND * len(entry.get("rejected_seeds", []))

    def _has_isolation(self, photo_id: int, kept_seed: int) -> bool:
        """Whether the cache holds the photo's bird as isolated with `kept_seed`, the seed the lock records and the
        patch step looks it up by (`patch_art.cached_isolations`): the file is named by the first seed tried, and its
        info records the one that was kept."""
        for image in (self.cache_dir / "isolated").glob(f"{self._isolation_key(photo_id, 0).replace('-s0-', '-s*-')}.png"):
            info = image.with_suffix(".json")
            seed = json.loads(info.read_text())["seed"] if info.exists() else int(image.name.split("-s", 1)[1].split("-", 1)[0])
            if seed == kept_seed:
                return True
        return False

    def _isolation_key(self, photo_id: int, seed: int) -> str:
        prompt = hashlib.sha256(self.prompts.isolate.encode()).hexdigest()[:10]
        return f"{photo_id}-s{seed}-{self.painter.isolate_workflow.tag}-i{prompt}"

    def _species(self, result: SpeciesResult) -> Artwork:
        entry_id = result.entry.id
        entry = self.lock.species.get(entry_id)
        if entry is not None and entry["review"] == GAP:
            return Artwork(entry_id, GAP, None, tuple(entry["photos"]), self._version(entry))
        pinned = self.references.get(entry_id)
        if pinned is not None and all(chosen.candidate.photo_id != pinned for chosen in result.photos):
            log.warning("  %s: art.reference %d is not one of the pack's photos; painting from the best-lit one", result.entry.common_name, pinned)
        locked = entry["photos"][0] if entry and entry["photos"] else None
        reference = pick_reference(result.photos, pinned if pinned is not None else locked)
        inputs = self._inputs(result, reference)
        same = entry is not None and all(entry.get(key) == value for key, value in inputs.items())

        if same and entry["review"] in (PENDING, APPROVED):
            cached = self._painting(entry["sha256"])
            if cached.exists():
                return self._artwork(entry_id, entry)
            log.info("  %s: the locked painting isn't cached; repainting it from its seeds", result.entry.common_name)
            fresh = self._render(result, reference, entry["seed"], entry.get("isolate_seed"), attempts=1)
            if fresh["sha256"] != entry["sha256"]:
                log.warning("  %s: the repainted picture differs from the locked one; back to review", result.entry.common_name)
                fresh["review"] = PENDING
            else:
                fresh["review"] = entry["review"]
            return self._keep(result, fresh, entry)

        rejected = list(entry.get("rejected_seeds", [])) if entry else []
        round_ = len(rejected)
        seed = zlib.crc32(f"{self.pack_id}/{result.entry.scientific_name}/pack-art/{round_}".encode())
        fresh = self._render(result, reference, seed, ISOLATE_SEED + ISOLATE_ROUND * round_ if reference else None)
        fresh["review"] = PENDING
        return self._keep(result, fresh, entry)

    def _inputs(self, result: SpeciesResult, reference: ChosenPhoto | None) -> dict:
        """What a painting depends on, beside its seeds: a locked painting with other inputs is painted again."""
        return {
            "photos": [reference.candidate.photo_id] if reference else [],
            "workflow": (self.workflow if reference else self.text_workflow).tag,
            "isolate": self.painter.isolate_workflow.tag if reference else None,
            "prompts": self.prompts.version,
            "theme": self.theme,
            "setting": self._setting(result).kind,
        }

    def _setting(self, result: SpeciesResult) -> ArtSetting:
        pinned = self.settings.get(result.entry.id, ArtSetting())
        described = length_cm(result.description.size) if result.description else None
        return ArtSetting(pinned.kind, pinned.length_cm or described)

    def _render(self, result: SpeciesResult, reference: ChosenPhoto | None, seed: int, isolate_seed: int | None, attempts: int = ATTEMPTS) -> dict:
        """Paints one species' art and stores it in the cache; the lock entry for it, without the review."""
        entry = result.entry
        species = Species(entry.common_name, entry.scientific_name)
        if reference is None:
            prompt = self.prompts.render_from_text(species, self.theme, self._setting(result))
            painting = self.client.paint(self.text_workflow, images=[], prompt=prompt, seed=seed)
            raw = Image.open(io.BytesIO(painting.image)).convert("RGB")
            self.painted += 1
            log.info("  %s: painted from text (no photo), seed %d; review it by hand", entry.common_name, seed)
            return {"common_name": entry.common_name, **self._inputs(result, None), "seed": seed, "isolate_seed": None, "sha256": self._store(raw, raw), "faithful": None, "attempts": 1, "fidelity": None}

        crop = _reference_crop(reference)
        crop_mask = self.painter.mask(crop)
        isolation = self._isolated(reference.candidate.photo_id, crop, crop_mask, isolate_seed, attempts)
        prompt = self.prompts.render("pack", species, self.pack_id, theme=self.theme, setting=self._setting(result))
        images = [(f"bird-{reference.candidate.photo_id}.png", png(isolation.image))]
        best, tries = self.painter.best_of(self.workflow, images, prompt, seed, crop, crop_mask, f"pack-art/{entry.id}", attempts=attempts)
        self.painted += 1
        flag = "" if best.after.faithful else "  REVIEW: not faithful"
        log.info("  %s: painted from photo %d, seed %d, dE %.1f -> %.1f, iou %.2f, %d attempt(s)%s", entry.common_name, reference.candidate.photo_id,
                 best.seed, best.before.dE_mean, best.after.dE_mean, best.after.iou, tries, flag)
        return {
            "common_name": entry.common_name, **self._inputs(result, reference), "seed": best.seed, "isolate_seed": isolation.seed, "sha256": self._store(best.fitted, best.raw),
            "faithful": best.after.faithful and isolation.fitted["faithful"], "attempts": tries,
            "fidelity": {"painted": best.before.as_dict(), "fitted": best.after.as_dict(), "isolated": isolation.fitted},
        }

    def _isolated(self, photo_id: int, crop: Image.Image, crop_mask: np.ndarray, seed: int, attempts: int) -> "_Isolated":
        """The reference bird on white, cached by photo, seed, workflow and isolation prompt (not the prompts version,
        which a pack-art template bumps), so a repainted species reuses it."""
        key = self._isolation_key(photo_id, seed)
        image_path, info_path = self.cache_dir / "isolated" / f"{key}.png", self.cache_dir / "isolated" / f"{key}.json"
        if image_path.exists() and info_path.exists():
            info = json.loads(info_path.read_text())
            return _Isolated(Image.open(image_path).convert("RGB"), info["seed"], info["fitted"])
        isolation = self.painter.isolate(crop, crop_mask, self.prompts.isolate, str(photo_id), seed=seed, attempts=attempts)
        isolated = _Isolated(isolation.image, isolation.attempt.seed, isolation.attempt.after.as_dict())
        image_path.parent.mkdir(parents=True, exist_ok=True)
        isolated.image.save(image_path)
        info_path.write_text(json.dumps({"seed": isolated.seed, "attempts": isolation.attempts, "fitted": isolated.fitted}) + "\n")
        return isolated

    def _store(self, fitted: Image.Image, raw: Image.Image) -> str:
        data = png(fitted)
        digest = hashlib.sha256(data).hexdigest()
        target = self._painting(digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        raw.save(target.with_name(f"{digest}-raw.png"))
        return digest

    def _painting(self, digest: str) -> Path:
        return self.cache_dir / "paintings" / f"{digest}.png"

    def _keep(self, result: SpeciesResult, fresh: dict, previous: dict | None) -> Artwork:
        """Records a painting in the lock, keeping the review history of the one it replaces."""
        for key in ("rejected_seeds", "why"):
            if previous and previous.get(key):
                fresh[key] = previous[key]
        self.lock.species[result.entry.id] = fresh
        self.lock.write()
        return self._artwork(result.entry.id, fresh)

    def _artwork(self, species_id: str, entry: dict) -> Artwork:
        return Artwork(species_id, entry["review"], self._painting(entry["sha256"]), tuple(entry["photos"]), self._version(entry), entry.get("faithful"))

    @staticmethod
    def _version(entry: dict) -> str:
        return " ".join(filter(None, [entry["workflow"], entry.get("isolate"), f"prompts@{entry['prompts']}"]))

    def sheets(self, results: list[SpeciesResult], art: dict[str, Artwork], out_dir: Path, per_sheet: int = 12) -> list[Path]:
        """Contact sheets for the review: each species' reference crop beside its painting, with its state, numbered in
        the pack's order, `per_sheet` species to a sheet, plus one overview of every painting."""
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        for old in [*out_dir.glob("sheet-*.jpg"), out_dir / "overview.jpg"]:  # its own sheets only: the set's cover.jpg stays
            old.unlink(missing_ok=True)
        cells = []
        for number, result in enumerate(results, start=1):
            artwork = art.get(result.entry.id)
            entry = self.lock.species.get(result.entry.id, {})
            reference = next((c for c in result.photos if artwork and c.candidate.photo_id in artwork.photos), None)
            if reference is not None:
                crop = _reference_crop(reference)
                crop.thumbnail((576, 768))
                photo_cell = (crop, f"{number:03d} {result.entry.common_name}\nphoto {reference.candidate.photo_id}, {reference.candidate.normalized_license}")
            else:
                photo_cell = (None, f"{number:03d} {result.entry.common_name}\nno photo: painted from text")
            painting = _thumbnail(artwork.file) if artwork and artwork.file and artwork.file.exists() else None
            fitted = (entry.get("fidelity") or {}).get("fitted")
            measured = f"dE {fitted['dE_mean']:.1f} iou {fitted['iou']:.2f}" if fitted else "not measured"
            flag = "" if entry.get("faithful", True) is not False else " · NOT FAITHFUL"
            state = artwork.review if artwork else UNPAINTED
            setting = entry.get("setting")
            cells.append((photo_cell, (painting, f"{state.upper()}{flag}\n{measured}{f' · {setting}' if setting else ''}")))
        sheets = []
        for start in range(0, len(cells), per_sheet):
            chunk = cells[start:start + per_sheet]
            rows = [[cell for pair in chunk[i:i + 3] for cell in pair] for i in range(0, len(chunk), 3)]
            target = out_dir / f"sheet-{start // per_sheet + 1:02d}.jpg"
            title = f"{self.pack_id} pack art {start + 1}-{start + len(chunk)} of {len(cells)}: prompts v{self.prompts.version}, \"{self.theme}\""
            grid(rows, title, []).save(target, quality=88)
            sheets.append(target)
        overview = [[pair[1] for pair in cells[i:i + 10]] for i in range(0, len(cells), 10)]
        if overview:
            target = out_dir / "overview.jpg"
            grid(overview, f"{self.pack_id} pack art, all {len(cells)}", [], cell=(144, 192)).save(target, quality=85)
            sheets.append(target)
        return sheets


def _reference_crop(reference: ChosenPhoto) -> Image.Image:
    with Image.open(reference.original) as opened:
        return reference_crop(upright(opened), reference.scored.box)


def _thumbnail(path: Path, size: tuple[int, int] = (576, 768)) -> Image.Image:
    """A painting loaded small and closed, so a sheet of the whole pack never holds its files open."""
    with Image.open(path) as opened:
        image = opened.convert("RGB")
    image.thumbnail(size)
    return image


@dataclass(frozen=True)
class _Isolated:
    """A reference bird on white, the seed it was isolated with and its fidelity after the colour fit."""

    image: Image.Image
    seed: int
    fitted: dict


def review(lock: ArtLock, approve: list[str] = (), reject: list[str] = (), gap: list[str] = (), approve_all: bool = False, why: str | None = None) -> None:
    """Records the maintainer's review in the lock: species named by id or common name (any case). `approve_all`
    approves every pending painting that is faithful and painted from a photo (one from text, or flagged, needs its own
    `approve`); a rejected one is painted again by the next build with the next round of seeds; a gap gets no art,
    with `why`. Raises KeyError for a species the lock doesn't have."""
    for name in approve:
        lock.species[_find(lock, name)]["review"] = APPROVED
    if approve_all:
        for entry in lock.species.values():
            if entry["review"] == PENDING and entry.get("faithful") is True:
                entry["review"] = APPROVED
    for name in reject:
        entry = lock.species[_find(lock, name)]
        if entry["review"] in (REJECTED, GAP):
            continue  # not repainted yet, or given up: rejecting it again would skip a round
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


def _find(lock: ArtLock, name: str) -> str:
    wanted = name.strip().lower()
    if wanted in lock.species:
        return wanted
    slug = wanted.replace(" ", "-")
    if slug in lock.species:
        return slug
    for species_id, entry in lock.species.items():
        if (entry.get("common_name") or "").lower() == wanted:
            return species_id
    raise KeyError(f"no pack art for {name!r} in {lock.path}")
