"""Candidates for the generic Uncharted patch (#221, of #206): the one finished embroidered patch that stands in for every
Uncharted bird. The maintainer picked A, the feather, on the sheet this draws, and #222 shipped it in the app: the pick,
its two paintings in `art/uncharted/` and the hashes of the files the app lights are `shipped` in
`art/uncharted-patch.json`. This is how those were made, and how another would be.

    cd packbuilder
    uv run --quiet python ../scripts/uncharted-candidates.py paint  ../build/uncharted-candidates --trials 4          # every emblem, four seeds each
    uv run --quiet python ../scripts/uncharted-candidates.py paint  ../build/uncharted-candidates --only feather --trials 8
    uv run --quiet python ../scripts/uncharted-candidates.py layers ../build/uncharted-candidates                     # the lettered candidates' layers
    uv run --quiet python ../scripts/uncharted-candidates.py sheet  ../build/uncharted-candidates \
        --beside "House Finch|Los Angeles|../packs/us-ca-la/patch/haemorhous-mexicanus.avif" \
        --beside "Northern Cardinal|New York|cache/art/patches/<the cut patch's sha256>.png"                           # and --light

`paint` needs comfybox (UNCHARTED_COMFY, default http://comfybox:8189). Paint on the box itself, not across the tailnet:
copy `packbuilder/src`, `art/` and this script to a checkout-shaped folder there and run it from its `packbuilder` folder
with `PYTHONPATH=src UNCHARTED_COMFY=http://127.0.0.1:8189 ~/comfyui-flux3/.venv/bin/python ../scripts/uncharted-candidates.py paint OUT`,
then copy OUT back. It paints each emblem of `art/uncharted-patch.json` from text and cuts the round badge from its
card along its cord, as an exact disc (`cut_round`): `OUT/trials/<emblem>/<seed>.png` at 720 px, `-raw.png` as it came,
and `OUT/trials/results.json` (the prompt, the seed, where the embroidery lies). A painting already there under the same
prompt is only cut again; one that isn't round has no cut. `trials` draws them all on `OUT/trials.jpg`.

`layers` writes, for each candidate the prompts file letters (`candidates`), exactly what a pack ships for a patch
(`writer._write_patch`): `OUT/<letter>-<emblem>/patch.avif`, the colour on transparency at 720 px; `patch-layers.avif`
at half size, the height map in red, the cord's mask in green and the stitch order in blue; and `patch.json`, the
pack's `patch` row for it (size, the bare canvas's colour, the stitch layers' starts). `patch.png` and the three layers
as PNGs are beside them to look at.

`sheet` draws `OUT/contact-sheet.jpg` (`--light`: `contact-sheet-light.jpg`, on the light appearance's linen), a band
for today's blank and one for each candidate: on its page, on the Uncharted board three across with a short, a long and
a middling name on the paper tag (`PatchView.swift`'s `TiedTag`), and between two painted edition patches (`--beside`,
a pack's `patch/<id>.avif` or a cut patch's PNG from the cache). Every patch is lit as the app lights one
(`PatchShader.metal`, by numpy, with the light at rest) from the same two files the app would read. It is a drawing of
the app, not the app: the simulator has the last word once #222 ships the pick.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy import ndimage
from scipy.spatial import ConvexHull

from packbuilder.art import ART_DIR, Workflow
from packbuilder.patch_art import SIZE, layers, peeled, trim_rim

PROMPTS = ART_DIR / "uncharted-patch.json"
COMFY = os.environ.get("UNCHARTED_COMFY", "http://comfybox:8189")
ASPECT_SLACK, FILL_SLACK = 0.025, 0.015
"""How far a painted badge may be from round and still be drawn out to an exact disc (`cut_round`)."""
MARGIN = 4
"""Pixels of nothing around the disc in its 720 px picture."""


def prompts() -> dict:
    return json.loads(PROMPTS.read_text())


def render(data: dict, emblem: str) -> str:
    entry = data["emblems"][emblem]
    return data["template"].format(emblem=entry["emblem"], placement=entry.get("placement", data["placement"]))


def seed_of(emblem: str, index: int) -> int:
    return zlib.crc32(f"uncharted/{emblem}/{index}".encode())


def png(image: Image.Image) -> bytes:
    data = io.BytesIO()
    image.save(data, "PNG")
    return data.getvalue()


class NotRound(ValueError):
    pass


def cut_round(painting: Image.Image, size: int = SIZE) -> Image.Image:
    """The round badge cut from its card along its brown cord, as an exact disc `size` across. `cut_from_card` keeps
    whatever is clearly off the card, and on these pale badges that took in the darker side of the shadow, a crescent
    under one edge. Here the outline is the convex hull of everything cord-coloured (dark and red-brown: the cord and
    the brown embroidery inside it; never the card or its grey shadow), and its bounding box is drawn out to a square, so
    every candidate has the same alpha to the pixel, as a board of one patch repeated needs. Raises NotRound for a
    badge that was painted tilted or whose cord isn't whole: more than `ASPECT_SLACK` off square, or a hull that
    doesn't fill its ellipse."""
    rgb = np.asarray(painting.convert("RGB")).astype(float)
    cord = ndimage.binary_opening((rgb.mean(-1) < 135) & (rgb[..., 0] - rgb[..., 2] > 32), iterations=2)
    ys, xs = np.nonzero(cord)
    if len(xs) < 1000:
        raise NotRound("no cord on the card")
    points = np.column_stack([xs, ys])
    hull = points[ConvexHull(points).vertices]
    outline = Image.new("L", painting.size, 0)
    ImageDraw.Draw(outline).polygon([tuple(point) for point in hull], fill=255)
    box = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
    width, height = box[2] - box[0], box[3] - box[1]
    fill = float((np.asarray(outline) > 0).sum() / (np.pi * width * height / 4))
    if abs(width / height - 1) > ASPECT_SLACK or not 1 - FILL_SLACK < fill < 1 + FILL_SLACK:
        raise NotRound(f"not round: {width} x {height}, {fill:.3f} of its ellipse")
    if min(box[0], box[1], painting.width - box[2], painting.height - box[3]) < 8:
        raise NotRound("the badge runs off the card")
    # Drawn out to a square at twice the size, then cut to the largest circle about its middle that stays inside the
    # hull: a hull that bulges past its ellipse on one side would leave a sliver of card outside the cord on the other.
    work = size * 2
    inside = np.asarray(outline.resize((work, work), Image.BILINEAR, box=box)) > 128
    radius = float(ndimage.distance_transform_edt(inside)[work // 2, work // 2]) - 2
    middle = (box[0] + width / 2, box[1] + height / 2)
    # MARGIN pixels of nothing around the disc, as `cut_from_card` leaves around a patch: `layers` measures the cord from
    # the alpha's edge, and a disc touching the picture's sides has a thinner cord at those four points.
    grown = size / (size - 2 * MARGIN)
    reach = (radius / work * width * grown, radius / work * height * grown)
    face = painting.convert("RGB").resize((size, size), Image.LANCZOS, box=(middle[0] - reach[0], middle[1] - reach[1], middle[0] + reach[0], middle[1] + reach[1]))
    k = 4
    disc = Image.new("L", (size * k, size * k), 0)
    ImageDraw.Draw(disc).ellipse((MARGIN * k, MARGIN * k, (size - MARGIN) * k - 1, (size - MARGIN) * k - 1), fill=255)
    face.putalpha(disc.resize((size, size), Image.LANCZOS))
    return face


def emblem_box(patch: Image.Image) -> tuple[float, float, float, float] | None:
    """Where the embroidery is inside the cord, as parts of the patch (x0, y0, x1, y1): what is well off the canvas's
    colour, in pieces big enough to be stitching. The paper tag with a three-line name reaches 0.6 down a board's tile."""
    rgba = np.asarray(patch.convert("RGBA")).astype(float)
    rgb, inside = rgba[..., :3], rgba[..., 3] > 128
    dist = ndimage.distance_transform_edt(inside)
    ground = np.median(rgb[(dist > 30) & (dist < 45)], axis=0)
    stitched = ndimage.binary_opening((dist > 40) & (np.linalg.norm(rgb - ground, axis=-1) > 60), iterations=3)
    labels, count = ndimage.label(stitched)
    if count == 0:
        return None
    sizes = ndimage.sum_labels(stitched, labels, index=np.arange(1, count + 1))
    ys, xs = np.nonzero(np.isin(labels, np.flatnonzero(sizes >= 200) + 1))
    if not len(xs):
        return None
    height, width = inside.shape
    return (round(float(xs.min()) / width, 3), round(float(ys.min()) / height, 3), round(float(xs.max()) / width, 3), round(float(ys.max()) / height, 3))


def paint(out: Path, only: list[str], trials: int) -> None:
    """Paints each emblem's trials, or cuts again a trial whose painting is already there under the same prompt."""
    from packbuilder.comfy import ComfyClient, PaintingFailed

    data = prompts()
    workflow = Workflow.load(data["workflow"])
    client = ComfyClient(COMFY)
    folder = out / "trials"
    folder.mkdir(parents=True, exist_ok=True)
    results_path = folder / "results.json"
    results = json.loads(results_path.read_text()) if results_path.exists() else {}
    for emblem in data["emblems"]:
        if only and emblem not in only:
            continue
        prompt = render(data, emblem)
        for index in range(trials):
            seed = seed_of(emblem, index)
            target = folder / emblem / f"{seed}.png"
            raw_path = target.with_name(f"{seed}-raw.png")
            key = f"{emblem}/{seed}"
            seconds = results.get(key, {}).get("seconds")
            if raw_path.exists() and results.get(key, {}).get("prompt") == prompt:
                with Image.open(raw_path) as opened_raw:
                    raw = opened_raw.convert("RGB")
            else:
                try:
                    painting = client.paint(workflow, images=[], prompt=prompt, seed=seed, size=tuple(data["canvas"]))
                except PaintingFailed as error:
                    print(f"{key}: failed: {error}", flush=True)
                    continue
                raw, seconds = Image.open(io.BytesIO(painting.image)).convert("RGB"), round(painting.seconds, 1)
                target.parent.mkdir(parents=True, exist_ok=True)
                raw.save(raw_path)
            entry = {"emblem": emblem, "index": index, "seed": seed, "prompt": prompt, "prompts": data["version"], "workflow": workflow.tag, "seconds": seconds}
            try:
                cut_png = png(cut_round(raw))
            except NotRound as error:
                target.unlink(missing_ok=True)
                entry["not_cut"] = str(error)
            else:
                target.write_bytes(cut_png)
                cut = Image.open(io.BytesIO(cut_png))
                entry |= {"sha256": hashlib.sha256(cut_png).hexdigest(), "card_at_edge": round(peeled(cut), 4), "emblem_box": emblem_box(cut)}
            results[key] = entry
            results_path.write_text(json.dumps(results, indent=1) + "\n")
            print(f"{key}: {entry.get('not_cut') or entry['emblem_box']}, card at edge {entry.get('card_at_edge')}", flush=True)


def trials_sheet(out: Path, cell: int = 300) -> Path:
    """Every trial on one picture, a row per emblem, on mid grey: `OUT/trials.jpg`."""
    folder = out / "trials"
    results = json.loads((folder / "results.json").read_text())
    rows: dict[str, list[dict]] = {}
    for entry in results.values():
        if (folder / entry["emblem"] / f"{entry['seed']}.png").exists():
            rows.setdefault(entry["emblem"], []).append(entry)
    columns = max(len(row) for row in rows.values())
    sheet = Image.new("RGB", (columns * cell, len(rows) * (cell + 22)), (150, 150, 150))
    draw = ImageDraw.Draw(sheet)
    for r, (emblem, row) in enumerate(rows.items()):
        for c, entry in enumerate(sorted(row, key=lambda e: e["index"])):
            with Image.open(folder / emblem / f"{entry['seed']}.png") as opened:
                patch = opened.convert("RGBA")
            patch.thumbnail((cell - 8, cell - 8))
            sheet.paste(patch, (c * cell + 4, r * (cell + 22) + 4), patch)
            draw.text((c * cell + 6, r * (cell + 22) + cell + 4), f"{emblem} {entry['index']}  seed {entry['seed']}", fill=(20, 20, 20))
    target = out / "trials.jpg"
    sheet.save(target, quality=88)
    return target


# --- The layers, as a pack ships a patch's ---------------------------------------------------------------------------

def candidate_folder(out: Path, candidate: dict) -> Path:
    return out / f"{candidate['letter']}-{candidate['emblem']}"


def write_layers(out: Path) -> None:
    """Each lettered candidate in the form `writer._write_patch` gives a pack's patch, with PNG copies to look at."""
    from packbuilder.writer import ART_QUALITY, PATCH_LAYERS_QUALITY, PATCH_LAYERS_SCALE

    data = prompts()
    for candidate in data["candidates"]:
        source = out / "trials" / candidate["emblem"] / f"{candidate['seed']}.png"
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if digest != candidate["sha256"]:
            raise SystemExit(f"{source} is not the candidate {candidate['letter']} that was pinned ({digest})")
        with Image.open(source) as opened:
            made = layers(trim_rim(opened))
        folder = candidate_folder(out, candidate)
        folder.mkdir(parents=True, exist_ok=True)
        made.colour.save(folder / "patch.avif", "AVIF", quality=ART_QUALITY)
        packed = Image.merge("RGB", [made.height, made.cord, made.order])
        packed = packed.resize((round(packed.width * PATCH_LAYERS_SCALE), round(packed.height * PATCH_LAYERS_SCALE)), Image.LANCZOS)
        packed.save(folder / "patch-layers.avif", "AVIF", quality=PATCH_LAYERS_QUALITY, subsampling="4:4:4")
        made.colour.save(folder / "patch.png")
        made.height.save(folder / "height.png")
        made.cord.save(folder / "cord.png")
        made.order.save(folder / "order.png")
        row = {
            "letter": candidate["letter"], "emblem": candidate["emblem"], "title": data["emblems"][candidate["emblem"]]["title"],
            "file": "patch.avif", "layers_file": "patch-layers.avif", "width": made.colour.width, "height": made.colour.height,
            "layers_width": packed.width, "layers_height": packed.height,
            "ground": "#{:02X}{:02X}{:02X}".format(*made.ground), "stitch_bounds": list(made.bounds),
            "seed": candidate["seed"], "source_sha256": digest, "workflow": data["workflow"], "prompts": data["version"],
            "bytes": {"patch.avif": (folder / "patch.avif").stat().st_size, "patch-layers.avif": (folder / "patch-layers.avif").stat().st_size},
        }
        (folder / "patch.json").write_text(json.dumps(row, indent=1) + "\n")
        print(f"{folder}: {made.colour.width} x {made.colour.height}, ground {row['ground']}, {len(made.bounds) - 1} stitch layers, {row['bytes']}")


# --- The contact sheet: the app's drawing, by numpy and PIL ----------------------------------------------------------

S = 2
"""Pixels to a point on the sheet."""
REPO = ART_DIR.parent
ASSETS = REPO / "BirdJournal" / "BirdJournal" / "Assets.xcassets"
REST = (-0.46, -0.62)                       # PatchLightModel.rest
CANVAS, CORD = (0xD8, 0xCB, 0xB0), (0x6E, 0x4B, 0x2E)   # PatchEdition.of(setID: nil)
CARD_STOCK, CARD_INK, CARD_EDGE = (0xF1, 0xEB, 0xDD), (0x15, 0x36, 0x3A), (0x2F, 0x5F, 0x5C)
FELT_VEIL = (0x08, 0x1A, 0x1D)
SERIF, SANS = "/System/Library/Fonts/NewYork.ttf", "/System/Library/Fonts/SFNS.ttf"
NAMES = ("Verdin", "Northern Rough-winged Swallow", "Eurasian Blue Tit")
TILE, PAGE, GAP = 114, 286, 14
"""A board's tile on an iPhone 17 Pro at the default text size (three across, `PatchBoardLayout`), and the patch on its
page (the 330 pt footprint less its padding)."""


def typeface(path: str, pixels: float, weight: int, optical: float | None = None) -> ImageFont.FreeTypeFont:
    """A system face `pixels` high at `weight`, cut for `optical` points (the size it stands for on the phone)."""
    face = ImageFont.truetype(path, round(pixels))
    axes = []
    for axis in face.get_variation_axes():
        name = axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
        value = {"Weight": weight, "Optical Size": optical or pixels / S}.get(name, axis["default"])
        axes.append(min(max(value, axis["minimum"]), axis["maximum"]))
    face.set_variation_by_axes(axes)
    return face


def lit(colour: Image.Image, packed: Image.Image, width: float, full: bool, soft: float) -> Image.Image:
    """`PatchShader.metal` for a finished patch with the light at rest: `colour` on transparency and its packed layers,
    drawn `width` points wide with room around it for its shadow (`LitPatch`)."""
    room = (34 if full else 14) * S
    colour, packed = colour.convert("RGBA"), packed.convert("RGB")
    colour.thumbnail((720, 720) if full else (360, 360), Image.LANCZOS)     # PatchTextures.Size
    packed.thumbnail((360, 360) if full else (180, 180), Image.LANCZOS)
    w, h = round(width * S), round(width * S * colour.height / colour.width)
    rgba = np.asarray(colour.convert("RGBa").resize((w, h), Image.BILINEAR)).astype(float) / 255
    alpha = rgba[..., 3]
    base = rgba[..., :3] / np.maximum(alpha, 1e-3)[..., None]
    layer = np.asarray(packed).astype(float) / 255
    height = layer[..., 0]
    dx = ndimage.correlate(height, np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]], float), mode="nearest")
    dy = ndimage.correlate(height, np.array([[-1, -2, -1], [0, 0, 0], [1, 2, 1]], float), mode="nearest")

    def spread(values: np.ndarray) -> np.ndarray:
        return np.asarray(Image.fromarray(values.astype(np.float32), "F").resize((w, h), Image.BILINEAR))

    dx, dy, cord = spread(dx), spread(dy), spread(layer[..., 1])
    normal = np.dstack([-dx * 1.6, -dy * 1.6, np.ones_like(dx)])
    normal /= np.linalg.norm(normal, axis=-1, keepdims=True)
    to_light = np.array([REST[0], REST[1], 1.0])
    to_light /= np.linalg.norm(to_light)
    diffuse = np.clip(1.6 * (normal @ to_light) - 0.27, 0.5, 1.28)
    v, u = np.mgrid[0:h, 0:w]
    fx, fy = (u + 0.5) / w - 0.5 - REST[0] * 0.6, (v + 0.5) / h - 0.5 - REST[1] * 0.6
    spot = np.exp(-(fx * fx + fy * fy) / (2 * 0.27 * 0.27))
    halfway = to_light + np.array([0, 0, 1.0])
    halfway /= np.linalg.norm(halfway)
    facing = np.maximum(normal @ halfway, 0)
    sheen = spot * 0.27 * (0.45 + 0.55 * facing ** 8) * (1 - cord) + spot * 0.18 * facing ** 4 * cord
    shaded = np.minimum(base * diffuse[..., None] + sheen[..., None] * np.array([1, 1, 0.98]), 1)

    covered = np.pad(alpha, room)
    scale = min(max(width / 300, 0.28), 1.0)
    away = np.array([-REST[0], -REST[1]]) * 9 * scale / 0.77 * S
    soft_part = ndimage.shift(ndimage.gaussian_filter(covered, 10 * scale * S / 2), (away[1], away[0]), order=1) * soft
    contact = ndimage.shift(ndimage.gaussian_filter(covered, 2 * scale * S / 2), (-REST[1] * scale * S, -REST[0] * scale * S), order=1) * min(soft * 1.32, 0.5)
    shadow = 1 - (1 - np.clip(soft_part, 0, 1)) * (1 - np.clip(contact, 0, 1))
    out_alpha = covered + shadow * (1 - covered)
    premultiplied = np.pad(shaded * alpha[..., None], ((room, room), (room, room), (0, 0)))
    straight = premultiplied / np.maximum(out_alpha, 1e-3)[..., None]
    return Image.fromarray((np.dstack([straight, out_alpha]).clip(0, 1) * 255).astype(np.uint8), "RGBA")


def blank(width: float, soft: float) -> Image.Image:
    """Today's Uncharted blank (`PatchBlank`): the canvas round with its printed weave and its cord, on its shadow, with
    14 points of room around it."""
    k = S * 3
    side, room = round(width * k), 14 * k
    face = Image.new("RGBA", (side + 2 * room, side + 2 * room), (0, 0, 0, 0))
    box = (room, room, room + side - 1, room + side - 1)
    disc = Image.new("L", face.size, 0)
    ImageDraw.Draw(disc).ellipse(box, fill=255)
    cloth = Image.new("RGBA", face.size, CANVAS + (255,))
    weave = Image.new("RGBA", face.size, (0, 0, 0, 0))
    lines = ImageDraw.Draw(weave)
    step = 0.0
    while step <= width:
        offset = room + round(step * k)
        lines.line([(offset, room), (offset, room + side)], fill=(0, 0, 0, round(255 * 0.07)), width=round(0.75 * k))
        lines.line([(room, offset), (room + side, offset)], fill=(0, 0, 0, round(255 * 0.07)), width=round(0.75 * k))
        step += 2.5
    cloth = Image.alpha_composite(cloth, weave)
    face.paste(cloth, (0, 0), disc)
    cord = max(width * 0.035, 3) * k
    ImageDraw.Draw(face).ellipse((box[0] - cord / 2, box[1] - cord / 2, box[2] + cord / 2, box[3] + cord / 2), outline=CORD + (255,), width=round(cord))
    alpha = np.asarray(face)[..., 3].astype(float) / 255
    shadow = ndimage.shift(ndimage.gaussian_filter(alpha, 2.5 * k), (5 * k, 3 * k), order=1) * soft
    under = Image.fromarray(np.dstack([np.zeros(alpha.shape + (3,)), shadow * 255]).astype(np.uint8), "RGBA")
    whole = Image.alpha_composite(under, face)
    return whole.resize((whole.width // 3, whole.height // 3), Image.LANCZOS)


def wrapped(text: str, face: ImageFont.FreeTypeFont, width: float, limit: int = 3) -> list[str]:
    """Greedy lines no wider than `width`, breaking at spaces and after hyphens, as the system does."""
    pieces = []
    for word in text.split(" "):
        parts = word.split("-")
        pieces += [(part + "-" if i < len(parts) - 1 else part, i == 0) for i, part in enumerate(parts)]
    lines: list[str] = []
    for piece, spaced in pieces:
        joined = (lines[-1] + (" " if spaced else "") + piece) if lines else piece
        if lines and face.getlength(joined) <= width:
            lines[-1] = joined
        else:
            lines.append(piece)
    return lines[:limit]


def tie_tag(sheet: Image.Image, origin: tuple[int, int], width: float, height: float, text: str, drop: float = 0.1) -> tuple[float, float]:
    """`TiedTag`: the slot, the thread and the paper tag with `text`, over a patch whose face is at `origin` (pixels) and
    `width` by `height` points. Returns where the paper starts and ends, as parts of the patch's height."""
    k = 2
    scale = S * k
    small = width < 200
    pad_x, pad_y = ((6, 3) if small else (12, 6))
    for shrink in (1.0, 0.95, 0.9, 0.85):       # minimumScaleFactor(0.85) under lineLimit(3)
        face = typeface(SERIF, (11 if small else 15) * shrink * scale, 600 if small else 500, optical=(11 if small else 15) * shrink)
        line_height = (13 if small else 20) * shrink * scale
        lines = wrapped(text, face, (width * 0.8 - 2 * pad_x) * scale, limit=99)
        if len(lines) <= 3:
            break
    lines = lines[:3]
    layer = Image.new("RGBA", (round(width * scale), round(height * scale)), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    middle = layer.width / 2
    y = height * drop * scale
    slot_w, slot_h = max(width * 0.12, 10) * scale, max(height * 0.022, 3) * scale
    draw.rounded_rectangle((middle - slot_w / 2, y, middle + slot_w / 2, y + slot_h), radius=slot_h / 2, fill=(0, 0, 0, 128))
    y += slot_h
    draw.rectangle((middle - scale / 2, y, middle + scale / 2, y + height * 0.1 * scale), fill=CARD_EDGE + (255,))
    y += height * 0.1 * scale
    paper_w = max(face.getlength(line) for line in lines) + 2 * pad_x * scale
    paper_h = len(lines) * line_height + 2 * pad_y * scale
    paper = (middle - paper_w / 2, y, middle + paper_w / 2, y + paper_h)
    shade = Image.new("L", layer.size, 0)
    ImageDraw.Draw(shade).rounded_rectangle((paper[0] + scale, paper[1] + 2 * scale, paper[2] + scale, paper[3] + 2 * scale), radius=3 * scale, fill=round(255 * 0.3))
    shade = shade.filter(ImageFilter.GaussianBlur(1.0 * scale))
    layer = Image.alpha_composite(Image.merge("RGBA", [Image.new("L", layer.size, 0)] * 3 + [shade]), layer)
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle(paper, radius=3 * scale, fill=CARD_STOCK + (255,))
    for index, line in enumerate(lines):
        draw.text((middle, y + pad_y * scale + index * line_height + line_height / 2), line, font=face, fill=CARD_INK + (255,), anchor="mm")
    layer = layer.resize((layer.width // k, layer.height // k), Image.LANCZOS)
    sheet.alpha_composite(layer, origin)
    return (y / scale / height, (y + paper_h) / scale / height)


class Sheet:
    """The contact sheet's page: the board's material, with patches and words put on it in points."""

    def __init__(self, width: float, height: float, dark: bool):
        self.dark = dark
        self.soft = 0.38 if dark else 0.28          # PatchMaterial.softShadow
        self.ink = (0xEC, 0xE6, 0xD8) if dark else CARD_INK
        name = "MaterialFelt.imageset/felt.jpg" if dark else "MaterialLinen.imageset/linen.jpg"
        with Image.open(ASSETS / name) as opened:
            tile = opened.convert("RGB")
        tile = tile.resize((tile.width * S // 2, tile.height * S // 2), Image.LANCZOS)   # a 2x asset
        veil = Image.new("RGB", tile.size, FELT_VEIL if dark else (255, 255, 255))
        tile = Image.blend(tile, veil, 0.6 if dark else 0.45)                              # BoardMaterial
        self.image = Image.new("RGBA", (round(width * S), round(height * S)))
        for x in range(0, self.image.width, tile.width):
            for y in range(0, self.image.height, tile.height):
                self.image.paste(tile, (x, y))
        self.draw = ImageDraw.Draw(self.image)

    def words(self, x: float, y: float, text: str, points: float, weight: int = 400, serif: bool = False, anchor: str = "la", fill=None) -> None:
        self.draw.text((x * S, y * S), text, font=typeface(SERIF if serif else SANS, points * S, weight), fill=fill or self.ink, anchor=anchor)

    def patch(self, picture: Image.Image, x: float, y: float, width: float, room: float) -> tuple[int, int]:
        """Puts a patch drawn with `room` points around it so that its face's corner is at (x, y); returns that corner in pixels."""
        self.image.alpha_composite(picture, (round((x - room) * S), round((y - room) * S)))
        self.draw = ImageDraw.Draw(self.image)
        return round(x * S), round(y * S)

    def tile(self, picture: Image.Image, x: float, y: float, name: str, line: str, tag: str | None, room: float = 14) -> None:
        """`PatchTile`: the patch with its name and its line under it, and its paper tag when it has one."""
        width = picture.width / S - 2 * room
        height = picture.height / S - 2 * room
        corner = self.patch(picture, x, y, width, room)
        if tag:
            tie_tag(self.image, corner, width, height, tag)
            self.draw = ImageDraw.Draw(self.image)
        name_face = typeface(SERIF, 13 * S, 600)
        below = y + height + 6
        for index, text in enumerate(wrapped(name, name_face, width * S + 8 * S, limit=2)):
            self.draw.text(((x + width / 2) * S, (below + index * 17) * S), text, font=name_face, fill=self.ink, anchor="ma")
            last = below + (index + 1) * 17
        self.words(x + width / 2, last + 2, line, 11, anchor="ma")


def pictures(path: Path) -> tuple[Image.Image, Image.Image]:
    """A patch's colour and packed layers: a pack's two AVIFs (or a candidate's), or a cut patch's PNG, layered here."""
    path = Path(path)
    if path.suffix == ".avif":
        with Image.open(path) as colour, Image.open(path.with_name(f"{path.stem}-layers.avif")) as packed:
            return colour.convert("RGBA"), packed.convert("RGB")
    with Image.open(path) as cut:
        made = layers(trim_rim(cut))
    return made.colour, Image.merge("RGB", [made.height, made.cord, made.order])


def contact_sheet(out: Path, beside: list[tuple[str, str, Path]], dark: bool = True) -> Path:
    """`OUT/contact-sheet.jpg` (or `-light`): a band for today's blank and one per candidate. `beside` are two painted
    edition patches (name, line, file) for the last column."""
    data = prompts()
    candidates = data["candidates"]
    margin, head = 24, 34
    band = head + PAGE + 40
    columns = (margin, margin + PAGE + 44, margin + PAGE + 44 + 3 * TILE + 2 * GAP + 44)
    width = columns[2] + 3 * TILE + 2 * GAP + margin
    top = 92
    sheet = Sheet(width, top + band * (len(candidates) + 1) + 10, dark)
    sheet.words(margin, 20, "Generic Uncharted patch: candidates (#221)", 22, 700)
    sheet.words(margin, 52, "Each as the app would draw it, lit with the light at rest, with the bird's name on its paper tag. Candidates only: the pick ships with #222.", 12)
    for x, label in zip(columns, ("On its page (286 pt)", "On the Uncharted board (three across, 114 pt)", "Beside painted edition patches")):
        sheet.words(x, 74, label, 11, 600)
    neighbours = [(name, line, lit(*pictures(path), TILE, False, sheet.soft)) for name, line, path in beside]

    def row(index: int, title: str, small: callable, large: Image.Image, large_room: float) -> None:
        y = top + index * band
        sheet.draw.line([(margin * S, y * S), ((width - margin) * S, y * S)], fill=sheet.ink + (90,), width=1)
        sheet.words(margin, y + 8, title, 16, 700)
        y += head
        corner = sheet.patch(large, columns[0], y, PAGE, large_room)
        tie_tag(sheet.image, corner, PAGE, large.height / S - 2 * large_room, NAMES[1])
        sheet.draw = ImageDraw.Draw(sheet.image)
        for position, name in enumerate(NAMES):
            sheet.tile(small(), columns[1] + position * (TILE + GAP), y + 30, name, "Uncharted", name)
        if neighbours:
            sheet.tile(neighbours[0][2], columns[2], y + 30, neighbours[0][0], neighbours[0][1], None)
            sheet.tile(small(), columns[2] + TILE + GAP, y + 30, NAMES[0], "Uncharted", NAMES[0])
            sheet.tile(neighbours[1][2], columns[2] + 2 * (TILE + GAP), y + 30, neighbours[1][0], neighbours[1][1], None)

    row(0, "Today: the blank canvas round", lambda: blank(TILE, sheet.soft), blank(PAGE, sheet.soft), 14)
    for index, candidate in enumerate(candidates, start=1):
        folder = candidate_folder(out, candidate)
        colour, packed = pictures(folder / "patch.avif")
        title = f"{candidate['letter']}   {data['emblems'][candidate['emblem']]['title']}"
        row(index, title, lambda: lit(colour, packed, TILE, False, sheet.soft), lit(colour, packed, PAGE, True, sheet.soft), 34)
    target = out / ("contact-sheet.jpg" if dark else "contact-sheet-light.jpg")
    sheet.image.convert("RGB").save(target, quality=90)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    painting = commands.add_parser("paint")
    painting.add_argument("out", type=Path)
    painting.add_argument("--only", action="append", default=[])
    painting.add_argument("--trials", type=int, default=4)
    commands.add_parser("trials").add_argument("out", type=Path)
    commands.add_parser("layers").add_argument("out", type=Path)
    sheets = commands.add_parser("sheet")
    sheets.add_argument("out", type=Path)
    sheets.add_argument("--beside", action="append", default=[], metavar="NAME|LINE|FILE", help="a painted edition patch for the last column (twice): a pack's patch/<id>.avif or a cut patch's PNG")
    sheets.add_argument("--light", action="store_true", help="the light appearance's linen board")
    arguments = parser.parse_args()
    if arguments.command == "paint":
        paint(arguments.out, arguments.only, arguments.trials)
    elif arguments.command == "trials":
        print(trials_sheet(arguments.out))
    elif arguments.command == "layers":
        write_layers(arguments.out)
    elif arguments.command == "sheet":
        beside = [(name, line, Path(file)) for name, line, file in (entry.split("|") for entry in arguments.beside)]
        if len(beside) not in (0, 2):
            raise SystemExit("--beside takes two patches, or none")
        print(contact_sheet(arguments.out, beside, dark=not arguments.light))


if __name__ == "__main__":
    sys.exit(main())
