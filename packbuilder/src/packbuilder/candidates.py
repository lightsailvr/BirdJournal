"""Photo candidates as the metadata sources describe them, and the filter that keeps only redistributable ones."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable

from packbuilder.licenses import normalize_license

OPEN_DATA_BUCKET = "https://inaturalist-open-data.s3.amazonaws.com/photos"
OBSERVATION_URL = "https://www.inaturalist.org/observations"

# iNaturalist's controlled annotations (GET /v1/controlled_terms): "Alive or Dead" (17) and "Evidence of Presence"
# (22), whose only value that shows the bird itself is Organism (24); Feather, Bone, Track, Molt and Egg are not a card.
ALIVE_OR_DEAD, DEAD = 17, 19
EVIDENCE_OF_PRESENCE, ORGANISM = 22, 24


@dataclass(frozen=True)
class PhotoCandidate:
    photo_id: int
    extension: str
    license: str | None
    observer_name: str | None
    observer_login: str | None
    observation_id: int | None
    observation_uuid: str | None
    taxon_id: int
    quality_grade: str | None
    width: int | None = None
    height: int | None = None
    position: int | None = None
    annotations: tuple[tuple[int, int], ...] = ()
    """The observation's (controlled attribute, controlled value) pairs; the Open Data dump carries none."""

    def photo_url(self, size: str = "original") -> str:
        return f"{OPEN_DATA_BUCKET}/{self.photo_id}/{size}.{self.extension}"

    @property
    def source_url(self) -> str | None:
        """The observation page; iNaturalist resolves both the numeric id and the UUID."""
        if self.observation_id is not None:
            return f"{OBSERVATION_URL}/{self.observation_id}"
        if self.observation_uuid:
            return f"{OBSERVATION_URL}/{self.observation_uuid}"
        return None

    @property
    def normalized_license(self) -> str | None:
        return normalize_license(self.license)


class Rejection(str, Enum):
    LICENSE = "license"
    QUALITY = "quality"
    ATTRIBUTION = "attribution"
    NOT_A_LIVE_BIRD = "not_a_live_bird"


def attribution_name(candidate: PhotoCandidate) -> str | None:
    """The observer's name, or their login when the name is blank (the Open Data README's attribution rule)."""
    for value in (candidate.observer_name, candidate.observer_login):
        if value and value.strip():
            return value.strip()
    return None


def rejection_reason(candidate: PhotoCandidate) -> Rejection | None:
    if candidate.normalized_license is None:
        return Rejection.LICENSE
    if candidate.quality_grade != "research":
        return Rejection.QUALITY
    if attribution_name(candidate) is None or candidate.source_url is None:
        return Rejection.ATTRIBUTION
    if not shows_a_live_bird(candidate):
        return Rejection.NOT_A_LIVE_BIRD
    return None


def shows_a_live_bird(candidate: PhotoCandidate) -> bool:
    """False when the observer or the community annotated the observation as a dead bird or as evidence other than the
    bird itself (a feather, a track). Most observations carry no annotation, so this catches only part of them; the
    override file handles the rest (issue #37: beached murres, road-killed owls, a feather in a hand)."""
    for attribute, value in candidate.annotations:
        if attribute == ALIVE_OR_DEAD and value == DEAD:
            return False
        if attribute == EVIDENCE_OF_PRESENCE and value != ORGANISM:
            return False
    return True


@dataclass
class FilterResult:
    kept: list[PhotoCandidate] = field(default_factory=list)
    rejected: Counter = field(default_factory=Counter)


def filter_candidates(candidates: Iterable[PhotoCandidate]) -> FilterResult:
    result = FilterResult()
    for candidate in candidates:
        reason = rejection_reason(candidate)
        if reason is None:
            result.kept.append(candidate)
        else:
            result.rejected[reason] += 1
    return result
