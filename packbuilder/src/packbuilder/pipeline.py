"""Runs the whole build for one pack definition (see the package docstring for the steps)."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol

from PIL import Image, ImageOps

from packbuilder.candidates import PhotoCandidate, filter_candidates
from packbuilder.definition import PackDefinition, SpeciesEntry, load_overrides
from packbuilder.detector import BirdDetector
from packbuilder.download import fetch_photo
from packbuilder.scoring import Box, score_crop
from packbuilder.selection import Overrides, ScoredPhoto, select_photos
from packbuilder.writer import SpeciesResult, WrittenPack, write_pack

log = logging.getLogger("packbuilder")

# Birds smaller than this fraction of the frame make a soft 260-pixel crop even from a 2048-pixel original.
MIN_BIRD_AREA = 0.02
# Below this sharpness (see scoring.py) a crop is motion blur or out of focus; area and a dark background would
# otherwise carry it into the top five.
MIN_SHARPNESS = 0.4
# The bird must span at least the lens crop's 260 pixels in the original, or the lens JPEG would be upscaled.
MIN_BIRD_PIXELS = 260


class MetadataSource(Protocol):
    def candidates_for(self, taxon_id: int) -> list[PhotoCandidate]: ...


@dataclass
class BuildOptions:
    cache_dir: Path
    out_dir: Path
    candidate_limit: int = 60
    """How many license-cleared candidates per species are downloaded and run through the detector."""
    minimum: int = 3
    maximum: int = 5
    archive_path: Path | None = None
    built_at: str | None = None


def build_pack(definition: PackDefinition, overrides_path: Path, metadata: MetadataSource, detector: BirdDetector, options: BuildOptions) -> WrittenPack:
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


def build_species(entry: SpeciesEntry, overrides: Overrides, metadata: MetadataSource, detector: BirdDetector, options: BuildOptions) -> SpeciesResult:
    log.info("%s (%s)", entry.common_name, entry.scientific_name)
    candidates = metadata.candidates_for(entry.inat_taxon_id)
    filtered = filter_candidates(candidates)
    log.info("  %d candidates, %d cleared, rejected %s", len(candidates), len(filtered.kept), {k.value: v for k, v in filtered.rejected.items()} or "none")

    to_score = [c for c in filtered.kept if c.photo_id not in overrides.exclude][: options.candidate_limit]
    forced = [c for c in filtered.kept if c.photo_id in overrides.include and c not in to_score]
    missing = set(overrides.include) - {c.photo_id for c in filtered.kept}
    if missing:
        log.warning("  override includes %s, not among the cleared candidates", sorted(missing))

    scored: list[ScoredPhoto] = []
    sources: dict[int, Path] = {}
    detected = 0
    blurred = 0
    for candidate in to_score + forced:
        path = fetch_photo(candidate, options.cache_dir, size="large")
        if path is None:
            continue
        with Image.open(path) as image:
            image = ImageOps.exif_transpose(image) or image
            detections = detector.detect(image)
            box: Box | None = detections[0].box if detections else None
            if box is not None:
                detected += 1
                if candidate.photo_id not in overrides.include and (box.area < MIN_BIRD_AREA or bird_pixels(candidate, image.size, box) < MIN_BIRD_PIXELS):
                    continue
            elif candidate.photo_id in overrides.include:
                box = Box(0.0, 0.0, 1.0, 1.0)  # forced in without a detection: keep the whole frame
            else:
                continue
            score = score_crop(image, box)
            if score.sharpness < MIN_SHARPNESS and candidate.photo_id not in overrides.include:
                blurred += 1
                continue
            scored.append(ScoredPhoto(candidate=candidate, box=box, score=score))
    log.info("  %d with a bird, %d too blurred, %d scored", detected, blurred, len(scored))

    selection = select_photos(scored, overrides, minimum=options.minimum, maximum=options.maximum)
    photos: list[tuple[ScoredPhoto, Path]] = []
    for photo in selection.chosen:
        original = fetch_photo(photo.candidate, options.cache_dir, size="original")
        if original is None:
            log.warning("  original of %s unavailable; skipped", photo.candidate.photo_id)
            continue
        photos.append((photo, original))
    for photo, _ in photos:
        s = photo.score
        log.info("  chose %d  total %.2f (area %.2f, dark %.2f, sharp %.2f)  %s", photo.candidate.photo_id, s.total, s.bird_area, s.background_darkness, s.sharpness, photo.candidate.source_url)
    gap = len(photos) < options.minimum
    if gap:
        log.warning("  GAP: only %d photos for %s", len(photos), entry.common_name)
    return SpeciesResult(entry=entry, photos=photos, gap=gap, candidates=len(candidates), rejected=dict(filtered.rejected), detected=detected)


def bird_pixels(candidate: PhotoCandidate, large_size: tuple[int, int], box: Box) -> float:
    """The bird box's longer side in pixels of the original photo (the metadata's dimensions, or twice the `large`
    rendition when they are unknown)."""
    width, height = (candidate.width, candidate.height) if candidate.width and candidate.height else (large_size[0] * 2, large_size[1] * 2)
    return max((box.x1 - box.x0) * width, (box.y1 - box.y0) * height)
