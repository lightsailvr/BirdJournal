"""Card art: prompts from the committed templates (art/prompts.json), the committed ComfyUI workflows filled for one
painting, the 3:4 card crop of an input photo and the telephoto crop of a glasses photo."""

import numpy as np
import pytest
from PIL import Image, ImageDraw

from packbuilder.art import CARD_SIZE, ArtPrompts, Species, Workflow, card_crop_box, telephoto_crop, telephoto_zoom
from packbuilder.geometry import Box

HOUSE_FINCH = Species(common_name="House Finch", scientific_name="Haemorhous mexicanus")


@pytest.fixture(scope="module")
def prompts():
    return ArtPrompts.load()


def test_pack_art_paints_the_reference_bird_in_its_editions_theme(prompts):
    los_angeles = prompts.render("pack", HOUSE_FINCH, "us-ca-la")
    san_diego = prompts.render("pack", HOUSE_FINCH, "us-ca-sd")

    for prompt in (los_angeles, san_diego):
        assert "<ref_image_0>" in prompt and "<ref_image_1>" not in prompt
        assert "markings" in prompt and "nothing added and nothing taken away" in prompt
        assert "No text" in prompt and "border" in prompt
        assert "{" not in prompt and "}" not in prompt
    assert "citrus leaves" in los_angeles and "citrus leaves" not in san_diego
    assert "seafoam" in san_diego and "seafoam" not in los_angeles


def test_no_template_names_the_species(prompts):
    # Named, a red finch came out a Northern Cardinal and a female bluebird a bright male (bake-off, #49); the
    # reference bird is the identity.
    for kind in ("pack", "scene", "photo"):
        prompt = prompts.render(kind, HOUSE_FINCH, "us-ca-la")
        assert "House Finch" not in prompt and "Haemorhous" not in prompt, kind


def test_scene_art_paints_the_reference_bird_into_the_place_and_invents_no_motif(prompts):
    prompt = prompts.render("scene", HOUSE_FINCH, "us-ca-la")

    assert "<ref_image_0>" in prompt and "<ref_image_1>" in prompt
    # Only the bird comes from the reference, not its perch or leaves.
    assert "Only the bird comes from <ref_image_0>" in prompt
    # The edition colours the light and adds accents, but its motifs would be facts about the place that the photo
    # does not show, and version 6's palette painted every wall terracotta.
    assert "citrus leaves" not in prompt
    assert "keeps its own shapes and colours" in prompt and "accents of terracotta" in prompt
    assert "edge to edge" in prompt


def test_photo_art_keeps_the_photo_and_the_birds_sex_and_age(prompts):
    prompt = prompts.render("photo", HOUSE_FINCH, "us-ca-sd")

    assert "<ref_image_0>" in prompt and "<ref_image_1>" not in prompt
    assert "same place in the frame" in prompt and "pose" in prompt
    assert "female" in prompt and "stays dull" in prompt


def test_legendary_scene_and_photo_art_get_more_dramatic_light(prompts):
    for kind in ("scene", "photo"):
        standard = prompts.render(kind, HOUSE_FINCH, "us-ca-la")
        legendary = prompts.render(kind, HOUSE_FINCH, "us-ca-la", legendary=True)
        assert "golden glow" in legendary and "golden glow" not in standard
        assert "keeps its true colours" in legendary


def test_pack_art_has_no_legendary_variant_and_an_unknown_edition_is_refused(prompts):
    with pytest.raises(ValueError):
        prompts.render("pack", HOUSE_FINCH, "us-ca-la", legendary=True)
    with pytest.raises(KeyError):
        prompts.render("pack", HOUSE_FINCH, "us-xx-nowhere")


def test_the_isolation_keeps_the_photos_light_and_completes_what_the_perch_hid(prompts):
    # "Soft even light" relit a dim House Finch by 63 L; the photo's own light keeps it within a few.
    assert "<ref_image_0>" in prompts.isolate and "white background" in prompts.isolate
    assert "same light, exposure and colour" in prompts.isolate
    assert "completed" in prompts.isolate and "perch" in prompts.isolate


def test_the_templates_carry_a_version(prompts):
    assert isinstance(prompts.version, int) and prompts.version >= 7


def _titled(graph, title):
    (node,) = [n for n in graph.values() if n.get("_meta", {}).get("title") == title]
    return node


def test_a_workflow_takes_its_images_the_prompt_and_the_seed():
    workflow = Workflow.load("scene-art")
    graph = workflow.fill(images=["birdjournal/bird.png", "birdjournal/scene.png"], prompt="A watercolour of the bird", seed=7)

    assert _titled(graph, "image 1")["inputs"]["image"] == "birdjournal/bird.png"
    assert _titled(graph, "image 2")["inputs"]["image"] == "birdjournal/scene.png"
    assert _titled(graph, "prompt")["inputs"]["text"] == "A watercolour of the bird"
    assert _titled(graph, "sampler")["inputs"]["seed"] == 7
    assert isinstance(workflow.version, int) and workflow.version >= 4
    # The committed graph is a template: filling it twice gives two independent graphs.
    assert workflow.fill(images=["a", "b"], prompt="other", seed=1) != graph


def test_both_references_reach_the_model_in_order():
    graph = Workflow.load("scene-art").fill(images=["bird", "scene"], prompt="p", seed=1)
    references = _titled(graph, "references")["inputs"]
    image_1, image_2 = (next(key for key, n in graph.items() if n["_meta"]["title"] == t) for t in ("image 1", "image 2"))

    # <ref_image_0> is the bird, <ref_image_1> the place.
    assert references["images.image0"] == [image_1, 0] and references["images.image1"] == [image_2, 0]
    assert references["resolution"] == "keep resolution"


def test_every_art_kind_paints_a_card_with_flux3_klein_distilled():
    for name, images in (("pack-art", 1), ("scene-art", 2), ("photo-art", 1), ("bird-isolate", 1)):
        workflow = Workflow.load(name)
        graph = workflow.fill(images=["x"] * images, prompt="p", seed=1)
        assert workflow.image_count == images, name
        # The distilled checkpoint in int8, which runs on the 3090 Ti (no FP8 or FP4 on Ampere), 16 steps, no guidance.
        assert _titled(graph, "model")["inputs"]["unet_name"] == "flux3_image_klein_sd_int8_convrot.safetensors"
        assert _titled(graph, "text encoder")["inputs"]["type"] == "flux3"
        sampler = _titled(graph, "sampler")["inputs"]
        assert (sampler["steps"], sampler["cfg"]) == (16, 1.0)
        canvas = _titled(graph, "canvas")["inputs"]
        assert (canvas["width"], canvas["height"]) == CARD_SIZE
        with pytest.raises(ValueError):
            workflow.fill(images=["x"] * (images + 1), prompt="p", seed=1)


def test_the_isolation_paints_at_the_reference_crops_own_size():
    graph = Workflow.load("bird-isolate").fill(images=["crop"], prompt="p", seed=1, size=(1152, 1536))

    canvas = _titled(graph, "canvas")["inputs"]
    assert (canvas["width"], canvas["height"]) == (1152, 1536)
    with pytest.raises(ValueError):
        Workflow.load("bird-isolate").fill(images=["crop"], size=(1150, 1536))


def test_the_bird_is_cut_out_with_an_openly_licensed_model():
    workflow = Workflow.load("bird-cutout")
    graph = workflow.fill(images=["birdjournal/reference.png"])

    (cutout,) = [n for n in graph.values() if n["class_type"] == "BiRefNetRMBG"]
    reference = next(key for key, n in graph.items() if n["_meta"]["title"] == "image 1")
    assert cutout["inputs"]["image"] == [reference, 0]
    # BiRefNet is MIT; RMBG-2.0, the other remover on the box, is CC BY-NC (ADR-0001).
    assert cutout["inputs"]["model"] == "BiRefNet-general"
    # A transparent background, so the bird's outline can be measured.
    assert cutout["inputs"]["background"] == "Alpha"


def test_a_photo_without_a_bird_box_keeps_its_largest_centred_card():
    # A 360 x 640 stream frame from the glasses.
    assert card_crop_box(None, (360, 640)) == (0, 80, 360, 560)


def test_the_card_crop_pads_the_bird_and_stays_inside_the_photo():
    # A 200 x 300 bird in the middle of a 2000 x 1500 photo, padded by half its height on each side.
    assert card_crop_box(Box(0.45, 0.4, 0.55, 0.6), (2000, 1500), padding=0.5) == (775, 450, 1225, 1050)
    # The same bird at the right edge: the crop shifts left rather than leaving the photo.
    assert card_crop_box(Box(0.9, 0.4, 1.0, 0.6), (2000, 1500), padding=0.5) == (1550, 450, 2000, 1050)
    # A bird too big to pad gets the largest card the photo holds.
    assert card_crop_box(Box(0.1, 0.1, 0.9, 0.9), (2000, 1600), padding=0.5) == (400, 0, 1600, 1600)


def test_a_zoomed_glasses_photo_keeps_the_middle_of_the_view():
    # The viewfinder's crop is the middle half of each side: a 1080 x 1440 photo becomes its middle 540 x 720.
    assert card_crop_box(None, (1080, 1440), zoom=2) == (270, 360, 810, 1080)


def test_the_telephoto_zoom_scales_with_the_birds_length():
    assert telephoto_zoom(14.5) == pytest.approx(12)
    assert telephoto_zoom(42) == pytest.approx(4.14, abs=0.01)  # a Cooper's Hawk
    assert telephoto_zoom(10) == pytest.approx(17.4)  # a hummingbird
    assert telephoto_zoom(400) == 1  # never wider than the photo


def _scene_with_a_mark(size, at):
    scene = Image.new("RGB", size, (90, 90, 90))
    x, y = at
    ImageDraw.Draw(scene).rectangle((x - 5, y - 5, x + 5, y + 5), fill=(220, 20, 20))
    return scene


def _red_centre(image):
    ys, xs = np.nonzero(np.asarray(image)[..., 0] > 150)
    return xs.mean(), ys.mean()


def test_the_telephoto_crop_puts_the_perch_where_the_bird_stands():
    # A 3024 x 4032 glasses photo with its perch marked at (1512, 2000); at 12x the crop is 252 x 336 photo pixels.
    scene = _scene_with_a_mark((3024, 4032), (1512, 2000))
    crop = telephoto_crop(scene, 14.5, perch=(0.5, 2000 / 4032))

    assert crop.size == CARD_SIZE
    x, y = _red_centre(crop)
    assert x == pytest.approx(0.5 * 864, abs=4) and y == pytest.approx(0.72 * 1152, abs=4)


def test_the_telephoto_crop_shifts_rather_than_leaving_the_photo():
    # A perch in the top-left corner: the crop starts at the corner, so the mark sits up and to the left of the perch spot.
    scene = _scene_with_a_mark((3024, 4032), (60, 60))
    x, y = _red_centre(telephoto_crop(scene, 14.5, perch=(60 / 3024, 60 / 4032)))

    assert x == pytest.approx(60 / 252 * 864, abs=4) and y == pytest.approx(60 / 336 * 1152, abs=4)


def test_without_a_perch_the_telephoto_crop_frames_where_the_wearer_aimed():
    scene = _scene_with_a_mark((3024, 4032), (1512, 2016))
    x, y = _red_centre(telephoto_crop(scene, 14.5))

    # The middle of the photo is the perch spot, a little below the crop's middle.
    assert x == pytest.approx(432, abs=4) and y == pytest.approx(0.72 * 1152, abs=4)
