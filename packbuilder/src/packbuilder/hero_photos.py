"""Hero photos (#150): one review of the photo a bird's profile opens with, the first of its photos in the pack.

The profile draws that photo filling a 3:2 slot, centred (`AttributedImage` in the app). A portrait photo therefore loses
its top and bottom, and a bird in the wrong place loses its head: Black Phoebe's profile opened on a blurry back. So the
sheets show each first photo as the profile shows it, and `assess` flags a bird the slot or the photo's own frame cuts,
by the detector's box. The detector is a hint for the reviewer, not a judge: its box is loose, and it can't tell a head
from a tail.

A replacement comes from the wider pool of the species' cleared photos in the cache (`candidates`). It goes in
`overrides.json` as a proposal, `"hero": {"proposed": <photo id>, "_why": ...}`, which the build ignores. `review` turns
an accepted proposal into the pin: first in `include`, with the species' patch and silhouette photos after it, as a pack
holds five photos and those two must stay for their credits to stand.
"""

from __future__ import annotations

import json
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from packbuilder.candidates import filter_candidates
from packbuilder.contact_sheets import grid
from packbuilder.crops import phone_crop_box, render_phone, upright
from packbuilder.definition import PackDefinition, SpeciesEntry
from packbuilder.geometry import Box
from packbuilder.pack_art import ArtLock, lighting
from packbuilder.patch_art import LOCK_FILE as PATCH_LOCK
from packbuilder.pipeline import MIN_BIRD_AREA, MIN_BIRD_PIXELS, MIN_SHARPNESS, Detector, MetadataSource, bird_pixels, per_observation, shared_photo_ids, too_small_for_lens
from packbuilder.scoring import score_crop
from packbuilder.selection import Overrides
from packbuilder.silhouettes import LOCK_FILE as SILHOUETTE_LOCK

SLOT_ASPECT = 3 / 2
"""The profile's photo slot: `AttributedImage.aspectRatio` in the app."""
FRAME_MARGIN = 0.012
"""A box this close to the photo's edge (a share of its side) has run into the frame."""
SLOT_MARGIN = 0.04
"""A box past the slot's edge by this share of the bird's own size has lost part of the bird there."""
CELL = (330, 220)


@dataclass(frozen=True)
class FirstPhoto:
    """A species' first photo in the built pack, numbered as on the sheets."""

    number: int
    species_id: str
    common_name: str
    photo_id: int
    file: Path


def first_photos(pack_dir: Path) -> list[FirstPhoto]:
    """Every species' first photo, in the pack's order, numbered as in pack.json: a species with no photo keeps its number."""
    pack_dir = Path(pack_dir)
    with closing(sqlite3.connect(pack_dir / "pack.sqlite")) as db:
        rows = db.execute(
            "SELECT s.sort_order, s.id, s.common_name, p.inat_photo_id, p.file_phone FROM species s JOIN photo p ON p.species_id = s.id AND p.rank = 0 ORDER BY s.sort_order"
        ).fetchall()
    return [FirstPhoto(order + 1, species_id, name, photo_id, pack_dir / file) for order, species_id, name, photo_id, file in rows]


def slot_of(size: tuple[int, int]) -> tuple[int, int, int, int]:
    """What the profile's slot shows of a picture of `size`: the middle of it at 3:2, in pixels."""
    width, height = size
    if width / height > SLOT_ASPECT:
        shown = round(height * SLOT_ASPECT)
        left = (width - shown) // 2
        return left, 0, left + shown, height
    shown = round(width / SLOT_ASPECT)
    top = (height - shown) // 2
    return 0, top, width, top + shown


def as_shown(picture: Image.Image) -> Image.Image:
    """The picture as the profile's slot shows it."""
    return picture.convert("RGB").crop(slot_of(picture.size))


def cuts(box: Box, size: tuple[int, int]) -> list[str]:
    """Where the bird in `box` (fractions of a picture of `size`) doesn't all show in the slot: "frame: top" when it runs
    into the picture's edge, "slot: top" when it is in the picture and the slot crops it."""
    width, height = size
    left, top, right, bottom = slot_of(size)
    bird_width, bird_height = (box.x1 - box.x0) * width, (box.y1 - box.y0) * height
    found = []
    sides = (
        ("left", box.x0, box.x0 * width - left, bird_width), ("right", 1 - box.x1, right - box.x1 * width, bird_width),
        ("top", box.y0, box.y0 * height - top, bird_height), ("bottom", 1 - box.y1, bottom - box.y1 * height, bird_height),
    )
    for side, to_frame, to_slot, bird in sides:
        if to_frame < FRAME_MARGIN:
            found.append(f"frame: {side}")
        elif to_slot < -SLOT_MARGIN * bird:
            found.append(f"slot: {side}")
    return found


def assess(picture: Image.Image, detector: Detector) -> list[str]:
    """What the sheet says about a first photo: its `cuts`, or that no bird was found."""
    detections = detector.detect(picture)
    return cuts(detections[0].box, picture.size) if detections else ["no bird found"]


@dataclass(frozen=True)
class Candidate:
    """A photo of the wider pool that shows the whole bird in the slot."""

    photo_id: int
    picture: Image.Image
    """As the profile would show it."""
    light: float
    sharpness: float
    rank: float


def candidates(entry: SpeciesEntry, overrides: Overrides, metadata: MetadataSource, detector: Detector, cache_dir: Path, shared: frozenset[int] = frozenset(), top: int = 6) -> list[Candidate]:
    """The species' best photos for a hero among the cleared ones already in the cache: the rules the build applies to
    any photo, then only a whole bird in the slot, ranked by the light on it and its sharpness (the lens score prefers a
    dark background, which is no reason here)."""
    kept = filter_candidates(metadata.candidates_for(entry.inat_taxon_id)).kept
    excluded_observations = {c.source_url for c in kept if c.photo_id in overrides.exclude}
    pool = per_observation([c for c in kept if c.photo_id not in overrides.exclude and c.source_url not in excluded_observations and c.photo_id not in shared])
    found = []
    for candidate in pool:
        path = Path(cache_dir) / "photos" / "large" / f"{candidate.photo_id}.{candidate.extension}"
        if not path.exists() or too_small_for_lens(candidate):
            continue
        with Image.open(path) as opened:
            image = upright(opened).convert("RGB")
        detections = detector.detect(image)
        if not detections:
            continue
        box = detections[0].box
        if box.area < MIN_BIRD_AREA or bird_pixels(candidate, image.size, box) < MIN_BIRD_PIXELS:
            continue
        sharpness = score_crop(image, box).sharpness
        if sharpness < MIN_SHARPNESS:
            continue
        left, top_edge, right, bottom = phone_crop_box(box, image.size)
        crop_size = (right - left, bottom - top_edge)
        inside = Box((box.x0 * image.width - left) / crop_size[0], (box.y0 * image.height - top_edge) / crop_size[1],
                     (box.x1 * image.width - left) / crop_size[0], (box.y1 * image.height - top_edge) / crop_size[1])
        # The phone crop stops at the original's frame: a box at the original's edge is a bird it cuts, wherever the crop ends.
        if cuts(inside, crop_size) or box.x0 < FRAME_MARGIN or box.y0 < FRAME_MARGIN or box.x1 > 1 - FRAME_MARGIN or box.y1 > 1 - FRAME_MARGIN:
            continue
        light = lighting(image, box)
        found.append(Candidate(candidate.photo_id, as_shown(render_phone(image, box)), light, sharpness, light * sharpness))
    return sorted(found, key=lambda c: -c.rank)[:top]


def _as_the_build_would(photo_id: int, cache_dir: Path, detector: Detector) -> Image.Image | None:
    """A proposed photo as the profile would show it, from its cached rendition."""
    path = next(iter(sorted((Path(cache_dir) / "photos" / "large").glob(f"{photo_id}.*"))), None)
    if path is None:
        return None
    with Image.open(path) as opened:
        image = upright(opened).convert("RGB")
    detections = detector.detect(image)
    return as_shown(render_phone(image, detections[0].box) if detections else image)


def proposals_in(definition: PackDefinition, overrides: dict) -> dict[str, dict]:
    """The species with a proposal in the overrides, by species id."""
    found = {}
    for entry in definition.species:
        data = overrides.get(entry.scientific_name)
        if isinstance(data, dict) and isinstance(data.get("hero"), dict) and data["hero"].get("proposed") is not None:
            found[entry.id] = data["hero"]
    return found


def sheets(definition: PackDefinition, overrides: dict, firsts: list[FirstPhoto], detector: Detector, cache_dir: Path, out_dir: Path, per_sheet: int = 30, proposals_per_sheet: int = 15) -> tuple[list[Path], dict[int, list[str]]]:
    """The review's sheets: every first photo as the profile shows it, numbered and flagged, then each proposal beside the
    photo it would replace. Returns them and the flags by number."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in [*out_dir.glob("first-*.jpg"), *out_dir.glob("proposals-*.jpg")]:
        old.unlink()
    proposals = proposals_in(definition, overrides)
    cells, pairs, flags = [], [], {}
    for first in firsts:
        with Image.open(first.file) as opened:
            picture = opened.convert("RGB")
        noticed = assess(picture, detector)
        if noticed:
            flags[first.number] = noticed
        shown = as_shown(picture)
        note = ", ".join(noticed).upper() if noticed else ""
        if first.species_id in proposals:
            note = f"{note} · replacement proposed".removeprefix(" · ")
        cells.append((shown, f"{first.number:03d} {first.common_name}\n{note}"))
        if first.species_id in proposals:
            photo_id = int(proposals[first.species_id]["proposed"])
            pairs.append(((shown, f"{first.number:03d} {first.common_name}\nnow: {first.photo_id}"),
                          (_as_the_build_would(photo_id, cache_dir, detector), f"proposed: {photo_id}\n{proposals[first.species_id].get('_why', '')}")))
    made = []
    for start in range(0, len(cells), per_sheet):
        chunk = cells[start:start + per_sheet]
        rows = [chunk[i:i + 6] for i in range(0, len(chunk), 6)]
        target = out_dir / f"first-{start // per_sheet + 1:02d}.jpg"
        grid(rows, f"{definition.id} first photos {start + 1}-{start + len(chunk)} of {len(cells)}, as a bird's profile shows them (the middle at 3:2)", [], cell=CELL).save(target, quality=86)
        made.append(target)
    for start in range(0, len(pairs), proposals_per_sheet):
        chunk = pairs[start:start + proposals_per_sheet]
        rows = [[cell for pair in chunk[i:i + 3] for cell in pair] for i in range(0, len(chunk), 3)]
        target = out_dir / f"proposals-{start // proposals_per_sheet + 1:02d}.jpg"
        grid(rows, f"{definition.id} proposed first photos {start + 1}-{start + len(chunk)} of {len(pairs)}: the photo now, then the proposal, as the profile shows them", [], cell=CELL).save(target, quality=86)
        made.append(target)
    return made, flags


def candidate_sheet(definition: PackDefinition, overrides: dict, species: list[str], metadata: MetadataSource, detector: Detector, cache_dir: Path, target: Path, top: int = 6) -> Path:
    """For choosing a proposal: each of these species ids' best photos from the wider pool, with their ids."""
    shared = shared_photo_ids(definition.species, metadata)
    numbered = {entry.id: (number, entry) for number, entry in enumerate(definition.species, start=1)}
    rows = []
    for species_id in species:
        number, entry = numbered[species_id]
        found = candidates(entry, Overrides.from_mapping(overrides.get(entry.scientific_name, {})), metadata, detector, cache_dir, shared, top)
        row = [(c.picture, f"{number:03d} {entry.common_name}\n{c.photo_id} light {c.light:.2f} sharp {c.sharpness:.2f}") for c in found]
        rows.append(row or [(None, f"{number:03d} {entry.common_name}\nnothing cached shows the whole bird")])
    Path(target).parent.mkdir(parents=True, exist_ok=True)
    grid(rows, f"{definition.id} candidates for a first photo", [], cell=CELL).save(target, quality=86)
    return Path(target)


def write_overrides(path: Path, overrides: dict) -> None:
    """The file in the format it is committed in, so a review's diff is only the review."""
    Path(path).write_text(json.dumps(overrides, indent=1, ensure_ascii=False) + "\n")


def propose(definition: PackDefinition, overrides: dict, species_id: str, photo_id: int, why: str) -> None:
    """Records a proposal for this species id, which changes nothing in a build until `review` accepts it. Raises ValueError
    on a photo the overrides already exclude: the build would drop it."""
    entry = next(e for e in definition.species if e.id == species_id)
    data = overrides.setdefault(entry.scientific_name, {})
    if photo_id in data.get("exclude", []):
        raise ValueError(f"{entry.common_name}: photo {photo_id} is excluded in the overrides")
    data["hero"] = {"proposed": photo_id, "_why": why}


def review(definition: PackDefinition, overrides: dict, definition_dir: Path, accept: list[str] = (), decline: list[str] = (), accept_all: bool = False) -> tuple[list[str], list[str]]:
    """The maintainer's answer: `accept` pins a proposal, first in `include` with the species' patch and silhouette photos
    kept after it; `decline` drops one, which stays out of the build as it always was; `accept_all` accepts whatever
    this answer doesn't decline. Raises KeyError, having changed nothing, when a species named has no proposal, and
    ValueError when one is both accepted and declined."""
    proposals = proposals_in(definition, overrides)
    if both := set(accept) & set(decline):
        raise ValueError(f"both accepted and declined: {', '.join(sorted(both))}")
    for species_id in (*accept, *decline):
        if species_id not in proposals:
            raise KeyError(f"no proposal for {species_id} in the overrides")
    accepted = list(accept) + ([species_id for species_id in proposals if species_id not in accept and species_id not in decline] if accept_all else [])
    by_id = {entry.id: entry for entry in definition.species}
    for species_id in accepted:
        data = overrides[by_id[species_id].scientific_name]
        hero = data["hero"]
        photo_id = int(hero["proposed"])
        # The credited ones come straight after it: a long `include` must push out anything but them.
        data["include"] = list(dict.fromkeys([photo_id, *_credited_photos(definition_dir, species_id), *data.get("include", [])]))
        data["hero"] = {"pinned": photo_id, "_why": hero.get("_why", "")}
    for species_id in decline:
        name = by_id[species_id].scientific_name
        del overrides[name]["hero"]
        if not overrides[name]:
            del overrides[name]
    return accepted, list(decline)


def _credited_photos(definition_dir: Path, species_id: str) -> list[int]:
    """The photos the species' patch and silhouette credit: they have to stay in the pack."""
    photos = []
    for lock in (PATCH_LOCK, SILHOUETTE_LOCK):
        photos += ArtLock.load(Path(definition_dir) / lock).species.get(species_id, {}).get("photos", [])
    return photos
