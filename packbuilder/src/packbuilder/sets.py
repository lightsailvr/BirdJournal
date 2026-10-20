"""The set definition (issue #54): what a birder collects toward in one pack's region. Built from the `set` section of
the pack definition by `packbuilder set <definition-dir>` and pinned beside it as `set.json`, which the pack build
writes into the pack and `scripts/publish-pack-index.sh` copies into the index, so sets work before a pack is
downloaded.

- The region boundary is a list of named parts, each a US Census county or an NPS park (both public domain, fetched
  once into the cache) or a hand-drawn GeoJSON polygon committed with the definition where a region is neither (the
  Coachella Valley, Anza-Borrego Desert State Park). Each part is simplified with Douglas–Peucker and its islets
  dropped, so all five sets fit the index. The phone gives a sighting to the smallest part that contains it, which
  is why parts stay separate rather than being merged.
- The species are in the taxonomic order of the IOC World Bird List (CC BY 3.0), the pinned version below; a
  collector number is a species' position in it. BirdNET's names follow eBird/Clements, so the few IOC names that
  differ are mapped in `TAXONOMY_FIXES`, and a build fails on a species the list lacks.
- The edition is the set's name on cards that are not Legendary ("Citrus edition") and the art theme pack art is
  painted in.
"""

from __future__ import annotations

import json
import math
import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import urlencode

from packbuilder.definition import PackDefinition, SpeciesEntry
from packbuilder.download import fetch
from packbuilder.metadata_api import USER_AGENT

IOC_VERSION = "15.1"
IOC_URL = f"https://www.worldbirdnames.org/master_ioc-names_xml.{IOC_VERSION}.xml"
IOC_SHA256 = "d0de18f12cfff1b4eb1a4ab7a8d1154d442ecbaa821f04260759e47e7a2a3fd2"

TAXONOMY_FIXES = {
    # BirdNET+ (eBird/Clements) name: IOC name, for the species of the packs whose names differ.
    "Dryobates borealis": "Leuconotopicus borealis",
    "Dryobates villosus": "Leuconotopicus villosus",
}

CENSUS_COUNTY_URL = "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/State_County/MapServer/1/query"
NPS_BOUNDARY_URL = (
    "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/"
    "NPS_Land_Resources_Division_Boundary_and_Tract_Data_Service/FeatureServer/2/query"
)

HEADERS = {"User-Agent": USER_AGENT}
"""The IOC site refuses requests' default agent."""

DEFAULT_TOLERANCE_KM = 0.5
"""Douglas–Peucker tolerance: a boundary moves by at most half a kilometre, finer than a phone's place name."""
DEFAULT_MIN_AREA_KM2 = 1.0
"""Islets and holes smaller than this are dropped (offshore rocks, enclaves no sighting will fall in)."""

KM_PER_DEGREE_LATITUDE = 110.57
KM_PER_DEGREE_LONGITUDE_AT_EQUATOR = 111.32

Point = list[float]
"""[longitude, latitude], GeoJSON's order."""
Ring = list[Point]
"""Closed: the first point is repeated last."""
Polygon = list[Ring]
"""The outer ring, then any holes."""


class UnmappedSpecies(ValueError):
    pass


@dataclass(frozen=True)
class Edition:
    name: str
    """On cards that are not Legendary, e.g. "Citrus edition"."""
    theme: str
    """What pack art in this set is painted with, e.g. "citrus groves, chaparral and golden valley light"."""

    def as_json(self) -> dict:
        return {"name": self.name, "theme": self.theme}


@dataclass(frozen=True)
class BoundaryPart:
    name: str
    census_county: str | None = None
    """The county's five-digit FIPS code (GEOID), e.g. "06037" for Los Angeles County."""
    nps_park: str | None = None
    """The park's NPS unit code, e.g. "JOTR"."""
    polygon: str | None = None
    """A GeoJSON file beside pack.json holding a hand-drawn Polygon or MultiPolygon."""

    @classmethod
    def from_mapping(cls, data: dict) -> "BoundaryPart":
        part = cls(name=data["name"], census_county=data.get("census_county"), nps_park=data.get("nps_park"), polygon=data.get("polygon"))
        sources = [s for s in (part.census_county, part.nps_park, part.polygon) if s]
        if len(sources) != 1:
            raise ValueError(f"boundary part {part.name!r} needs exactly one of census_county, nps_park or polygon")
        return part

    @property
    def source_text(self) -> str:
        if self.census_county:
            return f"US Census Bureau TIGER county {self.census_county} (public domain)"
        if self.nps_park:
            return f"National Park Service boundary of {self.nps_park} (public domain)"
        return f"hand-drawn polygon committed with the pack definition ({self.polygon})"


@dataclass(frozen=True)
class SetSection:
    """The `set` section of pack.json."""

    edition: Edition
    boundary: tuple[BoundaryPart, ...]

    @classmethod
    def from_mapping(cls, data: dict) -> "SetSection":
        edition = data["edition"]
        parts = tuple(BoundaryPart.from_mapping(part) for part in data["boundary"])
        if not parts:
            raise ValueError("the set's boundary has no parts")
        return cls(edition=Edition(name=edition["name"], theme=edition["theme"]), boundary=parts)


# Geometry


def _projected(ring: Ring, latitude: float) -> list[tuple[float, float]]:
    """Kilometres on a plane touching the earth at `latitude`: plenty for a county."""
    scale = KM_PER_DEGREE_LONGITUDE_AT_EQUATOR * math.cos(math.radians(latitude))
    return [(lon * scale, lat * KM_PER_DEGREE_LATITUDE) for lon, lat in ring]


def _middle_latitude(ring: Ring) -> float:
    latitudes = [lat for _, lat in ring]
    return (min(latitudes) + max(latitudes)) / 2


def _ring_area_km2(ring: Ring, latitude: float) -> float:
    points = _projected(ring, latitude)
    return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(points, points[1:]))) / 2


def polygon_area_km2(polygon: Polygon) -> float:
    """The outer ring's area less the holes'."""
    latitude = _middle_latitude(polygon[0])
    return _ring_area_km2(polygon[0], latitude) - sum(_ring_area_km2(hole, latitude) for hole in polygon[1:])


def _distance_to_segment(point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]) -> float:
    (px, py), (ax, ay), (bx, by) = point, start, end
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0.0 if length == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def simplify_ring(ring: Ring, tolerance_km: float) -> Ring:
    """Douglas–Peucker over the closed ring. A ring that would collapse below a triangle is returned as it was (an
    islet; `simplify_polygons` drops it by area)."""
    if len(ring) < 4:
        return ring
    points = _projected(ring, _middle_latitude(ring))
    keep = [False] * len(ring)
    keep[0] = keep[-1] = True
    stack = [(0, len(ring) - 1)]
    while stack:
        first, last = stack.pop()
        farthest, distance = None, tolerance_km
        for index in range(first + 1, last):
            d = _distance_to_segment(points[index], points[first], points[last])
            if d > distance:
                farthest, distance = index, d
        if farthest is not None:
            keep[farthest] = True
            stack += [(first, farthest), (farthest, last)]
    simplified = [point for point, kept in zip(ring, keep) if kept]
    return simplified if len(simplified) >= 4 else ring


def _rounded(ring: Ring) -> Ring:
    """Four decimals (about 11 m), without the repeated points rounding makes."""
    rounded: Ring = []
    for lon, lat in ring:
        point = [round(lon, 4), round(lat, 4)]
        if not rounded or rounded[-1] != point:
            rounded.append(point)
    return rounded


def simplify_polygons(polygons: list[Polygon], tolerance_km: float = DEFAULT_TOLERANCE_KM, min_area_km2: float = DEFAULT_MIN_AREA_KM2) -> list[Polygon]:
    simplified: list[Polygon] = []
    for polygon in polygons:
        outer = _rounded(simplify_ring(polygon[0], tolerance_km))
        if len(outer) < 4 or polygon_area_km2([outer]) < min_area_km2:
            continue
        latitude = _middle_latitude(outer)
        holes = [_rounded(simplify_ring(hole, tolerance_km)) for hole in polygon[1:]]
        simplified.append([outer] + [hole for hole in holes if len(hole) >= 4 and _ring_area_km2(hole, latitude) >= min_area_km2])
    return simplified


def geojson_polygons(data: dict) -> list[Polygon]:
    """Every polygon in a GeoJSON geometry, Feature or FeatureCollection."""
    kind = data.get("type")
    if kind == "FeatureCollection":
        return [polygon for feature in data["features"] for polygon in geojson_polygons(feature)]
    if kind == "Feature":
        return geojson_polygons(data["geometry"])
    if kind == "Polygon":
        return [data["coordinates"]]
    if kind == "MultiPolygon":
        return list(data["coordinates"])
    raise ValueError(f"not a polygon: {kind}")


# Taxonomy


def taxonomy_title(version: str) -> str:
    return f"IOC World Bird List {version}"


class Taxonomy:
    """The IOC World Bird List's species in its order."""

    def __init__(self, version: str, sequence: dict[str, int], fixes: dict[str, str] | None = None):
        self.version = version
        self.sequence = sequence
        self.fixes = TAXONOMY_FIXES if fixes is None else fixes

    @classmethod
    def parse(cls, xml_text: str, fixes: dict[str, str] | None = None) -> "Taxonomy":
        root = ElementTree.fromstring(xml_text)
        sequence: dict[str, int] = {}
        for genus in root.iter("genus"):
            genus_name = genus.findtext("latin_name")
            for species in genus.findall("species"):
                sequence.setdefault(f"{genus_name} {species.findtext('latin_name')}", len(sequence))
        return cls(version=root.get("version", "?"), sequence=sequence, fixes=fixes)

    @classmethod
    def load(cls, cache_dir: Path) -> "Taxonomy":
        """The pinned IOC list, fetched into the cache once and checked against its digest."""
        path = fetch(IOC_URL, Path(cache_dir) / "taxonomy" / f"master_ioc-names_xml.{IOC_VERSION}.xml", sha256=IOC_SHA256, headers=HEADERS)
        return cls.parse(path.read_text(encoding="utf-8"))

    @property
    def title(self) -> str:
        return taxonomy_title(self.version)

    def ordered(self, species: list[SpeciesEntry]) -> list[SpeciesEntry]:
        names = {entry.scientific_name: self.fixes.get(entry.scientific_name, entry.scientific_name) for entry in species}
        missing = sorted(name for name, ioc in names.items() if ioc not in self.sequence)
        if missing:
            raise UnmappedSpecies(f"not in the {self.title} (add a TAXONOMY_FIXES entry): {', '.join(missing)}")
        return sorted(species, key=lambda entry: self.sequence[names[entry.scientific_name]])


# Boundaries


class BoundarySource(Protocol):
    def polygons_for(self, part: BoundaryPart, definition_dir: Path) -> list[Polygon]: ...


class PublicBoundaries:
    """Census counties and NPS parks from their public ArcGIS services, cached as GeoJSON; hand-drawn polygons from
    the definition folder."""

    def __init__(self, cache_dir: Path):
        self.directory = Path(cache_dir) / "boundaries"

    def polygons_for(self, part: BoundaryPart, definition_dir: Path) -> list[Polygon]:
        if part.polygon:
            return geojson_polygons(json.loads((Path(definition_dir) / part.polygon).read_text()))
        if part.census_county:
            query = {"where": f"GEOID='{part.census_county}'", "outFields": "GEOID,NAME", "outSR": 4326, "f": "geojson"}
            path = fetch(f"{CENSUS_COUNTY_URL}?{urlencode(query)}", self.directory / f"census-county-{part.census_county}.geojson", headers=HEADERS)
        else:
            query = {"where": f"UNIT_CODE='{part.nps_park}'", "outFields": "UNIT_CODE,UNIT_NAME", "outSR": 4326, "f": "geojson"}
            path = fetch(f"{NPS_BOUNDARY_URL}?{urlencode(query)}", self.directory / f"nps-{part.nps_park}.geojson", headers=HEADERS)
        polygons = geojson_polygons(json.loads(path.read_text()))
        if not polygons:
            path.unlink()
            raise ValueError(f"no boundary for {part.name} ({part.source_text})")
        return polygons


# The set document


def build_set(
    definition: PackDefinition, definition_dir: Path, boundaries: BoundarySource, taxonomy: Taxonomy,
    tolerance_km: float = DEFAULT_TOLERANCE_KM, min_area_km2: float = DEFAULT_MIN_AREA_KM2,
) -> dict:
    """The set as the index and the pack carry it (camelCase keys, like the rest of the index)."""
    if definition.set is None:
        raise ValueError(f"{definition.id}: pack.json has no set section")
    regions = []
    for part in definition.set.boundary:
        polygons = simplify_polygons(boundaries.polygons_for(part, definition_dir), tolerance_km, min_area_km2)
        if not polygons:
            raise ValueError(f"{part.name}: nothing left of the boundary after simplification")
        regions.append({"name": part.name, "source": part.source_text, "polygons": polygons})
    return {
        "id": definition.id,
        "name": definition.name,
        "edition": definition.set.edition.as_json(),
        "taxonomy": taxonomy.title,
        "regions": regions,
        "species": [{"scientificName": s.scientific_name, "commonName": s.common_name} for s in taxonomy.ordered(definition.species)],
    }


def check_set(document: dict, definition: PackDefinition) -> None:
    """Refuses a pinned set that no longer matches its definition (other species, names, edition or boundary parts)
    or the pinned taxonomy (another IOC version would renumber the set)."""
    problems = []
    if document.get("id") != definition.id or document.get("name") != definition.name:
        problems.append("the pack id or name changed")
    if document.get("taxonomy") != taxonomy_title(IOC_VERSION):
        problems.append(f"the taxonomy is not the pinned {taxonomy_title(IOC_VERSION)}")
    if definition.set is None:
        problems.append("pack.json has no set section")
    else:
        if document.get("edition") != definition.set.edition.as_json():
            problems.append("the edition changed")
        if [(r["name"], r["source"]) for r in document.get("regions", [])] != [(p.name, p.source_text) for p in definition.set.boundary]:
            problems.append("the boundary parts changed")
    species = {(s["scientificName"], s["commonName"]) for s in document.get("species", [])}
    if species != {(s.scientific_name, s.common_name) for s in definition.species} or len(species) != len(document.get("species", [])):
        problems.append("the species changed")
    if problems:
        raise ValueError(f"{definition.id}: set.json is out of date ({'; '.join(problems)}): rebuild it with `packbuilder set packs/{definition.id}`")


def load_set(path: Path) -> dict:
    if not Path(path).exists():
        raise FileNotFoundError(f"no {path}: build it with `packbuilder set {Path(path).parent}`")
    return json.loads(Path(path).read_text(encoding="utf-8"))


def dump_set(document: dict) -> str:
    """Pretty enough to review: one species per line and one ring per line, rather than one number per line."""
    head = [f"  {json.dumps(key)}: {json.dumps(document[key], ensure_ascii=False)}" for key in ("id", "name", "edition", "taxonomy")]
    regions = []
    for region in document["regions"]:
        polygons = ",\n".join(
            "      [\n" + ",\n".join(f"        {json.dumps(ring, separators=(',', ':'))}" for ring in polygon) + "\n      ]" for polygon in region["polygons"]
        )
        regions.append(f'    {{"name": {json.dumps(region["name"], ensure_ascii=False)}, "source": {json.dumps(region["source"], ensure_ascii=False)}, "polygons": [\n{polygons}\n    ]}}')
    species = ",\n".join(f"    {json.dumps(s, ensure_ascii=False)}" for s in document["species"])
    return "{\n" + ",\n".join(head) + ',\n  "regions": [\n' + ",\n".join(regions) + '\n  ],\n  "species": [\n' + species + "\n  ]\n}\n"
