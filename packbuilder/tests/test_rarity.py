"""The rarity calibration (ADR-0006, issue #52): label thresholds from the geomodel's readings over the packs' species,
regions and weeks, above the identification floor."""

import json

import numpy as np
import pytest

from packbuilder.definition import BoundingBox
from packbuilder.rarity import FLOOR, Region, calibration, grid, readings, thresholds


def test_grid_spans_the_box_corner_to_corner():
    points = grid(BoundingBox(south=33.0, west=-119.0, north=34.0, east=-118.0), 3)
    assert len(points) == 9
    assert points[0] == (33.0, -119.0)
    assert points[4] == (33.5, -118.5)
    assert points[-1] == (34.0, -118.0)


def test_thresholds_are_percentiles_of_the_readings_above_the_floor():
    # 100 readings from 0.01 to 1.00: the four below the floor (0.01 to 0.029) never count.
    values = np.concatenate([np.array([0.01, 0.02, 0.025, 0.029]), np.linspace(0.04, 1.0, 97)])
    cuts = thresholds(values)
    above = values[values >= FLOOR]
    assert cuts == {
        "rare": round(float(np.percentile(above, 5)), 3),
        "uncommon": round(float(np.percentile(above, 20)), 3),
        "common": round(float(np.percentile(above, 50)), 3),
    }
    assert FLOOR < cuts["rare"] < cuts["uncommon"] < cuts["common"] < 1


def test_readings_cover_every_point_and_week_for_the_species_the_geomodel_knows():
    labels = ["Haemorhous mexicanus", "Sayornis nigricans", "Turdus merula"]
    asked = []

    def occurrence(inputs: np.ndarray) -> np.ndarray:
        asked.append(inputs)
        # Every class reads its index plus the week as a hundredth, so the test can tell rows and columns apart.
        return np.array([[0.1 * (i + 1) + week / 100 for i in range(len(labels))] for _, _, week in inputs], dtype=np.float32)

    region = Region(BoundingBox(south=0, west=0, north=1, east=1), ["Sayornis nigricans", "Haemorhous mexicanus", "Tyto furcata"])
    values, unknown = readings(occurrence, labels, [region], grid_size=2)

    assert unknown == ["Tyto furcata"]
    inputs = np.concatenate(asked)
    assert len(inputs) == 4 * 48
    assert sorted(set(inputs[:, 2].tolist())) == list(range(1, 49))
    assert values.size == 4 * 48 * 2
    assert pytest.approx(values.min(), abs=1e-6) == 0.1 + 1 / 100
    assert pytest.approx(values.max(), abs=1e-6) == 0.2 + 48 / 100


def test_the_calibration_file_names_its_version_floor_and_thresholds():
    values = np.linspace(0.0, 1.0, 1001)
    document = calibration(values, version=3, geomodel="geo.onnx", packs=["us-ca-la"], grid_size=6, unknown=["Tyto furcata"])
    assert document["version"] == 3
    assert document["floor"] == FLOOR
    assert document["geomodel"] == "geo.onnx"
    assert document["thresholds"] == thresholds(values)
    assert document["readings"] == int((values >= FLOOR).sum())
    json.dumps(document)
