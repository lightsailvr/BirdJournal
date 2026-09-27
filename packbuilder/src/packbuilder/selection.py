"""Keeps the top three to five crops per species, with a manual override list (spec user story 44)."""

from __future__ import annotations

from dataclasses import dataclass, field

from packbuilder.candidates import PhotoCandidate
from packbuilder.scoring import Box, CropScore


@dataclass(frozen=True)
class ScoredPhoto:
    candidate: PhotoCandidate
    box: Box
    score: CropScore


@dataclass(frozen=True)
class Overrides:
    """`include` photo ids are forced in, first, in the given order; `exclude` ids are never chosen."""

    include: list[int] = field(default_factory=list)
    exclude: list[int] = field(default_factory=list)

    @classmethod
    def from_mapping(cls, data: dict) -> "Overrides":
        return cls(include=[int(i) for i in data.get("include", [])], exclude=[int(i) for i in data.get("exclude", [])])


@dataclass
class Selection:
    chosen: list[ScoredPhoto]
    gap: bool
    """True when fewer than the minimum could be chosen."""


def select_photos(photos: list[ScoredPhoto], overrides: Overrides, minimum: int = 3, maximum: int = 5) -> Selection:
    by_id = {p.candidate.photo_id: p for p in photos}
    chosen: list[ScoredPhoto] = []
    observations: set = set()

    def take(photo: ScoredPhoto) -> None:
        chosen.append(photo)
        observations.add(_observation_key(photo.candidate))

    for photo_id in overrides.include:
        if photo_id in by_id and photo_id not in overrides.exclude and len(chosen) < maximum:
            take(by_id[photo_id])

    ranked = sorted(photos, key=lambda p: -p.score.total)
    for photo in ranked:
        if len(chosen) >= maximum:
            break
        if photo.candidate.photo_id in overrides.exclude or photo in chosen:
            continue
        if _observation_key(photo.candidate) in observations:
            continue  # one photo per observation: the same bird twice is not a second reference
        take(photo)

    return Selection(chosen=chosen, gap=len(chosen) < minimum)


def _observation_key(candidate: PhotoCandidate):
    return candidate.observation_id if candidate.observation_id is not None else candidate.observation_uuid
