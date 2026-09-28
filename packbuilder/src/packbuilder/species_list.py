"""`packbuilder draft`: a first species list for a new pack, from iNaturalist's research-grade observation counts.

The Los Angeles list (issue #12) was made by hand from `observations/species_counts`; this does the same for any set of
places: the `top` most-observed species, optionally the most-observed of some months (a pack for a trip in October
wants the wintering ducks and the migrants that a year-round ranking buries), then species named by hand (the ones
heard far more than seen). Every species is keyed and named by the BirdNET+ label file, so the engine, the lens and the
phone agree; a taxon the label file does not name is listed as unresolved for a person to map or drop, never guessed.
The output is the `species` array of a `pack.json`, in rank order; the ranking is printed to stderr.
"""

from __future__ import annotations

import csv
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from packbuilder.http import session
from packbuilder.metadata_api import USER_AGENT

SPECIES_COUNTS = "https://api.inaturalist.org/v1/observations/species_counts"
TAXA = "https://api.inaturalist.org/v1/taxa"
BIRDS = 3


@dataclass(frozen=True)
class Ranked:
    taxon_id: int
    name: str
    common_name: str | None
    wikipedia_url: str | None
    count: int
    rank: str


class SpeciesCounts:
    """Research-grade bird species counts for a set of places, cached on disk like the build's API pages."""

    def __init__(self, place_ids: tuple[int, ...], cache_dir: Path, created_before: str, pause_seconds: float = 1.0):
        self.place_ids = tuple(place_ids)
        self.created_before = created_before
        self.cache_dir = Path(cache_dir) / "api"
        self.pause_seconds = pause_seconds
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def ranking(self, months: tuple[int, ...] = (), limit: int = 500) -> list[Ranked]:
        places = "-".join(map(str, self.place_ids))
        season = f"-months-{'-'.join(map(str, months))}" if months else ""
        cache_file = self.cache_dir / f"species-counts-place-{places}{season}-before-{self.created_before}.json"
        if cache_file.exists():
            results = json.loads(cache_file.read_text())
        else:
            params = {
                "place_id": ",".join(map(str, self.place_ids)),
                "taxon_id": BIRDS,
                "quality_grade": "research",
                "created_d2": self.created_before,
                "per_page": limit,
            }
            if months:
                params["month"] = ",".join(map(str, months))
            response = session().get(SPECIES_COUNTS, params=params, headers={"User-Agent": USER_AGENT}, timeout=60)
            response.raise_for_status()
            results = response.json()["results"]
            cache_file.write_text(json.dumps(results))
            time.sleep(self.pause_seconds)
        return [_ranked(r) for r in results]

    def taxon(self, scientific_name: str) -> Ranked:
        """A species named by hand, looked up by its exact name (count 0: it is not from the ranking)."""
        cache_file = self.cache_dir / f"taxon-name-{scientific_name.replace(' ', '_')}.json"
        if cache_file.exists():
            results = json.loads(cache_file.read_text())
        else:
            params = {"q": scientific_name, "rank": "species", "is_active": "true", "per_page": 10}
            response = session().get(TAXA, params=params, headers={"User-Agent": USER_AGENT}, timeout=60)
            response.raise_for_status()
            results = response.json()["results"]
            cache_file.write_text(json.dumps(results))
            time.sleep(self.pause_seconds)
        for taxon in results:
            if taxon.get("name") == scientific_name:
                return _ranked({"count": 0, "taxon": taxon})
        raise LookupError(f"no active iNaturalist species named {scientific_name!r}")


def _ranked(result: dict) -> Ranked:
    taxon = result["taxon"]
    return Ranked(
        taxon_id=int(taxon["id"]), name=taxon["name"], common_name=taxon.get("preferred_common_name"),
        wikipedia_url=taxon.get("wikipedia_url"), count=int(result.get("count", 0)), rank=taxon.get("rank", ""),
    )


def birdnet_labels(path: Path) -> dict[str, str]:
    """Scientific name → common name, as the BirdNET+ label file spells them."""
    with path.open(encoding="utf-8-sig") as handle:
        return {row["sci_name"]: row["com_name"] for row in csv.DictReader(handle, delimiter=";")}


def known_entries(pack_dirs: list[Path]) -> dict[int, dict]:
    """iNaturalist taxon id → the species entry of a committed pack: a new pack reuses it whole, keeping the mappings
    a person already made where iNaturalist and BirdNET disagree (iNaturalist's Vireo swainsoni is BirdNET's Vireo
    gilvus) and the Wikipedia article that pack was checked against."""
    known: dict[int, dict] = {}
    for pack_dir in pack_dirs:
        path = pack_dir / "pack.json"
        if path.exists():
            for s in json.loads(path.read_text())["species"]:
                known.setdefault(int(s["inat_taxon_id"]), s)
    return known


@dataclass
class Draft:
    species: list[dict]
    unresolved: list[Ranked]
    skipped: list[tuple[Ranked, str]]
    renamed: list[tuple[Ranked, str]]
    """Taxa taken under a different binomial by their common name, for a person to check."""


def draft(
    counts: SpeciesCounts, labels: dict[str, str], known: dict[int, dict], top: int,
    season_months: tuple[int, ...] = (), season_top: int = 0, add: list[str] = (), exclude: set[str] = frozenset(),
) -> Draft:
    """The top `top` species of the year, then the top `season_top` of `season_months` not already in, then `add`.
    A non-species taxon (a hybrid, a genus) or an excluded name is skipped and does not use up a place in the top."""
    result = Draft(species=[], unresolved=[], skipped=[], renamed=[])
    names: set[str] = set()

    def take(ranked: Ranked) -> str | None:
        """The species' BirdNET name when it belongs in the pack (added now or already in), else None."""
        if ranked.rank != "species":
            result.skipped.append((ranked, f"rank {ranked.rank}"))
            return None
        entry = known.get(ranked.taxon_id)
        name = entry["scientific_name"] if entry else (ranked.name if ranked.name in labels else None)
        if name is None and ranked.common_name:
            # The same bird under another binomial: the label file's common name is a second key, checked by a person.
            by_common = [sci for sci, com in labels.items() if com.lower() == ranked.common_name.lower()]
            if len(by_common) == 1:
                name = by_common[0]
                result.renamed.append((ranked, name))
        if ranked.name in exclude or (name and name in exclude):
            result.skipped.append((ranked, "excluded"))
            return None
        if name is None:
            result.unresolved.append(ranked)
            return None
        if name in names:
            return name
        names.add(name)
        wikipedia_url = (ranked.wikipedia_url or wikipedia_guess(labels[name])).replace("http://", "https://", 1)
        result.species.append(dict(entry) if entry else {
            "scientific_name": name,
            "common_name": labels[name],
            "inat_taxon_id": ranked.taxon_id,
            "wikipedia_url": wikipedia_url,
        })
        return name

    def take_top(ranking: list[Ranked], n: int) -> None:
        # Skipped and unresolved taxa do not use up a place; a species already in does ("the season's top 100" means
        # those 100 are in the pack).
        taken = 0
        for ranked in ranking:
            if taken >= n:
                break
            if take(ranked) is not None:
                taken += 1

    take_top(counts.ranking(), top)
    if season_months and season_top:
        take_top(counts.ranking(season_months), season_top)
    for scientific_name in add:
        if take(counts.taxon(scientific_name)) is None:
            print(f"added species {scientific_name} is not a BirdNET label or is excluded", file=sys.stderr)
    return result


def wikipedia_guess(common_name: str) -> str:
    """English Wikipedia titles birds in sentence case ("Red-tailed hawk"); the build refuses an article whose lead
    names neither the binomial nor the common name, so a wrong guess is logged, not used."""
    title = common_name[:1].upper() + common_name[1:].lower()
    return "https://en.wikipedia.org/wiki/" + title.replace(" ", "_")
