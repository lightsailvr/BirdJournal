"""The bake-off's paintings per species: what each paints from, in workflow image order."""

import json

from packbuilder.bakeoff import PLAN, planned_paintings

SCENES = [{"id": "garden"}, {"id": "lawn"}]
FINCH = {"reference": 1, "scene_reference": 2, "photos": [3, 4]}


def test_pack_and_scene_art_paint_the_isolated_reference_and_photo_art_the_photo():
    paintings = {p.name: p for p in planned_paintings(FINCH, SCENES)}

    assert paintings["pack-us-ca-la"].inputs == ["bird:1"] and paintings["pack-us-ca-sd"].inputs == ["bird:1"]
    # The bird first (<ref_image_0>), then the place (<ref_image_1>).
    assert paintings["scene-garden"].inputs == ["bird:2", "scene:garden"]
    assert paintings["scene-garden-legendary"].inputs == ["bird:2", "scene:garden"] and paintings["scene-garden-legendary"].legendary
    assert paintings["photo-3"].inputs == ["photo:3"] and paintings["photo-3-legendary"].legendary
    assert len(paintings) == 2 + len(SCENES) + 1 + 2 + 1


def test_without_a_scene_reference_scene_art_paints_the_reference():
    without = {key: value for key, value in FINCH.items() if key != "scene_reference"}
    paintings = {p.name: p for p in planned_paintings(without, SCENES)}
    assert paintings["scene-lawn"].inputs[0] == "bird:1"


def test_the_committed_plan_has_a_length_for_every_species_and_a_perch_for_every_scene():
    plan = json.loads(PLAN.read_text())

    assert all(isinstance(s["length_cm"], (int, float)) and 5 < s["length_cm"] < 150 for s in plan["species"])
    assert all(len(s["perch"]) == 2 and all(0 <= v <= 1 for v in s["perch"]) for s in plan["scenes"])
