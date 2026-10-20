"""The art bake-off (issue #49): ten hard species painted by FLUX.3 Image Klein on comfybox as pack art in the Los
Angeles and San Diego editions, as scene art in real glasses photos (with the Legendary variant), and as photo art
from open-license bird photos, then laid out on contact sheets for the maintainer's review.

    uv run python -m packbuilder.bakeoff references   # open-license photos per species -> art/bakeoff/plan.json
    uv run python -m packbuilder.bakeoff paint --scenes DIR [--comfy http://comfybox:8189]
    uv run python -m packbuilder.bakeoff sheets --scenes DIR

Every input is an open-license (CC0 or CC BY) iNaturalist photo or a glasses photo from the maintainer's phone; the
glasses photos stay out of the repository. Paintings, timings, fidelity and sheets go to build/art-bakeoff/v<prompts
version>/. Painting is resumable: a painting whose file exists is skipped.

A painting's file is the card art: the bird's colours fitted back to its photo (`packbuilder.fidelity`). Beside it,
`<name>-raw.png` is the painting as FLUX.3 left it, and results.json has both birds' fidelity.
"""

from __future__ import annotations

import argparse
import io
import json
import logging
import math
import sys
import time
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from packbuilder.art import ART_KINDS, ArtKind, ArtPrompts, Species, Workflow, card_crop_box, telephoto_crop
from packbuilder.comfy import ComfyClient, PaintingFailed
from packbuilder.crops import upright
from packbuilder.definition import PackDefinition
from packbuilder.download import fetch
from packbuilder.fidelity import Fidelity, bird_mask, fit_colours, on_white
from packbuilder.geometry import Box
from packbuilder.licenses import CC0, CC_BY, credit_line, normalize_license

log = logging.getLogger("packbuilder.bakeoff")

REPO = Path(__file__).resolve().parents[3]
PLAN = REPO / "art" / "bakeoff" / "plan.json"
BUILD = REPO / "build" / "art-bakeoff"
CACHE = REPO / "packbuilder" / "cache"
COMFY = "http://comfybox:8189"

SPECIES = [
    "Black Phoebe", "Anna's Hummingbird", "Red-tailed Hawk", "Cooper's Hawk", "House Finch",
    "California Towhee", "Western Bluebird", "Great Egret", "Great Horned Owl", "Townsend's Warbler",
]
EDITIONS = ("us-ca-la", "us-ca-sd")
# The glasses photos are from Los Angeles, and so are most of the bird photos.
HOME_EDITION = "us-ca-la"
REFERENCE_PADDING = 0.35
PHOTO_PADDING = 0.8
MAX_INPUT_SIDE = 1536
ISOLATE_SEED = 49
ATTEMPTS = 3
"""A painting whose bird isn't faithful to its photo (packbuilder.fidelity) is painted again with the next seed, at most
this many times in all; then the closest is kept and marked for review."""


class OpenLicensePhotos:
    """The CC0 and CC BY photos among the Los Angeles and San Diego packs' candidates (every species is in both),
    from the builds' cached iNaturalist pages: the open-license pack photos #50 will choose from. CC BY-SA is not in
    those pages, which asked for CC0, CC BY and CC BY-NC."""

    def __init__(self, sources):
        self.sources = sources

    def candidates_for(self, taxon_id: int):
        return [c for source in self.sources for c in source.candidates_for(taxon_id) if normalize_license(c.license) in (CC0, CC_BY)]


@dataclass(frozen=True)
class PlannedPainting:
    """One painting of a species the bake-off makes (not an art job: no card asked for it)."""

    name: str
    kind: ArtKind
    edition: str
    legendary: bool
    inputs: list[str]
    """In workflow image order: "bird:<photo id>" (the reference bird isolated on white), "scene:<id>" (the telephoto
    crop of a glasses photo) or "photo:<photo id>" (a bird photo as it is)."""


def planned_paintings(species: dict, scenes: list[dict]) -> list[PlannedPainting]:
    """Pack art in both editions; scene art in every scene plus a Legendary one, painting the species'
    `scene_reference` or else its `reference`; photo art from both photos plus a Legendary one."""
    reference = f"bird:{species['reference']}"
    scene_reference = f"bird:{species.get('scene_reference', species['reference'])}"
    first_scene, first_photo = scenes[0]["id"], species["photos"][0]
    paintings = [PlannedPainting(f"pack-{edition}", "pack", edition, False, [reference]) for edition in EDITIONS]
    paintings += [PlannedPainting(f"scene-{scene['id']}", "scene", HOME_EDITION, False, [scene_reference, f"scene:{scene['id']}"]) for scene in scenes]
    paintings.append(PlannedPainting(f"scene-{first_scene}-legendary", "scene", HOME_EDITION, True, [scene_reference, f"scene:{first_scene}"]))
    paintings += [PlannedPainting(f"photo-{photo}", "photo", HOME_EDITION, False, [f"photo:{photo}"]) for photo in species["photos"]]
    paintings.append(PlannedPainting(f"photo-{first_photo}-legendary", "photo", HOME_EDITION, True, [f"photo:{first_photo}"]))
    return paintings


def references(args) -> int:
    """Ranks each species' open-license photos the way a pack build ranks photos, and writes a plan taking the best
    as the reference and the next two as the birder's photos. Review the sheet and edit the plan before painting."""
    from packbuilder.detector import BirdDetector, ensure_model
    from packbuilder.metadata_api import APIMetadata
    from packbuilder.pipeline import BuildOptions, build_species
    from packbuilder.selection import Overrides

    packs = [PackDefinition.load(REPO / "packbuilder" / "packs" / pack / "pack.json") for pack in EDITIONS]
    entries = {entry.common_name: entry for entry in packs[0].species}
    metadata = OpenLicensePhotos([APIMetadata(pack.place_ids, CACHE, created_before=pack.created_before) for pack in packs])
    detector = BirdDetector(ensure_model(CACHE))
    options = BuildOptions(cache_dir=CACHE, out_dir=BUILD, candidate_limit=args.limit, min_photos=3, max_photos=args.keep)
    plan = {"comment": "", "scenes": [], "species": []}
    for name in SPECIES:
        entry = entries[name]
        result = build_species(entry, Overrides(), metadata, detector, options)
        photos = []
        for chosen in result.photos:
            candidate, box = chosen.candidate, chosen.scored.box
            photos.append({
                "id": candidate.photo_id,
                "license": normalize_license(candidate.license),
                "observer": candidate.observer_name or candidate.observer_login,
                "source_url": candidate.source_url,
                "original_url": candidate.photo_url("original"),
                "box": [round(v, 4) for v in (box.x0, box.y0, box.x1, box.y1)],
            })
        ids = [photo["id"] for photo in photos]
        plan["species"].append({
            "common_name": entry.common_name, "scientific_name": entry.scientific_name, "inat_taxon_id": entry.inat_taxon_id,
            "reference": ids[0] if ids else None, "photos": ids[1:3], "candidates": photos,
        })
    target = Path(args.plan)
    if target.exists() and not args.force:
        target = BUILD / "plan.draft.json"
        log.info("%s exists; the new plan is %s", args.plan, target)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(plan, indent=2) + "\n")
    _candidate_sheet(plan, BUILD / "references.jpg")
    log.info("wrote %s and %s", target, BUILD / "references.jpg")
    return 0


@dataclass(frozen=True)
class Attempt:
    """One painting of a bird and how faithful it came out."""

    seed: int
    seconds: float
    raw: Image.Image
    mask: np.ndarray
    fitted: Image.Image
    before: Fidelity
    after: Fidelity


class Studio:
    """Everything one round of painting reads and caches: the isolated reference birds, the cut-outs the fidelity is
    measured with, and the results. All of it lives under `out`."""

    def __init__(self, plan: dict, prompts: ArtPrompts, client: ComfyClient, scenes_dir: Path, out: Path):
        self.plan, self.prompts, self.client, self.scenes_dir, self.out = plan, prompts, client, scenes_dir, out
        self.isolate, self.cutout = Workflow.load("bird-isolate"), Workflow.load("bird-cutout")
        self.results_path = out / "results.json"
        self.results = json.loads(self.results_path.read_text()) if self.results_path.exists() else {}

    def save(self) -> None:
        self.results_path.write_text(json.dumps(self.results, indent=2) + "\n")

    def mask(self, name: str, image: Image.Image) -> np.ndarray:
        """The bird in `image` (BiRefNet), cached as cutouts/<name>.png."""
        target = self.out / "cutouts" / f"{name}.png"
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(self.client.paint(self.cutout, images=[(f"cutout-{name.replace('/', '-')}.png", _png(image))]).image)
        return bird_mask(Image.open(target))

    def best_of(self, workflow: Workflow, images: list[tuple[str, bytes]], prompt: str, seed: int, photo: Image.Image, photo_mask: np.ndarray,
                name: str, size: tuple[int, int] | None = None) -> tuple[Attempt, int]:
        """Paints with `seed`, then the next seeds, until the bird is faithful to `photo` after its colour fit, at most
        ATTEMPTS times; returns the faithful painting or else the closest, and how many were painted."""
        best = None
        for attempt in range(ATTEMPTS):
            painting = self.client.paint(workflow, images=images, prompt=prompt, seed=seed + attempt, size=size)
            raw = Image.open(io.BytesIO(painting.image)).convert("RGB")
            mask = self.mask(f"{name}@{seed + attempt}", raw)
            try:
                fitted, before, after = fit_colours(raw, mask, photo, photo_mask)
            except ValueError as error:  # no bird, or none where the photo's is
                log.warning("%s seed %d: %s", name, seed + attempt, error)
                continue
            current = Attempt(seed + attempt, painting.seconds, raw, mask, fitted, before, after)
            if best is None or (after.faithful, -after.dE_mean) > (best.after.faithful, -best.after.dE_mean):
                best = current
            if after.faithful:
                return best, attempt + 1
        if best is None:
            raise ValueError(f"{name}: no painting had a bird to measure")
        return best, ATTEMPTS

    def reference_crop(self, species: dict, photo_id: int) -> Image.Image:
        """A reference photo cropped to 3:4 around the bird, in multiples of 16 (the isolation's canvas)."""
        crop = _photo_crop(species, photo_id, "pack")
        return crop.resize((crop.width // 16 * 16, crop.height // 16 * 16), Image.Resampling.LANCZOS)

    def isolated(self, species: dict, photo_id: int) -> Image.Image:
        """The reference bird alone on white (bird-isolate at the crop's own size, so it stays where it is in the
        photo, its hidden parts completed), its colours fitted back to the photo's. Cached as isolated/<id>.png, with
        FLUX.3's own picture beside it as <id>-raw.png."""
        target = self.out / "isolated" / f"{photo_id}.png"
        if target.exists():
            return Image.open(target).convert("RGB")
        crop = self.reference_crop(species, photo_id)
        best, attempts = self.best_of(self.isolate, [(f"isolate-{photo_id}.png", _png(crop))], self.prompts.isolate, ISOLATE_SEED,
                                      crop, self.mask(f"photos/{photo_id}", crop), f"isolated/{photo_id}", size=crop.size)
        target.parent.mkdir(parents=True, exist_ok=True)
        best.raw.save(target.with_name(f"{photo_id}-raw.png"))
        isolated = on_white(best.fitted, best.mask)
        isolated.save(target)
        self.results[f"isolated/{photo_id}"] = {
            "species": species["common_name"], "kind": "isolate", "photo": photo_id, "seed": best.seed, "attempts": attempts,
            "seconds": best.seconds, "fidelity": {"painted": best.before.as_dict(), "fitted": best.after.as_dict()},
            "prompts_version": self.prompts.version, "workflow_version": self.isolate.version,
        }
        self.save()
        _log(species, f"isolate {photo_id}", best, attempts)
        return isolated

    def reference(self, key: str, species: dict) -> tuple[str, Image.Image]:
        """One of a painting's inputs, named for the upload."""
        source, source_id = key.split(":", 1)
        slug = _slug(species["common_name"])
        if source == "bird":
            return f"{slug}-bird-{source_id}.png", self.isolated(species, int(source_id))
        if source == "scene":
            (scene,) = [s for s in self.plan["scenes"] if s["id"] == source_id]
            image = upright(Image.open(self.scenes_dir / scene["file"]))
            return f"{slug}-scene-{source_id}.png", telephoto_crop(image, species["length_cm"], tuple(scene["perch"]))
        return f"{slug}-photo-{source_id}.png", _photo_crop(species, int(source_id), "photo")

    def measured_against(self, planned: PlannedPainting, species: dict) -> tuple[Image.Image, np.ndarray]:
        """The photo a painting's bird must match, and the bird in it: the reference crop for pack and scene art, the
        photo itself for photo art."""
        source, source_id = planned.inputs[0].split(":", 1)
        if source == "bird":
            crop = self.reference_crop(species, int(source_id))
            return crop, self.mask(f"photos/{source_id}", crop)
        photo = _photo_crop(species, int(source_id), "photo")
        return photo, self.mask(f"photos/{source_id}-wide", photo)


def paint(args) -> int:
    plan = json.loads(Path(args.plan).read_text())
    prompts = ArtPrompts.load()
    workflows = {kind: Workflow.load(f"{kind}-art") for kind in ART_KINDS}
    out = BUILD / f"v{prompts.version}"
    studio = Studio(plan, prompts, ComfyClient(args.comfy, poll_seconds=1.0), Path(args.scenes), out)
    selected = [s for s in plan["species"] if not args.species or s["common_name"] in args.species]
    for species in selected:
        slug = _slug(species["common_name"])
        for planned in planned_paintings(species, plan["scenes"]):
            if args.kind and planned.kind not in args.kind:
                continue
            target = out / slug / f"{planned.name}.png"
            if target.exists() and not args.again:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            prompt = prompts.render(planned.kind, Species(species["common_name"], species["scientific_name"]), planned.edition, legendary=planned.legendary)
            seed = zlib.crc32(f"{species['scientific_name']}/{planned.name}".encode())
            started = time.monotonic()
            try:
                images = [(name, _png(image)) for name, image in (studio.reference(key, species) for key in planned.inputs)]
                photo, photo_mask = studio.measured_against(planned, species)
                best, attempts = studio.best_of(workflows[planned.kind], images, prompt, seed, photo, photo_mask, f"paintings/{slug}/{planned.name}")
            except (PaintingFailed, ValueError) as error:
                log.error("%s %s: %s", species["common_name"], planned.name, error)
                continue
            best.raw.save(target.with_name(f"{planned.name}-raw.png"))
            best.fitted.save(target)
            studio.results[f"{slug}/{planned.name}"] = {
                "species": species["common_name"], "painting": planned.name, "kind": planned.kind, "edition": planned.edition,
                "legendary": planned.legendary, "inputs": planned.inputs, "prompt": prompt, "seed": best.seed, "attempts": attempts,
                "seconds": best.seconds, "wall_seconds": round(time.monotonic() - started, 2),
                "fidelity": {"painted": best.before.as_dict(), "fitted": best.after.as_dict()},
                "prompts_version": prompts.version, "workflow_version": workflows[planned.kind].version,
            }
            studio.save()
            _log(species, planned.name, best, attempts)
    return 0


def sheets(args) -> int:
    plan = json.loads(Path(args.plan).read_text())
    prompts = ArtPrompts.load()
    out = BUILD / f"v{prompts.version}"
    studio = Studio(plan, prompts, ComfyClient(args.comfy), Path(args.scenes), out)
    for species in plan["species"]:
        _species_sheet(species, studio, out / "sheets" / f"{_slug(species['common_name'])}.jpg")
    _overview(plan, studio, out / "sheets" / "overview.jpg")
    _timings(studio.results)
    return 0


def _log(species: dict, name: str, best: Attempt, attempts: int) -> None:
    review = "" if best.after.faithful else "  REVIEW: not faithful"
    log.info("%-20s %-28s %5.1f s  dE %.1f -> %.1f  iou %.2f  %d attempt(s)%s", species["common_name"], name, best.seconds,
             best.before.dE_mean, best.after.dE_mean, best.after.iou, attempts, review)


def _photo_crop(species: dict, photo_id: int, kind: ArtKind) -> Image.Image:
    """A bird photo's 3:4 crop around the bird: tighter for a reference, with more of the photo for photo art, at
    most MAX_INPUT_SIDE a side."""
    photo = _photo(species, photo_id)
    image = upright(Image.open(_original(photo))).convert("RGB")
    padding = PHOTO_PADDING if kind == "photo" else REFERENCE_PADDING
    crop = image.crop(card_crop_box(Box(*photo["box"]), image.size, padding=padding))
    crop.thumbnail((MAX_INPUT_SIDE, MAX_INPUT_SIDE), Image.Resampling.LANCZOS)
    return crop


def _photo(species: dict, photo_id: int) -> dict:
    (photo,) = [p for p in species["candidates"] if p["id"] == photo_id]
    return photo


def _original(photo: dict) -> Path:
    extension = photo["original_url"].rsplit(".", 1)[-1]
    return fetch(photo["original_url"], CACHE / "photos" / "original" / f"{photo['id']}.{extension}")


def _png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def _slug(name: str) -> str:
    return "".join(c if c.isalnum() else "-" for c in name.lower().replace("'", "")).strip("-")


# Contact sheets ---------------------------------------------------------------------------------------------------

CELL = (288, 384)
LABEL_HEIGHT = 44


def _font(size: int):
    return ImageFont.load_default(size=size)


def _fit(image: Image.Image, size=CELL) -> Image.Image:
    canvas = Image.new("RGB", size, (235, 232, 224))
    image = image.copy()
    image.thumbnail(size, Image.Resampling.LANCZOS)
    canvas.paste(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return canvas


def _grid(rows: list[list[tuple[Image.Image | None, str]]], title: str, footer: list[str]) -> Image.Image:
    columns = max(len(row) for row in rows)
    header, line = 56, 22
    width = columns * CELL[0] + (columns + 1) * 8
    height = header + len(rows) * (CELL[1] + LABEL_HEIGHT + 8) + 16 + line * len(footer)
    sheet = Image.new("RGB", (width, height), (248, 245, 237))
    draw = ImageDraw.Draw(sheet)
    draw.text((12, 12), title, fill=(38, 51, 41), font=_font(28))
    for r, row in enumerate(rows):
        for c, (image, label) in enumerate(row):
            x, y = 8 + c * (CELL[0] + 8), header + r * (CELL[1] + LABEL_HEIGHT + 8)
            if image is not None:
                sheet.paste(_fit(image), (x, y))
            for i, text in enumerate(label.split("\n")[:2]):
                draw.text((x + 2, y + CELL[1] + 3 + i * 19), text, fill=(38, 51, 41), font=_font(16))
    y = header + len(rows) * (CELL[1] + LABEL_HEIGHT + 8) + 8
    for text in footer:
        draw.text((12, y), text, fill=(93, 103, 94), font=_font(15))
        y += line
    return sheet


def _species_sheet(species: dict, studio: Studio, target: Path) -> None:
    """Three rows: each painting's first reference (with the scene it goes into), FLUX.3's painting, and the card art
    with the bird's colours fitted back, each with its fidelity."""
    slug = _slug(species["common_name"])
    inputs, painted, fitted = [], [], []
    for planned in planned_paintings(species, studio.plan["scenes"]):
        name, image = studio.reference(planned.inputs[0], species)
        inputs.append((image, f"{planned.inputs[0]}\n+ {planned.inputs[1]}" if len(planned.inputs) > 1 else planned.inputs[0]))
        result = studio.results.get(f"{slug}/{planned.name}")
        path = studio.out / slug / f"{planned.name}.png"
        if result is None or not path.exists():
            painted.append((None, f"{planned.name}\nnot painted"))
            fitted.append((None, ""))
            continue
        before, after = result["fidelity"]["painted"], result["fidelity"]["fitted"]
        seconds = f" · {result['seconds']:.0f} s" if not math.isnan(result["seconds"]) else ""
        tries = f" · {result['attempts']} tries" if result.get("attempts", 1) > 1 else ""
        painted.append((Image.open(path.with_name(f"{planned.name}-raw.png")), f"{planned.name}{seconds}{tries}\ndE {before['dE_mean']} p95 {before['dE_p95']} dL {before['dL']}"))
        verdict = "" if after["faithful"] else " · REVIEW"
        fitted.append((Image.open(path), f"colours fitted{verdict}\ndE {after['dE_mean']} iou {after['iou']}"))
    used = dict.fromkeys([species["reference"], species.get("scene_reference", species["reference"]), *species["photos"]])
    credits = [f"{p['id']}: {credit_line(p['observer'], p['license'])} {p['source_url']}" for p in (_photo(species, i) for i in used)]
    target.parent.mkdir(parents=True, exist_ok=True)
    title = f"{species['common_name']} ({species['scientific_name']}): FLUX.3 Image Klein, prompts v{studio.prompts.version}"
    _grid([inputs, painted, fitted], title, credits).save(target, quality=88)


def _overview(plan: dict, studio: Studio, target: Path) -> None:
    rows = []
    for species in plan["species"]:
        row = []
        for planned in planned_paintings(species, plan["scenes"]):
            path = studio.out / _slug(species["common_name"]) / f"{planned.name}.png"
            result = studio.results.get(f"{_slug(species['common_name'])}/{planned.name}")
            label = f"{species['common_name']}\n{planned.name}" + (f" dE {result['fidelity']['fitted']['dE_mean']}" if result else "")
            row.append((Image.open(path) if path.exists() else None, label))
        rows.append(row)
    _grid(rows, f"Art bake-off: FLUX.3 Image Klein, prompts v{studio.prompts.version}, colours fitted", []).save(target, quality=85)


def _candidate_sheet(plan: dict, target: Path) -> None:
    rows = []
    for species in plan["species"]:
        row = []
        for photo in species["candidates"]:
            image = _photo_crop(species, photo["id"], "pack")
            row.append((image, f"{species['common_name']}\n{photo['id']} {photo['license']}"))
        rows.append(row)
    _grid(rows, "Open-license candidates (reference = first, photos = next two, unless the plan says otherwise)", []).save(target, quality=85)


def _timings(results: dict) -> None:
    timed = [r for r in results.values() if not math.isnan(r["seconds"])]
    seconds = sorted(r["seconds"] for r in timed)
    if not seconds:
        return
    by_kind: dict[str, list[float]] = {}
    for r in timed:
        by_kind.setdefault(r["kind"], []).append(r["seconds"])
    median = seconds[len(seconds) // 2]
    log.info("%d paintings: median %.1f s, fastest %.1f s, slowest %.1f s", len(seconds), median, seconds[0], seconds[-1])
    for kind, values in sorted(by_kind.items()):
        values.sort()
        log.info("  %-7s median %.1f s over %d", kind, values[len(values) // 2], len(values))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="packbuilder.bakeoff", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plan", default=str(PLAN), help=f"the bake-off plan (default {PLAN.relative_to(REPO)})")
    commands = parser.add_subparsers(dest="command", required=True)
    references_command = commands.add_parser("references", help="rank open-license photos per species and write a plan")
    references_command.add_argument("--limit", type=int, default=40, help="cleared candidates per species to download and detect")
    references_command.add_argument("--keep", type=int, default=6, help="photos kept per species")
    references_command.add_argument("--force", action="store_true", help="overwrite an existing plan")
    paint_command = commands.add_parser("paint", help="paint every painting of the plan on ComfyUI")
    paint_command.add_argument("--scenes", required=True, help="folder holding the plan's glasses photos")
    paint_command.add_argument("--comfy", default=COMFY, help=f"ComfyUI base URL (default {COMFY})")
    paint_command.add_argument("--species", action="append", help="paint only this species (repeat)")
    paint_command.add_argument("--kind", action="append", choices=ART_KINDS, help="paint only this kind (repeat)")
    paint_command.add_argument("--again", action="store_true", help="repaint the paintings that already exist")
    sheets_command = commands.add_parser("sheets", help="contact sheets of the paintings")
    sheets_command.add_argument("--scenes", required=True, help="folder holding the plan's glasses photos")
    sheets_command.add_argument("--comfy", default=COMFY, help=f"ComfyUI base URL, for a reference not yet isolated (default {COMFY})")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    return {"references": references, "paint": paint, "sheets": sheets}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
