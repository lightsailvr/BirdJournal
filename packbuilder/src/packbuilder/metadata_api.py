"""Candidates from the iNaturalist API (api.inaturalist.org/v1), the default source.

The API describes the same observations, photos and observers as the Open Data dump and serves open-licensed
photos from the Open Data bucket, at a fraction of the download. Responses are cached on disk so a rebuild is
reproducible and offline. The API asks for about one request per second.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from urllib.parse import urlparse

import requests

from packbuilder.candidates import PhotoCandidate

API = "https://api.inaturalist.org/v1/observations"
USER_AGENT = "BirdJournal packbuilder (https://github.com/lightsailvr/BirdJournal)"
PER_PAGE = 200


class APIMetadata:
    def __init__(self, place_id: int, cache_dir: Path, created_before: str | None = None, per_species: int = 200, pause_seconds: float = 1.0):
        """`created_before` (YYYY-MM-DD) pins the newest-first query to observations created up to that date, so a
        rebuild from a clean checkout sees the same candidates as the committed pack (barring deletions)."""
        self.place_id = place_id
        self.created_before = created_before
        self.cache_dir = Path(cache_dir) / "api"
        self.per_species = per_species
        self.pause_seconds = pause_seconds
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def candidates_for(self, taxon_id: int) -> list[PhotoCandidate]:
        candidates: list[PhotoCandidate] = []
        page = 1
        while len(candidates) < self.per_species:
            results = self._page(taxon_id, page)
            if not results:
                break
            for observation in results:
                candidates.extend(_candidates_in(observation))
            if len(results) < PER_PAGE:
                break
            page += 1
        return candidates

    def _page(self, taxon_id: int, page: int) -> list[dict]:
        pin = f"-before-{self.created_before}" if self.created_before else ""
        cache_file = self.cache_dir / f"taxon-{taxon_id}-place-{self.place_id}{pin}-page-{page}.json"
        if cache_file.exists():
            return json.loads(cache_file.read_text())["results"]
        params = {
            "taxon_id": taxon_id,
            "place_id": self.place_id,
            "quality_grade": "research",
            "photo_license": "cc0,cc-by,cc-by-nc",
            "photos": "true",
            # Newest first: the most-faved observations are the oddities (leucistic birds, rare plumages), which
            # make misleading reference cards.
            "order_by": "created_at",
            "order": "desc",
            "per_page": PER_PAGE,
            "page": page,
        }
        if self.created_before:
            params["created_d2"] = self.created_before
        response = requests.get(API, params=params, headers={"User-Agent": USER_AGENT}, timeout=60)
        response.raise_for_status()
        payload = response.json()
        cache_file.write_text(json.dumps(payload))
        time.sleep(self.pause_seconds)
        return payload["results"]


def _candidates_in(observation: dict) -> list[PhotoCandidate]:
    """The photo candidates one API observation describes (its taxon may be a subspecies; the pipeline queried by
    the species' taxon id, so the observation's taxon is recorded as given)."""
    user = observation.get("user") or {}
    taxon = observation.get("taxon") or {}
    out = []
    for position, photo in enumerate(observation.get("photos") or []):
        extension = _extension(photo.get("url"))
        dims = photo.get("original_dimensions") or {}
        out.append(
            PhotoCandidate(
                photo_id=int(photo["id"]),
                extension=extension,
                license=photo.get("license_code"),
                observer_name=user.get("name"),
                observer_login=user.get("login"),
                observation_id=observation.get("id"),
                observation_uuid=observation.get("uuid"),
                taxon_id=int(taxon["id"]) if taxon.get("id") is not None else -1,
                quality_grade=observation.get("quality_grade"),
                width=dims.get("width"),
                height=dims.get("height"),
                position=position,
            )
        )
    return out


def _extension(url: str | None) -> str:
    """The file extension of an Open Data photo URL such as .../photos/123/square.jpeg?1700000000."""
    path = urlparse(url or "").path
    name = path.rsplit("/", 1)[-1]
    return name.rsplit(".", 1)[-1] if "." in name else "jpg"
