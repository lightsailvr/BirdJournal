"""The generic Uncharted patch the app ships (#222): the files are the maintainer's pick, and the app's own numbers for it
are the ones its layers were cut with."""
from __future__ import annotations

import hashlib
import json
import re

from PIL import Image

from packbuilder.art import ART_DIR
from packbuilder.patch_art import SIZE, layers, trim_rim

REPO = ART_DIR.parent
LOCK = json.loads((ART_DIR / "uncharted-patch.json").read_text())
SHIPPED = LOCK["shipped"]


def sha256(path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_the_shipped_patch_is_the_candidate_the_maintainer_picked():
    picked = next(candidate for candidate in LOCK["candidates"] if candidate["letter"] == SHIPPED["letter"])
    assert (picked["emblem"], picked["seed"]) == (SHIPPED["emblem"], SHIPPED["seed"])
    assert SHIPPED["source_sha256"] == picked["sha256"]
    assert sha256(ART_DIR / SHIPPED["source"]) == picked["sha256"]
    assert sha256(ART_DIR / SHIPPED["raw"]) == SHIPPED["raw_sha256"]


def test_the_app_ships_the_two_files_cut_from_it_at_a_packs_sizes():
    for name, side in (("colour", SIZE), ("layers", SIZE // 2)):
        path = REPO / SHIPPED[name]
        assert sha256(path) == SHIPPED[f"{name}_sha256"], path
        with Image.open(path) as opened:
            assert opened.size == (side, side), path


def test_the_canvas_colour_and_stitch_layers_are_the_cut_paintings_and_the_apps():
    with Image.open(ART_DIR / SHIPPED["source"]) as opened:
        made = layers(trim_rim(opened))
    assert "#{:02X}{:02X}{:02X}".format(*made.ground) == SHIPPED["ground"]
    assert list(made.bounds) == SHIPPED["stitch_bounds"]
    swift = (REPO / "BirdJournal/BirdJournal/Patch/PatchTextures.swift").read_text()
    declared = re.search(r'ground: "(#[0-9A-F]{6})", stitchBounds: \[([0-9, ]+)\], isGeneric: true', swift)
    assert declared, "PatchArt.uncharted's ground and stitch bounds"
    assert declared.group(1) == SHIPPED["ground"]
    assert [int(bound) for bound in declared.group(2).split(",")] == SHIPPED["stitch_bounds"]
