"""The pack definition file (`packbuilder/packs/<id>/pack.json`) and the per-species override file beside it."""

from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from packbuilder.sets import SetSection


DEFAULT_PHOTOS_PER_SPECIES = 5
DEFAULT_SOUND_COUNTRIES = ("United States",)


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
    set: SetSection | None = None
    """The set the pack's species make (issue #54): its edition and region boundary; `sets.py` builds it."""
    photos_per_species: int = DEFAULT_PHOTOS_PER_SPECIES
    """Photos a species keeps (`photos_per_species`): five, or three in the 300-species North America pack (#206),
    which would otherwise be far past the size the others keep to. `build --max-photos` overrides it for one build."""
    sound_countries: tuple[str, ...] = DEFAULT_SOUND_COUNTRIES
    """The countries whose xeno-canto recordings are searched, in order, each only when the ones before it have no
    usable song or call (`sound_countries`, or the one `country`): the United States, then Canada, for North America."""

    calibrates_rarity: bool = True
    """Whether the rarity calibration pools this pack's readings (`"rarity_calibration": false` leaves it out). North
    America is left out (#206): its bounding box is a continent, and a calibration that read every one of its birds
    over all of it would move the thresholds saved cards were labelled under."""
    whole: tuple[str, ...] | None = None
    """On a definition cut down by `only`: the ids of every species the pack lists, in its order."""

    def only(self, species_ids: Iterable[str]) -> "PackDefinition":
        """The definition with just these species, in the pack's order, for a build of some of its birds (#215: the
        North America tracer builds ten of the 300). It remembers the whole list, so its sheets keep the pack's
        numbers and its build leaves the other birds' lock entries alone. Raises KeyError for an id the pack lacks."""
        wanted = set(species_ids)
        unknown = wanted - {entry.id for entry in self.species}
        if unknown:
            raise KeyError(f"{self.id} lists no {', '.join(sorted(unknown))}")
        return replace(self, species=[entry for entry in self.species if entry.id in wanted], whole=self.whole or tuple(entry.id for entry in self.species))

    @property
    def partial(self) -> bool:
        """Whether this is some of the pack's birds (`only`)."""
        return self.whole is not None

    @property
    def listed(self) -> int:
        """How many species the pack lists, whatever part of it this is."""
        return len(self.whole) if self.whole is not None else len(self.species)

    def number(self, species_id: str) -> int:
        """A species' number on the contact sheets: its place in the whole pack's `pack.json`, from 1."""
        order = self.whole if self.whole is not None else [entry.id for entry in self.species]
        return order.index(species_id) + 1

    @classmethod
    def load(cls, path: Path) -> "PackDefinition":
        from packbuilder.sets import SetSection

        data = json.loads(path.read_text())
        box = data["bounding_box"]
        return cls(
            set=SetSection.from_mapping(data["set"]) if "set" in data else None,
            id=data["id"],
            name=data["name"],
            region=data["region"],
            version=int(data["version"]),
            place_ids=_place_ids(data),
            bounding_box=BoundingBox(south=box["south"], west=box["west"], north=box["north"], east=box["east"]),
            created_before=data.get("inat_created_before"),
            photos_per_species=int(data.get("photos_per_species", DEFAULT_PHOTOS_PER_SPECIES)),
            sound_countries=_sound_countries(data),
            calibrates_rarity=bool(data.get("rarity_calibration", True)),
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


def wider_places(species: list["SpeciesEntry"], overrides: dict[str, dict]) -> dict[int, tuple[int, ...]]:
    """By taxon id, the iNaturalist places a species borrows photos from beyond the pack's own (`"wider_places": [14]`
    in `overrides.json`, #58), for a species the region has no usable open-licensed photo of."""
    return {
        entry.inat_taxon_id: tuple(int(place) for place in places)
        for entry in species if (places := (overrides.get(entry.scientific_name) or {}).get("wider_places"))
    }


def _sound_countries(data: dict) -> tuple[str, ...]:
    if "sound_countries" in data:
        countries = tuple(str(country) for country in data["sound_countries"])
        if not countries:
            raise ValueError("sound_countries is empty")
        return countries
    return (str(data["country"]),) if "country" in data else DEFAULT_SOUND_COUNTRIES


def _place_ids(data: dict) -> tuple[int, ...]:
    if "inat_place_ids" in data:
        ids = tuple(int(p) for p in data["inat_place_ids"])
        if not ids:
            raise ValueError("inat_place_ids is empty")
        return ids
    return (int(data["inat_place_id"]),)
