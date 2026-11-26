"""Patch art (issue #133) against a stub ComfyUI: each species' patch is painted from the reference bird its pack art
was painted from, in its edition's patch, cut from the card it lies on, measured, locked and reviewed; a warm lock
paints nothing; and `layers` gives the app the patch's colour, height, cord and stitch order."""

import hashlib
import json
from pathlib import Path

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


def test_a_bird_that_is_black_all_over_can_be_pinned_to_go_without_the_clause(tmp_path, comfy):
    painter = artist(tmp_path, comfy)
    painter.pins = {RAVEN: PatchPin(markings="The whole bird is black.", dark_clause=False)}
    painter.paint([RAVEN])
    assert "the same contrast as the reference" not in comfy.paintings[0].prompt and "The whole bird is black." in comfy.paintings[0].prompt
    assert PatchLock.load(tmp_path / "patch.lock.json").species[RAVEN]["dark"] is False
    assert PatchPin.from_art({"patch": {"dark_clause": False}}).dark_clause is False and PatchPin.from_art({"patch": {}}).dark_clause


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


def test_a_cream_twill_inside_its_cord_is_not_a_peeled_corner():
    """New York's warm cream and Orlando's pearl twill are as pale as the card; only the cord's band is measured (#58)."""
    from packbuilder.patch_art import CORD_DEPTH, peeled

    patch = Image.new("RGBA", (400, 400), (0, 0, 0, 0))
    draw = ImageDraw.Draw(patch)
    draw.rounded_rectangle((0, 0, 399, 399), radius=70, fill=(170, 60, 50, 255))
    depth = int(CORD_DEPTH) + 2
    draw.rounded_rectangle((depth, depth, 399 - depth, 399 - depth), radius=50, fill=(238, 232, 220, 255))
    assert peeled(patch) < 0.015
    ImageDraw.Draw(patch).rectangle((150, 380, 250, 399), fill=(240, 239, 236, 255))  # card showing through the cord along the bottom
    assert peeled(patch) > 0.015


def test_a_silver_cord_is_not_card_and_card_showing_through_it_still_is():
    """The Bay Area's cord is light and unsaturated, like card; card is lighter still (#58)."""
    from packbuilder.patch_art import peeled

    patch = Image.new("RGBA", (400, 400), (0, 0, 0, 0))
    ImageDraw.Draw(patch).ellipse((0, 0, 399, 399), fill=(205, 207, 210, 255))
    ImageDraw.Draw(patch).ellipse((27, 27, 372, 372), fill=(218, 221, 221, 255))
    assert peeled(patch) < 0.015
    sheen = ImageDraw.Draw(patch)
    for x in range(120, 280, 6):  # the thread's highlights: as light as card, a few pixels each
        sheen.line((x, 4, x + 2, 12), fill=(252, 252, 250, 255), width=2)
    assert peeled(patch) < 0.015
    ImageDraw.Draw(patch).rectangle((150, 380, 250, 399), fill=(250, 250, 248, 255))
    assert peeled(patch) > 0.015


def test_shape_fit_tells_a_hexagon_on_its_flat_from_one_on_its_point_and_a_wrong_shape_is_painted_again(tmp_path, comfy, monkeypatch):
    """FLUX.3 reads "a hexagon with a flat top" loosely: half the Bay Area's trial patches stood on a point (#58)."""
    import dataclasses

    import packbuilder.patch_art as patch_art
    from packbuilder.patch_art import SHAPE_LIMIT, shape_fit

    flat = [(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)]

    def drawn(points, size=(440, 380)):
        image = Image.new("RGBA", (500, 500), (0, 0, 0, 0))
        ImageDraw.Draw(image).polygon([(30 + x * size[0], 40 + y * size[1]) for x, y in points], fill=(200, 200, 205, 255))
        return image

    assert shape_fit(drawn(flat), tuple(flat)) > 0.97
    assert shape_fit(drawn([(y, x) for x, y in flat], size=(380, 440)), tuple(flat)) < SHAPE_LIMIT, "the same hexagon on its point"

    fits = iter([0.8, 0.96])
    monkeypatch.setattr(patch_art, "shape_fit", lambda cut, outline: next(fits))
    prompts = PatchPrompts.load()
    hexagon = dataclasses.replace(prompts.editions["us-ca-la"], outline=tuple(flat))
    painter = artist(tmp_path, comfy, prompts=dataclasses.replace(prompts, editions={**prompts.editions, "us-ca-la": hexagon}))
    painter.paint([FINCH])
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["attempts"] == 2 and entry["shape_fit"] == 0.96
    assert "outline" not in entry["edition"], "the outline is no painting input: adding one repaints nothing"


def test_an_edition_sets_its_own_least_fit_and_of_the_wrong_shapes_the_nearest_is_kept(tmp_path, comfy, monkeypatch):
    """#58: the Bay Area's octagons fit its hexagon at 0.88 to 0.915, over the general limit, and a patch that stood on
    its point three times kept its first painting, not its best."""
    import dataclasses

    import packbuilder.patch_art as patch_art

    flat = ((0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5))
    prompts = PatchPrompts.load()
    assert prompts.editions["us-ca-bay"].least_fit == 0.92 and prompts.editions["us-pnw"].least_fit == patch_art.SHAPE_LIMIT
    fits = iter([0.9, 0.81, 0.91])
    monkeypatch.setattr(patch_art, "shape_fit", lambda cut, outline: next(fits))
    hexagon = dataclasses.replace(prompts.editions["us-ca-la"], outline=flat, shape_limit=0.92)
    painter = artist(tmp_path, comfy, prompts=dataclasses.replace(prompts, editions={**prompts.editions, "us-ca-la": hexagon}))
    painter.paint([FINCH])
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["attempts"] == 3 and entry["shape_fit"] == 0.91, "every try was an octagon: the nearest one is kept"
    assert "shape_limit" not in entry["edition"]


# The Continental edition (issue #214, of #206): the maintainer's pick, candidate E of #213, "as painted".

REPO = Path(__file__).resolve().parents[2]


def test_the_continental_edition_is_the_candidate_the_maintainer_picked_and_the_eight_are_as_they_were():
    picked = json.loads((REPO / "art" / "continental-candidates.json").read_text())["candidates"]["E"]
    edition = PatchPrompts.load().editions["north-america"]
    assert (edition.shape, edition.cord, edition.twill, edition.motif) == (picked["shape"], picked["cord"], picked["twill"], picked["motif"])
    assert edition.shape.startswith("a wide rectangle lying on its long side") and edition.cord == "rich golden-yellow"
    assert edition.outline == tuple(map(tuple, picked["outline"]))
    assert edition.canvas == (1152, 864), "the canvas its samples held their shape on"

    # A reviewed patch is painted again when its edition's painting inputs change: none of the eight's may.
    for pack in ("us-ca-la", "us-ca-sd", "us-ca-bay", "us-ca-desert", "us-fl-orlando", "us-pnw", "us-ny-nyc", "us-la-south"):
        spec = PatchPrompts.load().editions[pack]
        locked = {json.dumps(entry["edition"], sort_keys=True) for entry in json.loads((REPO / "packbuilder" / "packs" / pack / "patch.lock.json").read_text())["species"].values() if entry.get("edition")}
        assert locked == {json.dumps(spec.as_dict(), sort_keys=True)}, pack
        assert spec.canvas is None and spec.aspect is None


def continental_artist(tmp_path, comfy) -> PatchArtist:
    painter = artist(tmp_path, comfy)
    painter.pack_id = "north-america"
    painter.spec = painter.prompts.editions["north-america"]
    return painter


def test_a_continental_patch_is_painted_on_its_wide_canvas_and_cuts_out_to_the_wide_rectangle(tmp_path, comfy):
    # The model fits a badge to its picture: the stub's rectangle takes 70% of the canvas's width and 66% of its height,
    # as the samples' did (#213).
    comfy.patch_boxes = [(0.70, 0.66)]
    patches = continental_artist(tmp_path, comfy).paint([FINCH])

    painting = comfy.paintings[0]
    canvas = painting.node("canvas")["inputs"]
    assert (canvas["width"], canvas["height"]) == (1152, 864)
    for words in ("a wide rectangle lying on its long side", "rich golden-yellow", "pale lavender-grey cotton twill", "a big rising sun low on a far, flat horizon"):
        assert words in painting.prompt
    cut = Image.open(patches[FINCH].file)
    alpha = np.asarray(cut)[..., 3] > 128
    width, height = alpha.any(axis=0).sum(), alpha.any(axis=1).sum()
    assert cut.width == SIZE and 1.38 < width / height < 1.46, "wide, as painted: about 1.42 to 1"
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["attempts"] == 1 and entry["aspect"] == pytest.approx(width / height, abs=0.01) and entry["shape_fit"] > 0.95
    assert entry["edition"]["canvas"] == [1152, 864], "a painting input: another canvas paints the patch again"
    assert entry["measure"]["iou"] > 0.6, "the bird inside it is still found and measured"


def test_every_other_edition_is_painted_on_the_cards_own_canvas(tmp_path, comfy):
    artist(tmp_path, comfy).paint([FINCH])
    canvas = comfy.paintings[0].node("canvas")["inputs"]
    assert (canvas["width"], canvas["height"]) == (864, 1152)
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert "canvas" not in entry["edition"] and "aspect" not in entry


def test_a_continental_patch_that_comes_out_too_square_is_painted_again_with_the_next_seed(tmp_path, comfy):
    """`shape_fit` cannot see it: a square fills the rectangle's outline in its own bounding box as well as a wide one."""
    from packbuilder.patch_art import shape_fit
    from tests.comfy_stub import patch_on_card

    nearly_square = (0.56, 0.66)  # 1.13 to 1 on the wide canvas, about New York's rounded square
    comfy.patch_boxes = [nearly_square, (0.70, 0.66)]
    painter = continental_artist(tmp_path, comfy)
    painter.paint([FINCH])
    seeds = [job.seed for job in comfy.paintings]
    assert len(seeds) == 2 and seeds[1] == seeds[0] + 1
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert entry["seed"] == seeds[1] and entry["attempts"] == 2 and 1.38 < entry["aspect"] < 1.46
    assert shape_fit(cut_from_card(patch_on_card((1152, 864), isolated_bird(), nearly_square)), painter.spec.outline) > 0.95, "the outline alone would have kept the first"


def test_of_continental_patches_that_all_miss_the_aspect_the_nearest_is_kept_and_the_sheet_says_so(tmp_path, comfy, monkeypatch):
    comfy.patch_boxes = [(0.56, 0.66), (0.62, 0.66), (0.92, 0.5)]  # 1.13, 1.25 and 2.45 to 1
    painter = continental_artist(tmp_path, comfy)
    patches = painter.paint([FINCH])
    seeds = [job.seed for job in comfy.paintings]
    entry = PatchLock.load(tmp_path / "patch.lock.json").species[FINCH]
    assert len(seeds) == 3 and entry["seed"] == seeds[1] and entry["attempts"] == 2, "the 1.25 one: nearest to 1.3 to 1.55"
    assert 1.22 < entry["aspect"] < 1.29

    import packbuilder.patch_art as patch_art

    labels, draw = [], patch_art.grid
    monkeypatch.setattr(patch_art, "grid", lambda rows, *args, **kwargs: (labels.extend(label for row in rows for _, label in row), draw(rows, *args, **kwargs))[1])
    painter.sheets([FINCH], patches, tmp_path / "sheets")
    assert any("WRONG ASPECT" in label for label in labels), "the review sees why it was painted three times"
