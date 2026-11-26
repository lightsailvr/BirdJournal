"""A set bounded by countries (issue #210): the North America set's boundary is the United States and Canada.

- The source is Natural Earth's 1:10m "Admin 0 – Countries" (public domain: "All versions of Natural Earth raster +
  vector map data found on this website are in the public domain", naturalearthdata.com/about/terms-of-use), the
  pinned version below, fetched once into the cache. A country is named by the file's `ADM0_A3` code. Natural Earth
  draws dependencies as units of their own (Puerto Rico is PRI, Guam GUM, the US Virgin Islands VIR), so USA is the
  50 states and DC.
- Its "Minor Islands" file adds the islets the countries file leaves out. It names no country, so an islet goes to
  the country whose land is nearest.
- The countries of a part are merged, pushed offshore and simplified far more coarsely than a county, so a sighting
  from a pier or a boat counts and the outline stays small in the index, the app and every placement call. The
  tolerance is less than the push, so the simplified line never comes back onto the countries' own land.
- A neighbour's land is taken out again, so the push goes out to sea and not across a land border. The border keeps a
  narrow margin on the neighbour's side and its own finer tolerance, for the same reason: no place in the named
  countries falls outside (Santa Ana NWR is on the Rio Grande).
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy
import shapely
from shapely import affinity
from shapely.geometry import Polygon as Shape
from shapely.geometry.base import BaseGeometry

from packbuilder.download import fetch

NATURAL_EARTH_VERSION = "5.1.2"
NATURAL_EARTH_URL = f"https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v{NATURAL_EARTH_VERSION}/geojson/ne_10m_admin_0_countries.geojson"
"""Natural Earth's own repository, at the release's tag."""
NATURAL_EARTH_SHA256 = "239eec57ac17f100a11e2536cffc56752c318b50ae765b0918ff7aab4ce8f255"
MINOR_ISLANDS_URL = f"https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v{NATURAL_EARTH_VERSION}/geojson/ne_10m_minor_islands.geojson"
MINOR_ISLANDS_SHA256 = "8c933ca7a4760256bdc46408355706e39764b0fa01c160c28888b90b4faec29f"

OFFSHORE_KM = 15.0
"""How far the outline is pushed out to sea."""
COAST_TOLERANCE_KM = 10.0
"""The pushed outline's simplification tolerance. Less than `OFFSHORE_KM`, so the line stays off the land: between 4
and 25 km from the coast as measured on the built outline (5 less what the plane's scale takes at a continent's far
ends)."""
BORDER_MARGIN_KM = 2.0
"""How much of a neighbour's land along a land border stays inside."""
BORDER_TOLERANCE_KM = 1.0
"""The land border's simplification tolerance. Less than `BORDER_MARGIN_KM`, so the border never cuts into the named
countries; at most 3 km of the neighbour is inside."""
ISLET_REACH_KM = 200.0
"""An islet Natural Earth draws without a country goes to the country whose land is nearest, if that is no farther
than this: the Dry Tortugas are 70 km past the last of the Florida Keys it draws."""
DECIMALS = 3
"""About 110 m, plenty beside the tolerances."""

EARTH_RADIUS_KM = 6371.0088

Polygon = list[list[list[float]]]
"""The outer ring, then any holes; each ring closed, of [longitude, latitude]."""


@dataclass(frozen=True)
class Land:
    """Natural Earth's land: every unit's polygons by its `ADM0_A3` code, and the islets of a few square kilometres
    or less it draws in a file of their own without saying whose they are (Monhegan, the Dry Tortugas, the
    Farallones)."""

    by_code: dict[str, list[Polygon]]
    islets: list[Polygon] = field(default_factory=list)


def source_text(codes: tuple[str, ...]) -> str:
    """What the set definition and the pack's LICENSE say of a country part. It names the push and the tolerance, so
    a set built with other values no longer matches its definition."""
    return (
        f"Natural Earth {NATURAL_EARTH_VERSION} 1:10m countries {', '.join(codes)}, pushed {OFFSHORE_KM:g} km offshore "
        f"and simplified to {COAST_TOLERANCE_KM:g} km (public domain)"
    )


def land_by_code(data: dict) -> dict[str, list[Polygon]]:
    """Each unit's polygons by its `ADM0_A3` code, from the Natural Earth countries file."""
    land: dict[str, list[Polygon]] = {}
    for feature in data["features"]:
        land.setdefault(feature["properties"]["ADM0_A3"], []).extend(_feature_polygons(feature))
    return land


def _feature_polygons(feature: dict) -> list[Polygon]:
    geometry = feature["geometry"]
    return [geometry["coordinates"]] if geometry["type"] == "Polygon" else list(geometry["coordinates"])


def cached_files(directory: Path) -> tuple[Path, Path]:
    """Where the countries and the minor islands are kept in the cache's boundaries folder."""
    stem = f"natural-earth-{NATURAL_EARTH_VERSION}-10m"
    return Path(directory) / f"{stem}-admin-0-countries.geojson", Path(directory) / f"{stem}-minor-islands.geojson"


def load(directory: Path) -> Land:
    """The pinned Natural Earth countries and minor islands, fetched into the cache's boundaries folder once and
    checked against their digests."""
    countries, islands = cached_files(directory)
    countries = fetch(NATURAL_EARTH_URL, countries, sha256=NATURAL_EARTH_SHA256)
    islands = fetch(MINOR_ISLANDS_URL, islands, sha256=MINOR_ISLANDS_SHA256)
    islets = [polygon for feature in json.loads(islands.read_text(encoding="utf-8"))["features"] for polygon in _feature_polygons(feature)]
    return Land(by_code=land_by_code(json.loads(countries.read_text(encoding="utf-8"))), islets=islets)


def outline(
    land: list[Polygon], foreign: list[Polygon], islets: list[Polygon] = (), offshore_km: float = OFFSHORE_KM,
    tolerance_km: float = COAST_TOLERANCE_KM, border_margin_km: float = BORDER_MARGIN_KM, border_tolerance_km: float = BORDER_TOLERANCE_KM,
    islet_reach_km: float = ISLET_REACH_KM,
) -> list[Polygon]:
    """`land`, with the `islets` nearer to it than to `foreign` land, merged, pushed `offshore_km` out to sea and
    simplified, less the `foreign` land it would cover. Sea the push encloses is filled; nothing crosses the
    antimeridian (a piece that would is cut in two at 180°)."""
    own, abroad = [_shape(polygon) for polygon in land], [_shape(polygon) for polygon in foreign]
    own += _claimed([_shape(polygon) for polygon in islets], own, abroad, islet_reach_km)
    pushed = [_locally(shape, lambda flat: flat.buffer(offshore_km)) for shape in own]
    filled = [Shape(piece.exterior) for piece in _polygons(_wrapped(shapely.union_all(pushed)))]
    coast = shapely.union_all([_locally(piece, lambda flat: _simplified(flat, tolerance_km)) for piece in filled])

    neighbours = shapely.union_all([shape for shape in abroad if shape.intersects(coast)])
    if not neighbours.is_empty:
        # Only the land a neighbour is within reach of needs the margin drawn round it.
        margin = _wrapped(shapely.union_all([
            _locally(shape, lambda flat: flat.buffer(border_margin_km)) for shape, reach in zip(own, pushed) if reach.intersects(neighbours)
        ]))
        beyond = _polygons(neighbours.difference(margin))
        coast = coast.difference(shapely.union_all([_locally(piece, lambda flat: _simplified(flat, border_tolerance_km)) for piece in beyond]))
    return [[[list(point) for point in ring.coords] for ring in (piece.exterior, *piece.interiors)] for piece in _polygons(coast)]


def _claimed(islets: list[BaseGeometry], own: list[BaseGeometry], abroad: list[BaseGeometry], reach_km: float) -> list[BaseGeometry]:
    """The islets whose nearest land is `own` and within reach. Land is looked for in a box of the reach round each
    islet, in plain longitudes, so not across the antimeridian."""
    if not islets or not own:
        return []
    ours, theirs = shapely.STRtree(own), shapely.STRtree(abroad)
    claimed = []
    for islet in islets:
        west, south, east, north = islet.bounds
        longitude, latitude = (west + east) / 2, (south + north) / 2
        across = min(180.0, reach_km / (111.32 * max(math.cos(math.radians(latitude)), 0.01)))
        window = (longitude - across, latitude - reach_km / 110.57, longitude + across, latitude + reach_km / 110.57)
        forward, _ = _plane(longitude, latitude)
        flat = shapely.transform(islet, forward)

        def distance(tree: shapely.STRtree, shapes: list[BaseGeometry]) -> float:
            near = (shapely.clip_by_rect(shapes[index], *window) for index in tree.query(shapely.box(*window)))
            return min((flat.distance(shapely.transform(piece, forward)) for piece in near if not piece.is_empty), default=math.inf)

        home = distance(ours, own)
        if home <= reach_km and home <= distance(theirs, abroad):
            claimed.append(islet)
    return claimed


def _shape(polygon: Polygon) -> BaseGeometry:
    return shapely.make_valid(Shape(polygon[0], polygon[1:]))


def _polygons(geometry: BaseGeometry) -> list[Shape]:
    """The polygons of whatever a union or a difference returned."""
    if geometry.is_empty:
        return []
    if isinstance(geometry, Shape):
        return [geometry]
    return [polygon for part in getattr(geometry, "geoms", ()) for polygon in _polygons(part)]


def _simplified(flat: BaseGeometry, tolerance: float) -> BaseGeometry:
    """Douglas–Peucker over each ring of a polygon on the plane, and strictly: no stretch of a ring moves farther than
    `tolerance`, which the promise that the line stays off the land rests on. (GEOS's simplifier also drops a ring's
    first point and then moves the line up to a quarter farther.) Two stretches that cross once simplified are sorted
    out as the phone reads them, by the even-odd rule."""
    shapes = []
    for polygon in _polygons(flat):
        outer, *holes = (_simplified_ring(numpy.asarray(ring.coords), tolerance) for ring in (polygon.exterior, *polygon.interiors))
        shapes.append(shapely.make_valid(Shape(outer, holes)))
    return shapely.union_all(shapes)


def _simplified_ring(points: numpy.ndarray, tolerance: float) -> numpy.ndarray:
    """A ring that would collapse below a triangle is returned as it was."""
    keep = numpy.zeros(len(points), dtype=bool)
    keep[[0, -1]] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        if last - first < 2:
            continue
        between, start, span = points[first + 1:last], points[first], points[last] - points[first]
        length = float(span @ span)
        along = numpy.clip((between - start) @ span / length, 0, 1) if length else numpy.zeros(len(between))
        distance = numpy.hypot(*(between - (start + along[:, None] * span)).T)
        farthest = int(distance.argmax())
        if distance[farthest] > tolerance:
            keep[first + 1 + farthest] = True
            stack += [(first, first + 1 + farthest), (first + 1 + farthest, last)]
    return points[keep] if keep.sum() >= 4 else points


def _locally(geometry: BaseGeometry, operation: Callable[[BaseGeometry], BaseGeometry]) -> BaseGeometry:
    """`operation` in kilometres, on a stereographic plane touching the earth at the middle of `geometry`: distances
    there are true at the middle and at most a tenth too long at the far ends of a continent, so a push or a tolerance
    is never more on the ground than asked for. Longitudes come back unwrapped (past ±180° near the antimeridian)."""
    west, south, east, north = geometry.bounds
    forward, inverse = _plane((west + east) / 2, (south + north) / 2)
    # Made valid again: a ring that only touches itself on the plane can cross itself by a hair once back on the globe.
    return shapely.make_valid(shapely.transform(operation(shapely.transform(geometry, forward)), inverse))


def _plane(middle_longitude: float, middle_latitude: float) -> tuple[Callable[[numpy.ndarray], numpy.ndarray], Callable[[numpy.ndarray], numpy.ndarray]]:
    """To kilometres on the stereographic plane touching the earth at the given place, and back."""
    longitude, latitude = math.radians(middle_longitude), math.radians(middle_latitude)

    def forward(points: numpy.ndarray) -> numpy.ndarray:
        lon, lat = numpy.radians(points[:, 0]), numpy.radians(points[:, 1])
        turn = (lon - longitude + math.pi) % (2 * math.pi) - math.pi
        scale = 2 * EARTH_RADIUS_KM / (1 + math.sin(latitude) * numpy.sin(lat) + math.cos(latitude) * numpy.cos(lat) * numpy.cos(turn))
        return numpy.column_stack([
            scale * numpy.cos(lat) * numpy.sin(turn),
            scale * (math.cos(latitude) * numpy.sin(lat) - math.sin(latitude) * numpy.cos(lat) * numpy.cos(turn)),
        ])

    def inverse(points: numpy.ndarray) -> numpy.ndarray:
        x, y = points[:, 0], points[:, 1]
        distance = numpy.hypot(x, y)
        angle = 2 * numpy.arctan2(distance, 2 * EARTH_RADIUS_KM)
        safe = numpy.where(distance == 0, 1.0, distance)
        lat = numpy.arcsin(numpy.clip(numpy.cos(angle) * math.sin(latitude) + y * numpy.sin(angle) * math.cos(latitude) / safe, -1, 1))
        turn = numpy.arctan2(x * numpy.sin(angle), safe * math.cos(latitude) * numpy.cos(angle) - y * math.sin(latitude) * numpy.sin(angle))
        return numpy.column_stack([numpy.degrees(longitude + turn), numpy.degrees(lat)])

    return forward, inverse


def _wrapped(geometry: BaseGeometry) -> BaseGeometry:
    """What lies past ±180° brought round to the other side, so the phone's plain longitude test holds."""
    pieces = []
    for shift in (-360, 0, 360):
        piece = geometry.intersection(shapely.box(-180 - shift, -90, 180 - shift, 90))
        if not piece.is_empty:
            pieces.append(affinity.translate(piece, xoff=shift))
    return shapely.union_all(pieces)
