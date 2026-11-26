"""Painted samples of the Continental edition's CANDIDATE looks (#213, of #206), for the maintainer's pick.

Nothing here is an edition: the candidates are in `art/continental-candidates.json`, and no pack or app code reads them.
Two birds, one bright and one dark, are painted in each candidate through the patch step itself (`packbuilder.patch_art`:
the committed `patch-art` workflow, patch-prompts.json's own template, settings and clauses, the cut from the card, the
peel and shape retries, the measure), so the look the maintainer picks is copied into patch-prompts.json's `editions`
as it stands (#214).

    cd packbuilder
    uv run --quiet python ../scripts/continental-samples.py prepare          # the two reference birds, from the builder's art cache
    uv run --quiet python ../scripts/continental-samples.py paint            # what the candidates' locks lack
    uv run --quiet python ../scripts/continental-samples.py paint --only B   # one candidate
    uv run --quiet python ../scripts/continental-samples.py reject C corvus-brachyrhynchos --why "a blob"   # next seed on the next paint
    uv run --quiet python ../scripts/continental-samples.py sheet            # build/continental-samples/contact-sheet.jpg

Everything is written under `--out` (default `build/continental-samples/`, which git ignores): per candidate letter a
`patch.lock.json` as the patch step writes it and each bird's cut patch and raw painting, and `cache/art/` with the
reference birds and every painted patch. Painting across the tailnet is slow, so on the painting box copy
`packbuilder/src`, `art/`, this script and `<out>/cache` into a checkout-shaped folder and run
`PYTHONPATH=packbuilder/src ~/comfyui-flux3/.venv/bin/python scripts/continental-samples.py paint --comfy http://127.0.0.1:8189`,
then bring `<out>` back and draw the sheet here, where the other editions' patches are.
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import shutil
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from packbuilder.comfy import ComfyClient
from packbuilder.contact_sheets import FADED_INK, INK, MAT, PAPER, fitted_text, font
from packbuilder.pack_art import ArtLock
from packbuilder.patch_art import LOCK_FILE, PEEL_LIMIT, PatchArtist, PatchLock, PatchPin, PatchPrompts, PatchSpec, cached_isolations, review, trim_rim

REPO = Path(__file__).resolve().parents[1]
CANDIDATES = REPO / "art" / "continental-candidates.json"
OUT = REPO / "build" / "continental-samples"
BUILDER_CACHE = REPO / "packbuilder" / "cache"
COMFY = "http://comfybox:8189"
ASPECT_SLACK = 0.12
"""How far a cut patch's width over height may be from its candidate's before the sheet says so."""
EDITIONS = ("us-ca-la", "us-ca-sd", "us-ca-bay", "us-ca-desert", "us-fl-orlando", "us-pnw", "us-ny-nyc", "us-la-south")
FELT = (150, 150, 150)

log = logging.getLogger("continental-samples")


def load() -> dict:
    return json.loads(CANDIDATES.read_text())


def pack_id(letter: str) -> str:
    """The stand-in pack id a candidate is painted under: it seeds the painting, and never names a real pack."""
    return f"continental-candidate-{letter.lower()}"


def spec_of(candidate: dict) -> PatchSpec:
    outline = candidate.get("outline")
    return PatchSpec(candidate["shape"], candidate["cord"], candidate["twill"], candidate["motif"],
                     tuple(map(tuple, outline)) if outline else None, candidate.get("shape_limit"))


class CanvasClient(ComfyClient):
    """Paints the patch workflow on a candidate's own canvas, where it has one: the patch step paints every edition on the card's."""

    def __init__(self, base_url: str, canvas: tuple[int, int] | None):
        super().__init__(base_url)
        self.canvas = canvas

    def paint(self, workflow, images, prompt=None, seed=None, size=None):
        if size is None and workflow.name == "patch-art":
            size = self.canvas
        return super().paint(workflow, images, prompt=prompt, seed=seed, size=size)


def artist(letter: str, data: dict, out: Path, comfy: str) -> PatchArtist:
    candidate, birds = data["candidates"][letter], data["birds"]
    folder = out / letter
    folder.mkdir(parents=True, exist_ok=True)
    prompts = replace(PatchPrompts.load(), editions={pack_id(letter): spec_of(candidate)})
    art_lock = ArtLock(folder / "references.json", {
        species_id: {"photos": [bird["photo"]], "isolate_seed": bird["isolate_seed"], "common_name": bird["common_name"]} for species_id, bird in birds.items()
    })
    pins = {species_id: PatchPin(bird.get("setting", "perch"), None, bird.get("markings"), None, bird.get("dark_clause", True)) for species_id, bird in birds.items()}
    canvas = tuple(candidate["canvas"]) if candidate.get("canvas") else None
    return PatchArtist(CanvasClient(comfy, canvas), pack_id=pack_id(letter), lock=PatchLock.load(folder / LOCK_FILE), art_lock=art_lock,
                       cache_dir=out / "cache" / "art", prompts=prompts, pins=pins)


def prepare(args: argparse.Namespace) -> int:
    """Copies each bird's isolated reference from the builder's art cache into the samples' own."""
    target = args.out / "cache" / "art" / "isolated"
    target.mkdir(parents=True, exist_ok=True)
    for species_id, bird in load()["birds"].items():
        found = cached_isolations(args.cache / "art", bird["photo"])
        if bird["isolate_seed"] not in found:
            print(f"{species_id}: no isolated bird for photo {bird['photo']} seed {bird['isolate_seed']} in {args.cache / 'art' / 'isolated'}", file=sys.stderr)
            return 1
        image = found[bird["isolate_seed"]]
        for file in (image, image.with_suffix(".json")):
            if file.exists():
                shutil.copy2(file, target / file.name)
        print(f"{species_id}: {target / image.name}", file=sys.stderr)
    return 0


def paint(args: argparse.Namespace) -> int:
    data = load()
    for letter in args.only or sorted(data["candidates"]):
        painter = artist(letter, data, args.out, args.comfy)
        log.info("candidate %s (%s)", letter, data["candidates"][letter]["name"])
        patches = painter.paint(list(data["birds"]))
        for species_id, patch in patches.items():
            if patch.file is None:
                continue
            shutil.copy2(patch.file, args.out / letter / f"{species_id}.png")
            shutil.copy2(patch.file.with_name(f"{patch.file.stem}-raw.png"), args.out / letter / f"{species_id}-raw.png")
    return 0


def reject(args: argparse.Namespace) -> int:
    lock = PatchLock.load(args.out / args.letter / LOCK_FILE)
    review(lock, reject=[args.species], why=args.why)
    return 0


# The sheet

def wrap(text: str, size: int, width: int) -> list[str]:
    face, lines, line = font(size), [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if line and face.getlength(trial) > width:
            lines.append(line)
            line = word
        else:
            line = trial
    return [*lines, line] if line else lines


def on_felt(patch: Image.Image, box: int) -> Image.Image:
    """A cut patch as the pack ships it (without its rim of card), centred on a square of mid grey."""
    patch = trim_rim(patch.convert("RGBA"))
    patch.thumbnail((box - 16, box - 16), Image.Resampling.LANCZOS)
    card = Image.new("RGBA", (box, box), (*FELT, 255))
    card.alpha_composite(patch, ((box - patch.width) // 2, (box - patch.height) // 2))
    return card.convert("RGB")


def app_editions() -> dict[str, tuple[str, str, str]]:
    """Each edition's shape, cord and twill as the app draws them, from `PatchEdition.swift`."""
    source = (REPO / "BirdJournal" / "BirdJournal" / "Patch" / "PatchEdition.swift").read_text()
    found = re.findall(r'case "([a-z-]+)": PatchEdition\(shape: \.(\w+), cord: Color\(hex: 0x([0-9A-F]{6})\), twill: Color\(hex: 0x([0-9A-F]{6})\)\)', source)
    return {pack: (shape, f"#{cord}", f"#{twill}") for pack, shape, cord, twill in found}


def swatch(draw: ImageDraw.ImageDraw, x: int, y: int, colour: str, size: int = 26) -> None:
    draw.rectangle((x, y, x + size, y + size), fill=colour, outline=FADED_INK)


def sheet(args: argparse.Namespace) -> int:
    data = load()
    birds, candidates = data["birds"], data["candidates"]
    prompts = PatchPrompts.load()
    cell, text_width, gap, margin = 520, 760, 16, 24
    width = margin * 2 + text_width + (cell + gap) * len(birds)
    small = (width - margin * 2 - gap * (len(EDITIONS) - 1)) // len(EDITIONS)
    header, row, reference_row, footer = 96, cell + 64, 200, 48 + (small + 6) * len(birds) + 124
    height = header + reference_row + row * len(candidates) + footer
    page = Image.new("RGB", (width, height), PAPER)
    draw = ImageDraw.Draw(page)
    draw.text((margin, 18), "Continental edition: candidate looks (#213)", fill=INK, font=font(34))
    draw.text((margin, 62), f"Candidates, not editions. Two birds through the patch step: patch prompts v{prompts.version}, FLUX.3 on comfybox, cut from the card as every edition is.", fill=FADED_INK, font=font(18))

    # The reference birds, over their columns.
    y = header
    draw.text((margin, y + 8), "Reference birds (isolated on white; the prompt never names them)", fill=INK, font=font(20))
    for column, (species_id, bird) in enumerate(birds.items()):
        x = margin + text_width + column * (cell + gap)
        isolated = cached_isolations(args.out / "cache" / "art", bird["photo"]).get(bird["isolate_seed"])
        if isolated:
            with Image.open(isolated) as opened:
                picture = opened.convert("RGB")
            ink = np.asarray(picture).min(-1) < 235
            ys, xs = np.nonzero(ink)
            picture = picture.crop((xs.min() - 12, ys.min() - 12, xs.max() + 12, ys.max() + 12))
            picture.thumbnail((cell, reference_row - 44), Image.Resampling.LANCZOS)
            tile = Image.new("RGB", (cell, reference_row - 40), "white")
            tile.paste(picture, ((cell - picture.width) // 2, (tile.height - picture.height) // 2))
            page.paste(tile, (x, y))
        draw.text((x + 2, y + reference_row - 36), f"{bird['common_name']} · photo {bird['photo']} · setting {bird.get('setting', 'perch')}", fill=INK, font=font(17))

    # One row per candidate.
    for index, (letter, candidate) in enumerate(sorted(candidates.items())):
        y = header + reference_row + index * row
        draw.line((margin, y - 8, width - margin, y - 8), fill=MAT, width=2)
        draw.text((margin, y), letter, fill=INK, font=font(96))
        draw.text((margin + 96, y + 22), candidate["name"], fill=INK, font=font(34))
        lock = PatchLock.load(args.out / letter / LOCK_FILE)
        ty = y + 116
        for column, species_id in enumerate(birds):
            x = margin + text_width + column * (cell + gap)
            file, entry = args.out / letter / f"{species_id}.png", lock.species.get(species_id, {})
            if not file.exists():
                draw.rectangle((x, y, x + cell, y + cell), outline=FADED_INK)
                draw.text((x + 12, y + 12), "NOT PAINTED", fill=INK, font=font(20))
                continue
            with Image.open(file) as opened:
                patch = opened.convert("RGBA")
            page.paste(on_felt(patch, cell), (x, y))
            aspect = patch.width / patch.height
            flags = []
            if entry.get("card_at_edge", 0) > PEEL_LIMIT:
                flags.append("CARD AT EDGE")
            if "shape_fit" in entry and entry["shape_fit"] < spec_of(candidate).least_fit:
                flags.append("WRONG SHAPE")
            if abs(aspect / candidate["aspect"] - 1) > ASPECT_SLACK:
                flags.append("WRONG ASPECT")
            measured = entry.get("measure")
            line = f"seed {entry.get('seed')} · shape fit {entry.get('shape_fit', '-')} · width : height {aspect:.2f}"
            line += f" · dE {measured['dE_mean']:.1f}" if measured else " · not measured"
            draw.text((x + 2, y + cell + 6), line, fill=FADED_INK, font=font(16))
            draw.text((x + 2, y + cell + 28), " · ".join(flags), fill=INK, font=font(16))
        for label, words, colour in (("Shape", candidate["shape"], None), ("Cord", candidate["cord"], candidate["cord_hex"]),
                                     ("Twill", candidate["twill"], candidate["twill_hex"]), ("Motif", candidate["motif"], None)):
            draw.text((margin, ty), label, fill=FADED_INK, font=font(18))
            lines = wrap(words, 21, text_width - 110 - 20)
            for i, text in enumerate(lines):
                draw.text((margin + 96, ty - 2 + i * 27), text, fill=INK, font=font(21))
            ty += len(lines) * 27 + 4
            if colour:
                swatch(draw, margin + 96, ty, colour)
                draw.text((margin + 96 + 34, ty + 3), f"{colour} in the app", fill=INK, font=font(18))
                ty += 34
            ty += 12
        draw.text((margin, ty), f"width : height {candidate['aspect']:g} : 1" + (f" · canvas {candidate['canvas'][0]} x {candidate['canvas'][1]}" if candidate.get("canvas") else ""), fill=FADED_INK, font=font(17))

    # The eight editions, for comparison: the same two species' approved patches.
    y = header + reference_row + row * len(candidates)
    draw.line((margin, y - 8, width - margin, y - 8), fill=MAT, width=2)
    draw.text((margin, y), "The eight editions taken, with their approved patches of the same two species (their own reference birds)", fill=INK, font=font(22))
    app = app_editions()
    for column, pack in enumerate(EDITIONS):
        x, ey = margin + column * (small + gap), y + 40
        definition = json.loads((REPO / "packbuilder" / "packs" / pack / "pack.json").read_text())
        patch_lock = PatchLock.load(REPO / "packbuilder" / "packs" / pack / LOCK_FILE)
        for i, species_id in enumerate(birds):
            entry = patch_lock.species.get(species_id)
            file = args.cache / "art" / "patches" / f"{entry['sha256']}.png" if entry else None
            if file is not None and file.exists():
                with Image.open(file) as opened:
                    page.paste(on_felt(opened, small), (x, ey + i * (small + 6)))
        shape, cord, twill = app.get(pack, ("?", "#000000", "#000000"))
        spec = prompts.editions[pack]
        ly = ey + (small + 6) * len(birds)
        draw.text((x, ly), definition["set"]["edition"]["name"].replace(" edition", ""), fill=INK, font=font(20))
        draw.text((x, ly + 26), shape, fill=FADED_INK, font=font(16))
        swatch(draw, x, ly + 50, cord, 22)
        draw.text((x + 28, ly + 52), fitted_text(f"{cord} {spec.cord}", 14, small - 30), fill=INK, font=font(14))
        swatch(draw, x, ly + 78, twill, 22)
        draw.text((x + 28, ly + 80), fitted_text(f"{twill} {spec.twill.replace(' cotton twill', '')}", 14, small - 30), fill=INK, font=font(14))
    target = args.out / "contact-sheet.jpg"
    page.save(target, quality=92)
    page.save(target.with_suffix(".png"))
    print(target, file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=Path, default=OUT)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_command = commands.add_parser("prepare")
    prepare_command.add_argument("--cache", type=Path, default=BUILDER_CACHE, help="the builder's cache")
    paint_command = commands.add_parser("paint")
    paint_command.add_argument("--comfy", default=COMFY)
    paint_command.add_argument("--only", action="append", metavar="LETTER")
    reject_command = commands.add_parser("reject")
    reject_command.add_argument("letter")
    reject_command.add_argument("species")
    reject_command.add_argument("--why")
    sheet_command = commands.add_parser("sheet")
    sheet_command.add_argument("--cache", type=Path, default=BUILDER_CACHE, help="the builder's cache, for the other editions' patches")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    return {"prepare": prepare, "paint": paint, "reject": reject, "sheet": sheet}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
