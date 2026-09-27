"""Photo candidates as the metadata sources describe them, and the filter that keeps only redistributable ones."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from enum import Enum
from typing import Iterable

from packbuilder.licenses import normalize_license

OPEN_DATA_BUCKET = "https://inaturalist-open-data.s3.amazonaws.com/photos"
OBSERVATION_URL = "https://www.inaturalist.org/observations"


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
    return None


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
