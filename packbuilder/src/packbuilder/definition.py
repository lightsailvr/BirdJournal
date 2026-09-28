"""The pack definition file (`packbuilder/packs/<id>/pack.json`) and the per-species override file beside it."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BoundingBox:
    south: float
    west: float
    north: float
    east: float


@dataclass(frozen=True)
class SpeciesEntry:
    scientific_name: str
    common_name: str
    birdnet_label: str
    inat_taxon_id: int
    wikipedia_url: str | None = None

    @property
    def id(self) -> str:
        return self.scientific_name.lower().replace(" ", "-")


@dataclass(frozen=True)
class PackDefinition:
    id: str
    name: str
    region: str
    version: int
    place_ids: tuple[int, ...]
    """iNaturalist places the photos come from: `inat_place_id` (one place) or `inat_place_ids` (a region several
    places make up, such as the counties around Orlando)."""
    bounding_box: BoundingBox
    species: list[SpeciesEntry]
    created_before: str | None = None
    """Observations created after this date (YYYY-MM-DD) are ignored, so rebuilds see the same candidates."""

    @classmethod
    def load(cls, path: Path) -> "PackDefinition":
        data = json.loads(path.read_text())
        box = data["bounding_box"]
        return cls(
            id=data["id"],
            name=data["name"],
            region=data["region"],
            version=int(data["version"]),
            place_ids=_place_ids(data),
            bounding_box=BoundingBox(south=box["south"], west=box["west"], north=box["north"], east=box["east"]),
            created_before=data.get("inat_created_before"),
            species=[
                SpeciesEntry(
                    scientific_name=s["scientific_name"],
                    common_name=s["common_name"],
                    birdnet_label=s.get("birdnet_label", s["scientific_name"]),
                    inat_taxon_id=int(s["inat_taxon_id"]),
                    wikipedia_url=s.get("wikipedia_url"),
                )
                for s in data["species"]
            ],
        )


def load_overrides(path: Path) -> dict[str, dict]:
    """Raw override mapping keyed by scientific name; missing file means no overrides."""
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def _place_ids(data: dict) -> tuple[int, ...]:
    if "inat_place_ids" in data:
        ids = tuple(int(p) for p in data["inat_place_ids"])
        if not ids:
            raise ValueError("inat_place_ids is empty")
        return ids
    return (int(data["inat_place_id"]),)
