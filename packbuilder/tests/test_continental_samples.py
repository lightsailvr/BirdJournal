"""`scripts/continental-samples.py` (issue #213): the Continental edition's candidates go through the patch step itself,
so what the maintainer picked from is what the step paints. Since #214 a candidate's canvas is the step's own
(`PatchSpec.canvas`), not the script's."""

import hashlib
import importlib.util
import json
from pathlib import Path

import pytest
from PIL import Image

from packbuilder.patch_art import _isolate_prompt
from tests.comfy_stub import bird_on, serve

REPO = Path(__file__).resolve().parents[2]


@pytest.fixture
def comfy():
    state, server = serve()
    yield state
    server.shutdown()


@pytest.fixture
def samples():
    spec = importlib.util.spec_from_file_location("continental_samples", REPO / "scripts" / "continental-samples.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_a_candidate_is_painted_on_its_own_canvas_and_one_without_on_the_cards(tmp_path, comfy, samples):
    data = json.loads((REPO / "art" / "continental-candidates.json").read_text())
    robin = "turdus-migratorius"
    bird = data["birds"][robin]
    isolated = tmp_path / "cache" / "art" / "isolated" / f"{bird['photo']}-s{bird['isolate_seed']}-bird-isolate@1-i{hashlib.sha256(_isolate_prompt().encode()).hexdigest()[:10]}.png"
    isolated.parent.mkdir(parents=True)
    bird_on(Image.new("RGB", (576, 768), "white"), box=(0.25, 0.25, 0.75, 0.8)).save(isolated)

    comfy.patch_boxes = [(0.70, 0.66)]
    wide = samples.artist("E", data, tmp_path, comfy.url)
    wide.client.poll_seconds = 0.01
    assert wide.paint([robin])[robin].file is not None
    upright = samples.artist("B", data, tmp_path, comfy.url)
    upright.client.poll_seconds = 0.01
    upright.paint([robin])

    canvases = [(job.node("canvas")["inputs"]["width"], job.node("canvas")["inputs"]["height"]) for job in comfy.paintings]
    assert canvases[0] == (1152, 864) and canvases[-1] == (864, 1152)
    assert "a wide rectangle lying on its long side" in comfy.paintings[0].prompt and "clearly redder than the golden border" in comfy.paintings[0].prompt
    assert json.loads((tmp_path / "E" / "patch.lock.json").read_text())["species"][robin]["edition"]["canvas"] == [1152, 864]
