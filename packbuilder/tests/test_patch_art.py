"""Patch art (issue #133) against a stub ComfyUI: each species' patch is painted from the reference bird its pack art
was painted from, in its edition's patch, cut from the card it lies on, measured, locked and reviewed; a warm lock
paints nothing; and `layers` gives the app the patch's colour, height, cord and stitch order."""

import hashlib
import json

import numpy as np
from scipy import ndimage
import pytest
from PIL import Image, ImageDraw

from packbuilder.comfy import ComfyClient
from packbuilder.pack_art import ArtLock
from packbuilder.geometry import Box
from packbuilder.patch_art import CORD_DEPTH, SIZE, PatchArtist, PatchLock, PatchPin, PatchPrompts, _isolate_prompt, cut_from_card, is_dark, layers, trim_rim, review
from tests.comfy_stub import BACKGROUND, bird_on, serve

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


def test_a_species_stands_where_it_lives_with_the_markings_it_was_given(tmp_path, comfy):
    painter = artist(tmp_path, comfy)
    painter.pins = {FINCH: PatchPin(setting="water", markings="The head is solid black and the bill is white.")}
    painter.paint([FINCH])
    prompt = comfy.paintings[0].prompt
    assert "swims on calm water" in prompt and "no branch" in prompt and "perches" not in prompt
    assert "The head is solid black and the bill is white." in prompt
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["setting"] == "water" and entry["markings"] == "The head is solid black and the bill is white."


def test_every_setting_a_pack_can_pin_has_its_words():
    prompts = PatchPrompts.load()
    for kind in ("perch", "trunk", "ground", "rock", "shore", "wade", "water", "flight"):
        assert prompts.settings[kind] in prompts.render(prompts.editions["us-ca-la"], False, kind)
    assert PatchPin.from_art({"setting": "water", "patch": {"reference": 7, "markings": "Black."}}) == PatchPin("water", 7, "Black.")
    assert PatchPin.from_art({}) == PatchPin("perch", None, None)
    assert PatchPin.from_art({"patch": {"reference": 7, "box": [0.1, 0.2, 0.3, 0.4]}}).box == (0.1, 0.2, 0.3, 0.4)


def test_a_pinned_reference_is_isolated_from_its_original_and_cached(tmp_path, comfy):
    originals = tmp_path / "originals"
    originals.mkdir()
    photo = Image.new("RGB", (1200, 1600), BACKGROUND)
    bird_on(photo, box=(0.3, 0.25, 0.7, 0.75))
    photo.save(originals / "77.jpeg", "JPEG", quality=95)  # iNaturalist's extension: .jpg, .jpeg or .png
    painter = artist(tmp_path, comfy)
    painter.pins = {FINCH: PatchPin(reference=77)}
    painter.originals, painter.find_bird = originals, lambda image: Box(0.3, 0.25, 0.7, 0.75)
    patches = painter.paint([FINCH])
    assert patches[FINCH].photos == (77,)

    # A bird the detector can't see takes the box the pin gives.
    (originals / "78.jpeg").write_bytes((originals / "77.jpeg").read_bytes())
    def blind(image):
        raise ValueError("no bird detected")
    boxed = artist(tmp_path, comfy)
    boxed.pins = {RAVEN: PatchPin(reference=78, box=(0.3, 0.25, 0.7, 0.75))}
    boxed.originals, boxed.find_bird = originals, blind
    assert boxed.paint([RAVEN])[RAVEN].photos == (78,)
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["photos"] == [77] and entry["review"] == "pending"
    painted = len(comfy.paintings)

    again = artist(tmp_path, comfy)
    again.pins = {FINCH: PatchPin(reference=77)}
    again.paint([FINCH])
    assert len(comfy.paintings) == painted, "warm: the isolation is cached and nothing is painted"


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
    changed = PatchPrompts(base.version + 1, base.template, base.dark, base.dark_lightness, base.editions, base.settings)
    artist(tmp_path, comfy, prompts=changed).paint([FINCH])
    assert len(comfy.paintings) == 1, "new prompts leave a reviewed patch alone: the review is the costly part"

    lock = PatchLock.load(tmp_path / "patch.lock.json")
    review(lock, reject=[FINCH])
    artist(tmp_path, comfy, prompts=changed).paint([FINCH])
    assert len(comfy.paintings) == 2
    assert PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]["prompts"] == changed.version, "a rejected patch takes the current templates"


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


def _patch_with_rim(rim: int = 30, cord_rgb: tuple[int, int, int] = (92, 96, 34)) -> Image.Image:
    """A round stitched patch, lying on the pale smooth crescent the cut keeps: card under its soft shadow."""
    size = 720
    rows, cols = np.mgrid[0:size, 0:size]
    radius = (size - rim * 2) / 2
    centre = size / 2 - rim / 2
    patch = np.hypot(cols - centre, rows - centre) <= radius
    # The hull: the patch and its crescent to the lower right.
    outer = patch | (np.hypot(cols - centre - rim, rows - centre - rim) <= radius)
    rng = np.random.default_rng(1)
    grain = rng.integers(-34, 34, (size, size))
    rgb = np.zeros((size, size, 3), float)
    rgb[outer & ~patch] = (170, 158, 150)
    rim_fade = np.clip((np.hypot(cols - centre, rows - centre) - radius) / max(rim, 1), 0, 1)
    rgb[outer & ~patch] += (rim_fade[outer & ~patch] * 40)[:, None]
    in_cord = patch & (np.hypot(cols - centre, rows - centre) > radius - 25)
    rgb[in_cord] = np.array(cord_rgb) + grain[in_cord][:, None]
    rgb[patch & ~in_cord] = np.array([196, 160, 104]) + grain[patch & ~in_cord][:, None]
    rgba = np.dstack([np.clip(rgb, 0, 255), outer * 255.0])
    return Image.fromarray(rgba.astype(np.uint8), "RGBA")


def test_trimming_takes_the_pale_crescent_and_keeps_the_stitched_patch():
    trimmed = trim_rim(_patch_with_rim())
    assert max(trimmed.size) == SIZE
    alpha = np.asarray(trimmed)[..., 3]
    ys, xs = np.nonzero(alpha > 128)
    width, height = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    assert abs(width - height) <= 8, "a round patch stays round once its crescent has gone"
    rgb = np.asarray(trimmed).astype(float)[..., :3]
    pale = (alpha > 128) & (rgb.mean(-1) > 140) & ((rgb.max(-1) - rgb.min(-1)) < 30)
    assert pale.sum() < 0.01 * (alpha > 128).sum(), "none of the pale crescent is left"


def test_trimming_leaves_a_patch_without_a_rim_about_as_it_was():
    plain = _patch_with_rim(rim=0)
    before = (np.asarray(plain)[..., 3] > 128).sum()
    trimmed = trim_rim(plain)
    after = (np.asarray(trimmed)[..., 3] > 128).sum()
    assert after > before * 0.93, "the cord isn't eaten"


def test_trimming_keeps_a_pale_silver_cord_because_it_is_stitched():
    silver = trim_rim(_patch_with_rim(rim=0, cord_rgb=(168, 172, 176)))
    alpha = np.asarray(silver)[..., 3] > 128
    assert alpha.sum() > 0.9 * np.pi * (SIZE / 2) ** 2, "a pale cord's grain isn't the smooth shadow"


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
