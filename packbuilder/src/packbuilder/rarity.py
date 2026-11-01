"""The rarity calibration (ADR-0006, issue #52): where the geomodel's occurrence probability splits into Common,
Uncommon, Rare and Exceptional.

The geomodel is read for every species of every pack definition, at a grid of points over the pack's bounding box and
all 48 of BirdNET's weeks. Identification never admits a species below the 0.03 floor when it knows the place, so
only readings at or above it count. The thresholds are percentiles of those readings: the rarest 5 % are Exceptional,
the next 15 % Rare, the next 30 % Uncommon and the upper half Common (below the floor is Exceptional too). The result
is committed as `RarityCalibration.json` in the Identification module; a new calibration takes the next version, and
saved cards keep the version they were labelled under.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass

import numpy as np

from packbuilder.definition import BoundingBox

FLOOR = 0.03
"""The identification floor (`IdentificationConfiguration.occurrenceThreshold`)."""

GRID_SIZE = 6
"""Points per side of the grid over each pack's bounding box."""

WEEKS = range(1, 49)

PERCENTILES = {"rare": 5, "uncommon": 20, "common": 50}
"""Each label's lower bound, as a percentile of the readings above the floor. Below `rare` is Exceptional."""


@dataclass(frozen=True)
class Region:
    """One pack's bounding box and its species' scientific names."""

    bounding_box: BoundingBox
    species: Sequence[str]


def grid(box: BoundingBox, size: int) -> list[tuple[float, float]]:
    """`size` × `size` (latitude, longitude) points from the box's south-west corner to its north-east one."""
    latitudes = np.linspace(box.south, box.north, size)
    longitudes = np.linspace(box.west, box.east, size)
    return [(float(lat), float(lon)) for lat in latitudes for lon in longitudes]


def readings(
    occurrence: Callable[[np.ndarray], np.ndarray], labels: Sequence[str], regions: Sequence[Region], grid_size: int = GRID_SIZE
) -> tuple[np.ndarray, list[str]]:
    """Every reading of each region's species over its grid and weeks, and the species the geomodel doesn't know.

    `occurrence` maps rows of (latitude, longitude, week) to one row of probabilities per input, one column per label.
    """
    index = {name: i for i, name in enumerate(labels)}
    values: list[np.ndarray] = []
    unknown: list[str] = []
    for region in regions:
        columns = [index[name] for name in region.species if name in index]
        unknown += [name for name in region.species if name not in index]
        inputs = np.array([[lat, lon, week] for lat, lon in grid(region.bounding_box, grid_size) for week in WEEKS], dtype=np.float32)
        values.append(np.asarray(occurrence(inputs))[:, columns].ravel())
    return np.concatenate(values), unknown


def thresholds(values: np.ndarray) -> dict[str, float]:
    """Each label's lower bound, to three decimals, over the readings at or above the floor."""
    above = values[values >= FLOOR]
    return {label: round(float(np.percentile(above, percentile)), 3) for label, percentile in PERCENTILES.items()}


def calibration(values: np.ndarray, version: int, geomodel: str, packs: Sequence[str], grid_size: int, unknown: Sequence[str]) -> dict:
    """The committed calibration file's contents."""
    return {
        "comment": (
            "Rarity label thresholds (ADR-0006, issue #52), written by `packbuilder calibrate-rarity`; never edit by hand. "
            "An occurrence at or above `common` is Common, at or above `uncommon` Uncommon, at or above `rare` Rare, "
            "and anything lower Exceptional. The thresholds are the 50th, 20th and 5th percentiles of the geomodel's readings "
            "at or above `floor` for every species of the listed packs, over a grid of points across each pack's bounding box "
            "and all 48 weeks. Saved cards keep the version they were labelled under."
        ),
        "version": version,
        "geomodel": geomodel,
        "floor": FLOOR,
        "thresholds": thresholds(values),
        "packs": list(packs),
        "grid": grid_size,
        "weeks": len(WEEKS),
        "readings": int((values >= FLOOR).sum()),
        "unknown_species": sorted(set(unknown)),
    }
