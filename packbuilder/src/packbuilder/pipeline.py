"""Runs the whole build for one pack definition (see the package docstring for the steps)."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Protocol

from PIL import Image

from packbuilder.candidates import PhotoCandidate, filter_candidates
from packbuilder.crops import upright
from packbuilder.definition import PackDefinition, SpeciesEntry, load_overrides
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
# The bird must span about the lens crop's 368-pixel height in the original (its padded box is 1.4 × the bird), or
# the lens JPEG would be upscaled.
MIN_BIRD_PIXELS = 260

FULL_FRAME = Box(0.0, 0.0, 1.0, 1.0)


class MetadataSource(Protocol):
    def candidates_for(self, taxon_id: int) -> list[PhotoCandidate]: ...


class Detector(Protocol):
    def detect(self, image: Image.Image) -> list[Detection]: ...


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


def build_pack(definition: PackDefinition, overrides_path: Path, metadata: MetadataSource, detector: Detector, options: BuildOptions) -> WrittenPack:
    raw_overrides = load_overrides(overrides_path)
    results = [
        build_species(entry, Overrides.from_mapping(raw_overrides.get(entry.scientific_name, {})), metadata, detector, options)
        for entry in definition.species
    ]
    built_at = options.built_at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    written = write_pack(definition, results, options.out_dir, built_at=built_at, archive_path=options.archive_path)
    gaps = [r.entry.common_name for r in results if r.gap]
    log.info("wrote %s (%d species, %d photos%s)", written.directory, len(results), sum(len(r.photos) for r in results), f"; gaps: {', '.join(gaps)}" if gaps else "")
    return written


def build_species(entry: SpeciesEntry, overrides: Overrides, metadata: MetadataSource, detector: Detector, options: BuildOptions) -> SpeciesResult:
    log.info("%s (%s)", entry.common_name, entry.scientific_name)
    candidates = metadata.candidates_for(entry.inat_taxon_id)
    filtered = filter_candidates(candidates)
    rejected = {reason.value: count for reason, count in filtered.rejected.items()}
    log.info("  %d candidates, %d cleared, rejected %s", len(candidates), len(filtered.kept), rejected or "none")

    shortlist = [c for c in filtered.kept if c.photo_id not in overrides.exclude][: options.candidate_limit]
    shortlist += [c for c in filtered.kept if overrides.forces(c.photo_id) and c not in shortlist]
    missing = set(overrides.include) - {c.photo_id for c in filtered.kept}
    if missing:
        log.warning("  override includes %s, not among the cleared candidates", sorted(missing))

    scored: list[ScoredPhoto] = []
    detected = 0
    blurred = 0
    for candidate in shortlist:
        path = options.fetch(candidate, options.cache_dir, "large")
        if path is None:
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
    log.info("  %d with a bird, %d too blurred, %d scored", detected, blurred, len(scored))

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
    return SpeciesResult(entry=entry, photos=photos, gap=gap, candidates=len(candidates), rejected=rejected, detected=detected)


def bird_pixels(candidate: PhotoCandidate, large_size: tuple[int, int], box: Box) -> float:
    """The bird box's longer side in pixels of the original photo (the metadata's dimensions, or twice the `large`
    rendition when they are unknown)."""
    width, height = (candidate.width, candidate.height) if candidate.width and candidate.height else (large_size[0] * 2, large_size[1] * 2)
    return max((box.x1 - box.x0) * width, (box.y1 - box.y0) * height)
