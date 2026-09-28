"""Runs the whole build for one pack definition (see the package docstring for the steps)."""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Protocol

from PIL import Image

from packbuilder.candidates import PhotoCandidate, filter_candidates
from packbuilder.crops import LENS_HEIGHT, LENS_PADDING, LENS_WIDTH, upright
from packbuilder.definition import PackDefinition, SpeciesEntry, load_overrides
from packbuilder.descriptions import Description
from packbuilder.detector import Detection
from packbuilder.download import fetch_photo
from packbuilder.geometry import Box
from packbuilder.scoring import score_crop
from packbuilder.selection import Overrides, ScoredPhoto, select_photos
from packbuilder.writer import ChosenPhoto, SpeciesResult, WrittenPack, write_pack

log = logging.getLogger("packbuilder")

# Birds smaller than this fraction of the frame make a soft lens crop even from a 2048-pixel original.
MIN_BIRD_AREA = 0.02
# Below this sharpness (see scoring.py) a crop is motion blur or out of focus; area and a dark background would
# otherwise carry it into the top five.
MIN_SHARPNESS = 0.4
# The bird's padded box (1.4 × the bird) must reach the lens crop's height in the original, or the lens JPEG would be
# upscaled: about 263 pixels.
MIN_BIRD_PIXELS = round(LENS_HEIGHT / (1 + 2 * LENS_PADDING))

FULL_FRAME = Box(0.0, 0.0, 1.0, 1.0)


class MetadataSource(Protocol):
    def candidates_for(self, taxon_id: int) -> list[PhotoCandidate]: ...


class Detector(Protocol):
    def detect(self, image: Image.Image) -> list[Detection]: ...


class DescriptionSource(Protocol):
    def describe(self, entry: SpeciesEntry, trust_article: bool = False) -> Description | None: ...


PhotoFetcher = Callable[[PhotoCandidate, Path, str], Path | None]
"""(candidate, cache_dir, size) -> local path, or None when the photo is gone; `download.fetch_photo` in production."""


@dataclass
class BuildOptions:
    cache_dir: Path
    out_dir: Path
    candidate_limit: int = 60
    """How many license-cleared candidates per species are downloaded and run through the detector."""
    min_photos: int = 3
    """Fewer chosen photos than this is a logged gap."""
    max_photos: int = 5
    archive_path: Path | None = None
    built_at: str | None = None
    fetch: PhotoFetcher = field(default=fetch_photo)
    download_workers: int = 8
    """Concurrent downloads of a species' `large` renditions; the Open Data bucket is the slow step of a big pack."""


def build_pack(definition: PackDefinition, overrides_path: Path, metadata: MetadataSource, detector: Detector, options: BuildOptions, descriptions: DescriptionSource | None = None) -> WrittenPack:
    raw_overrides = load_overrides(overrides_path)
    shared = shared_photo_ids(definition.species, metadata)
    if shared:
        log.info("%d photos belong to observations of two or more species of the pack; none is chosen", len(shared))
    results = [
        build_species(entry, Overrides.from_mapping(raw_overrides.get(entry.scientific_name, {})), metadata, detector, options, descriptions, shared)
        for entry in definition.species
    ]
    built_at = options.built_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    written = write_pack(definition, results, options.out_dir, built_at=built_at, archive_path=options.archive_path)
    gaps = [r.entry.common_name for r in results if r.gap]
    undescribed = [r.entry.common_name for r in results if r.description is None]
    log.info(
        "wrote %s (%d species, %d photos%s%s)",
        written.directory, len(results), sum(len(r.photos) for r in results),
        f"; photo gaps: {', '.join(gaps)}" if gaps else "",
        f"; no description: {', '.join(undescribed)}" if undescribed else "",
    )
    return written


def shared_photo_ids(species: list[SpeciesEntry], metadata: MetadataSource) -> frozenset[int]:
    """Photos attached to observations of more than one species of the pack: one picture of an avocet among pintails
    serves both observations. The detector's box may be either bird, so the photo is a card for neither (and the pack
    keys its photos by iNaturalist id, so it could not be both). The metadata is cached, so this pass costs no
    downloads beyond the ones the build makes anyway."""
    owners: dict[int, set[int]] = {}
    for entry in species:
        for candidate in metadata.candidates_for(entry.inat_taxon_id):
            owners.setdefault(candidate.photo_id, set()).add(entry.inat_taxon_id)
    return frozenset(photo_id for photo_id, taxa in owners.items() if len(taxa) > 1)


def build_species(entry: SpeciesEntry, overrides: Overrides, metadata: MetadataSource, detector: Detector, options: BuildOptions, descriptions: DescriptionSource | None = None, shared: frozenset[int] = frozenset()) -> SpeciesResult:
    log.info("%s (%s)", entry.common_name, entry.scientific_name)
    description = describe(entry, overrides, descriptions)
    candidates = metadata.candidates_for(entry.inat_taxon_id)
    filtered = filter_candidates(candidates)
    rejected = {reason.value: count for reason, count in filtered.rejected.items()}
    log.info("  %d candidates, %d cleared, rejected %s", len(candidates), len(filtered.kept), rejected or "none")

    limit = overrides.candidate_limit or options.candidate_limit
    # An excluded photo takes its observation with it: the other pictures of a dead or hand-held bird are no better.
    excluded_observations = {c.source_url for c in filtered.kept if c.photo_id in overrides.exclude}
    shortlist = [
        c for c in filtered.kept
        if c.photo_id not in overrides.exclude and c.source_url not in excluded_observations and c.photo_id not in shared
    ][:limit]
    shortlist += [c for c in filtered.kept if overrides.forces(c.photo_id) and c not in shortlist]
    missing = set(overrides.include) - {c.photo_id for c in filtered.kept}
    if missing:
        log.warning("  override includes %s, not among the cleared candidates", sorted(missing))

    scored: list[ScoredPhoto] = []
    detected = 0
    blurred = 0
    small = 0
    for candidate, path in zip(shortlist, prefetch(shortlist, options)):
        if path is None:
            continue
        if too_small_for_lens(candidate) and not overrides.forces(candidate.photo_id):
            small += 1
            continue
        with Image.open(path) as opened:
            image = upright(opened)
            detections = detector.detect(image)
            if detections:
                detected += 1
                box = detections[0].box
                too_small = box.area < MIN_BIRD_AREA or bird_pixels(candidate, image.size, box) < MIN_BIRD_PIXELS
                if too_small and not overrides.forces(candidate.photo_id):
                    continue
            elif overrides.forces(candidate.photo_id):
                box = FULL_FRAME  # forced in without a detection: keep the whole frame
            else:
                continue
            score = score_crop(image, box)
            if score.sharpness < MIN_SHARPNESS and not overrides.forces(candidate.photo_id):
                blurred += 1
                continue
            scored.append(ScoredPhoto(candidate=candidate, box=box, score=score))
    log.info("  %d originals under the card size, %d with a bird, %d too blurred, %d scored", small, detected, blurred, len(scored))

    selection = select_photos(scored, overrides, minimum=options.min_photos, maximum=options.max_photos)
    photos: list[ChosenPhoto] = []
    for photo in selection.chosen:
        original = options.fetch(photo.candidate, options.cache_dir, "original")
        if original is None:
            log.warning("  original of %s unavailable; skipped", photo.candidate.photo_id)
            continue
        photos.append(ChosenPhoto(scored=photo, original=original))
    for chosen in photos:
        s = chosen.scored.score
        log.info("  chose %d  total %.2f (area %.2f, dark %.2f, sharp %.2f)  %s", chosen.candidate.photo_id, s.total, s.bird_area, s.background_darkness, s.sharpness, chosen.candidate.source_url)
    gap = len(photos) < options.min_photos
    if gap:
        log.warning("  GAP: only %d photos for %s", len(photos), entry.common_name)
    return SpeciesResult(entry=entry, photos=photos, gap=gap, candidates=len(candidates), rejected=rejected, detected=detected, description=description)


def describe(entry: SpeciesEntry, overrides: Overrides, descriptions: DescriptionSource | None) -> Description | None:
    """The species' description: the source's text with the override fields written over it, the override fields
    alone when the source has nothing, None when neither has anything."""
    derived = descriptions.describe(entry, trust_article=overrides.trust_article) if descriptions is not None else None
    if overrides.description:
        base = derived or Description.empty()
        return base.replaced(overrides.description)
    return derived


def prefetch(candidates: list[PhotoCandidate], options: BuildOptions) -> list[Path | None]:
    """The `large` rendition of every candidate, downloaded `download_workers` at a time, in candidate order."""
    with ThreadPoolExecutor(max_workers=max(1, options.download_workers)) as pool:
        return list(pool.map(lambda candidate: options.fetch(candidate, options.cache_dir, "large"), candidates))


def too_small_for_lens(candidate: PhotoCandidate) -> bool:
    """Whether the original (by the metadata's dimensions) is narrower or shorter than the lens crop, so any crop of it
    would be upscaled into the card; unknown dimensions are checked later against the bird box."""
    return bool(candidate.width and candidate.height) and (candidate.width < LENS_WIDTH or candidate.height < LENS_HEIGHT)


def bird_pixels(candidate: PhotoCandidate, large_size: tuple[int, int], box: Box) -> float:
    """The bird box's longer side in pixels of the original photo (the metadata's dimensions, or twice the `large`
    rendition when they are unknown)."""
    width, height = (candidate.width, candidate.height) if candidate.width and candidate.height else (large_size[0] * 2, large_size[1] * 2)
    return max((box.x1 - box.x0) * width, (box.y1 - box.y0) * height)
