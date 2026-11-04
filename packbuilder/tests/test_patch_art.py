"""Patch art (issue #133) against a stub ComfyUI: each species' patch is painted from the reference bird its pack art
was painted from, in its edition's patch, cut from the card it lies on, measured, locked and reviewed; a warm lock
paints nothing; and `layers` gives the app the patch's colour, height, cord and stitch order."""

import hashlib
import json

import numpy as np
import pytest
from PIL import Image, ImageDraw

from packbuilder.comfy import ComfyClient
from packbuilder.pack_art import ArtLock
from packbuilder.patch_art import CORD_DEPTH, SIZE, PatchArtist, PatchLock, PatchPrompts, _isolate_prompt, cut_from_card, is_dark, layers, review
from tests.comfy_stub import bird_on, serve

FINCH, RAVEN = "haemorhous-mexicanus", "corvus-corax"


@pytest.fixture
def comfy():
    state, server = serve()
    yield state
    server.shutdown()


def isolated_bird(colours=((180, 60, 40), (120, 95, 70))) -> Image.Image:
    return bird_on(Image.new("RGB", (576, 768), "white"), box=(0.25, 0.25, 0.75, 0.8), colours=colours)


def pack_art_lock(tmp_path, cache) -> ArtLock:
    """The pack-art lock and its cached isolated birds: a finch and a raven, a black bird."""
    lock = ArtLock(tmp_path / "art.lock.json", {})
    prompt = hashlib.sha256(_isolate_prompt().encode()).hexdigest()[:10]
    for species_id, photo, name, colours in [(FINCH, 11, "House Finch", None), (RAVEN, 12, "Northern Raven", ((12, 12, 14), (20, 20, 24)))]:
        lock.species[species_id] = {"common_name": name, "photos": [photo], "isolate_seed": 49, "review": "approved"}
        path = cache / "isolated" / f"{photo}-s49-bird-isolate@1-i{prompt}.png"
        path.parent.mkdir(parents=True, exist_ok=True)
        (isolated_bird(colours) if colours else isolated_bird()).save(path)
    return lock


def artist(tmp_path, comfy, prompts=None) -> PatchArtist:
    cache = tmp_path / "cache"
    return PatchArtist(ComfyClient(comfy.url, poll_seconds=0.01), pack_id="us-ca-la", lock=PatchLock.load(tmp_path / "patch.lock.json"),
                       art_lock=pack_art_lock(tmp_path, cache), cache_dir=cache, **({"prompts": prompts} if prompts else {}))


def test_each_species_is_painted_from_its_pack_art_reference_in_its_editions_patch_and_locked(tmp_path, comfy):
    patches = artist(tmp_path, comfy).paint([FINCH])

    painting = comfy.paintings[0]
    assert painting.filename_prefix == "birdjournal/patch-art"
    assert "a perfect circle" in painting.prompt and "olive-green" in painting.prompt and "tan cotton twill" in painting.prompt
    assert "House Finch" not in painting.prompt, "the reference is the identity, never the name"
    assert "black thread" not in painting.prompt, "the dark-bird clause is for dark birds only"
    entry = json.loads((tmp_path / "patch.lock.json").read_text())["species"][FINCH]
    assert entry["photos"] == [11] and entry["isolate_seed"] == 49
    assert entry["workflow"] == "patch-art@1" and entry["prompts"] == PatchPrompts.load().version
    assert entry["edition"]["shape"] == "a perfect circle"
    assert entry["review"] == "pending" and entry["dark"] is False
    assert entry["measure"]["iou"] > 0.6, "the bird inside the patch is found and measured"
    patch = patches[FINCH]
    assert patch.review == "pending" and not patch.ships
    cut = Image.open(patch.file)
    assert cut.mode == "RGBA" and max(cut.size) == SIZE
    alpha = np.asarray(cut)[..., 3]
    assert alpha[0, 0] == 0 and alpha[cut.height // 2, cut.width // 2] == 255, "cut from the card: transparent around, opaque inside"


def test_a_warm_lock_paints_nothing_and_a_new_edition_or_prompts_paint_again(tmp_path, comfy):
    artist(tmp_path, comfy).paint([FINCH])
    assert len(comfy.paintings) == 1
    artist(tmp_path, comfy).paint([FINCH])
    assert len(comfy.paintings) == 1, "warm: nothing painted"

    base = PatchPrompts.load()
    changed = PatchPrompts(base.version + 1, base.template, base.dark, base.dark_lightness, base.editions)
    artist(tmp_path, comfy, prompts=changed).paint([FINCH])
    assert len(comfy.paintings) == 2, "new prompts: painted again"


def test_a_rejected_patch_is_painted_again_with_the_next_seed_and_approval_ships_it(tmp_path, comfy):
    artist(tmp_path, comfy).paint([FINCH])
    lock = PatchLock.load(tmp_path / "patch.lock.json")
    first_seed = lock.species[FINCH]["seed"]
    review(lock, reject=["House Finch"], why="the breast is too red")
    patches = artist(tmp_path, comfy).paint([FINCH])
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["seed"] != first_seed and entry["rejected_seeds"] == [first_seed] and entry["why"] == "the breast is too red"
    assert patches[FINCH].review == "pending"

    lock = PatchLock.load(tmp_path / "patch.lock.json")
    review(lock, approve_all=True)
    assert artist(tmp_path, comfy).paint([FINCH])[FINCH].ships


def test_a_dark_bird_gets_the_black_thread_clause(tmp_path, comfy):
    artist(tmp_path, comfy).paint([RAVEN])
    assert "black thread" in comfy.paintings[0].prompt
    assert PatchLock.load(tmp_path / "patch.lock.json").species[RAVEN]["dark"] is True
    assert is_dark(isolated_bird(((12, 12, 14), (20, 20, 24))), 22) and not is_dark(isolated_bird(), 22)


def test_a_species_whose_pack_art_has_no_reference_is_left_unpainted(tmp_path, comfy):
    painter = artist(tmp_path, comfy)
    painter.art_lock.species["avis-textus"] = {"common_name": "Text Bird", "photos": [], "review": "approved"}
    patches = painter.paint(["avis-textus", FINCH])
    assert patches["avis-textus"].review == "unpainted" and patches[FINCH].review == "pending", "one failure never stops the run"


def test_the_patch_is_cut_from_its_card_without_its_shadow():
    card = Image.new("RGB", (864, 1152), (244, 243, 240))
    draw = ImageDraw.Draw(card)
    draw.ellipse((152, 212, 752, 812), fill=(222, 221, 218))  # a soft shadow, down and to the right
    draw.ellipse((132, 192, 732, 792), fill=(110, 118, 46))
    cut = cut_from_card(card)
    assert max(cut.size) == SIZE
    alpha = np.asarray(cut)[..., 3] > 128
    width = alpha.any(axis=0).sum()
    height = alpha.any(axis=1).sum()
    assert abs(width - height) < 12, "round, not stretched by its shadow"
    with pytest.raises(ValueError):
        cut_from_card(Image.new("RGB", (400, 400), (244, 243, 240)))


def test_layers_give_the_app_its_height_cord_and_stitch_order(tmp_path, comfy):
    patches = artist(tmp_path, comfy).paint([FINCH])
    made = layers(Image.open(patches[FINCH].file))
    alpha = np.asarray(made.colour)[..., 3] > 128
    height, cord, order = (np.asarray(image).astype(int) for image in (made.height, made.cord, made.order))
    assert (height[~alpha] == 0).all() and height[alpha].mean() > 100, "relief only on the patch"
    on_cord = cord > 128
    assert on_cord.any() and not on_cord[alpha.shape[0] // 2, alpha.shape[1] // 2], "the cord is the edge, not the middle"
    body = alpha & ~on_cord
    assert order[on_cord].min() >= order[body].max() - 1, "the cord is merrowed last"
    assert list(made.bounds) == sorted(made.bounds) and made.bounds[0] == 0 and made.bounds[-1] == 255
    assert np.asarray(made.colour).shape[:2] == height.shape
    assert CORD_DEPTH == 25.0


def test_a_patch_with_a_peeled_corner_is_painted_again_with_the_next_seed(tmp_path, comfy, monkeypatch):
    import packbuilder.patch_art as patch_art

    measured = iter([0.2, 0.001])
    monkeypatch.setattr(patch_art, "peeled", lambda cut: next(measured))
    artist(tmp_path, comfy).paint([FINCH])
    seeds = [job.seed for job in comfy.paintings]
    assert len(seeds) == 2 and seeds[1] == seeds[0] + 1
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["seed"] == seeds[1] and entry["attempts"] == 2 and entry["card_at_edge"] == 0.001


def test_peeled_measures_bare_card_in_the_patchs_edge():
    from packbuilder.patch_art import peeled

    clean = Image.new("RGBA", (400, 400), (0, 0, 0, 0))
    ImageDraw.Draw(clean).ellipse((0, 0, 399, 399), fill=(110, 118, 46, 255))
    assert peeled(clean) < 0.001
    curled = clean.copy()
    ImageDraw.Draw(curled).polygon([(40, 300), (140, 400), (40, 400)], fill=(240, 239, 236, 255))
    assert peeled(curled) > 0.015
