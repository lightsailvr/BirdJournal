"""Card art: prompts from the committed templates (art/prompts.json), the committed ComfyUI workflows filled for one
painting, and the 3:4 card crop of an input photo."""

import pytest

from packbuilder.art import ArtPrompts, Species, Workflow, card_crop_box
from packbuilder.geometry import Box

HOUSE_FINCH = Species(common_name="House Finch", scientific_name="Haemorhous mexicanus")


@pytest.fixture(scope="module")
def prompts():
    return ArtPrompts.load()


def test_pack_art_paints_the_species_in_its_editions_theme(prompts):
    los_angeles = prompts.render("pack", HOUSE_FINCH, "us-ca-la")
    san_diego = prompts.render("pack", HOUSE_FINCH, "us-ca-sd")

    for prompt in (los_angeles, san_diego):
        assert "House Finch (Haemorhous mexicanus)" in prompt
        assert "anatomy" in prompt and "field marks" in prompt
        assert "No typography" in prompt and "borders" in prompt and "logos" in prompt
        assert "{" not in prompt and "}" not in prompt
    assert "citrus leaves" in los_angeles and "citrus leaves" not in san_diego
    assert "seafoam" in san_diego and "seafoam" not in los_angeles


def test_scene_art_paints_the_composite_keeping_the_pasted_bird_and_inventing_nothing_else(prompts):
    prompt = prompts.render("scene", HOUSE_FINCH, "us-ca-la")

    # The bird is already pasted into image 1 (paste_bird); the painting must leave it where it is, at its size.
    assert "image 1" in prompt and "image 2" not in prompt
    assert "where it is" in prompt and "size" in prompt
    # The edition colours the light, but its motifs would be facts about the place that the photo does not show.
    assert "citrus leaves" not in prompt
    # Named, a red finch came out a Northern Cardinal (bake-off, #49).
    assert "House Finch" not in prompt and "Haemorhous" not in prompt
    # Version 2 sometimes ended in a ragged white paper edge, which is a border.
    assert "edge to edge" in prompt and "borders" in prompt


def test_photo_art_keeps_the_birds_pose_sex_and_age_and_never_names_the_species(prompts):
    prompt = prompts.render("photo", HOUSE_FINCH, "us-ca-sd")

    assert "pose" in prompt and "female" in prompt
    # Named, a female House Finch came out red and a juvenile bluebird a bright male (bake-off, #49).
    assert "House Finch" not in prompt and "Haemorhous" not in prompt


def test_legendary_scene_and_photo_art_get_more_dramatic_light(prompts):
    for kind in ("scene", "photo"):
        standard = prompts.render(kind, HOUSE_FINCH, "us-ca-la")
        legendary = prompts.render(kind, HOUSE_FINCH, "us-ca-la", legendary=True)
        assert "golden rim light" in legendary and "golden rim light" not in standard


def test_pack_art_has_no_legendary_variant_and_an_unknown_edition_is_refused(prompts):
    with pytest.raises(ValueError):
        prompts.render("pack", HOUSE_FINCH, "us-ca-la", legendary=True)
    with pytest.raises(KeyError):
        prompts.render("pack", HOUSE_FINCH, "us-xx-nowhere")


def test_the_negative_prompt_rules_out_a_photograph_and_a_border(prompts):
    assert "photograph" in prompts.negative and "border" in prompts.negative


def test_the_templates_carry_a_version(prompts):
    assert isinstance(prompts.version, int) and prompts.version >= 1


def _titled(graph, title):
    (node,) = [n for n in graph.values() if n.get("_meta", {}).get("title") == title]
    return node


def test_a_workflow_takes_its_images_the_prompt_the_negative_and_the_seed():
    workflow = Workflow.load("scene-art")
    graph = workflow.fill(images=["birdjournal/composite.png"], prompt="Paint the bird", negative="a photograph", seed=7)

    assert _titled(graph, "image 1")["inputs"]["image"] == "birdjournal/composite.png"
    assert _titled(graph, "prompt")["inputs"]["prompt"] == "Paint the bird"
    assert _titled(graph, "negative")["inputs"]["prompt"] == "a photograph"
    assert _titled(graph, "sampler")["inputs"]["seed"] == 7
    assert isinstance(workflow.version, int) and workflow.version >= 1
    # The committed graph is a template: filling it twice gives two independent graphs.
    assert workflow.fill(images=["a"], prompt="other", negative="", seed=1) != graph


def test_every_art_kind_paints_one_image_and_scene_art_paints_the_composite():
    for name in ("pack-art", "scene-art", "photo-art"):
        workflow = Workflow.load(name)
        assert workflow.image_count == 1
        with pytest.raises(ValueError):
            workflow.fill(images=["x", "y"], prompt="p", negative="", seed=1)


def test_the_bird_is_cut_out_of_its_reference_with_an_openly_licensed_model():
    workflow = Workflow.load("bird-cutout")
    graph = workflow.fill(images=["birdjournal/reference.png"])

    (cutout,) = [n for n in graph.values() if n["class_type"] == "BiRefNetRMBG"]
    reference = next(key for key, n in graph.items() if n["_meta"]["title"] == "image 1")
    assert cutout["inputs"]["image"] == [reference, 0]
    # BiRefNet is MIT; RMBG-2.0, the other remover on the box, is CC BY-NC (ADR-0001).
    assert cutout["inputs"]["model"] == "BiRefNet-general"
    # A transparent background, so the bird can be pasted into a scene.
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
    # A 360 x 640 stream frame: the middle half of its largest 3:4 card.
    assert card_crop_box(None, (360, 640), zoom=2) == (90, 200, 270, 440)


def test_the_cut_out_bird_is_pasted_centred_at_its_card_size():
    from PIL import Image, ImageDraw

    from packbuilder.art import paste_bird

    scene = Image.new("RGB", (300, 400), (90, 90, 90))
    cutout = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
    # A 20 x 40 red bird inside a transparent reference crop.
    ImageDraw.Draw(cutout).rectangle((40, 30, 59, 69), fill=(200, 30, 30, 255))

    composite = paste_bird(scene, cutout, height_fraction=0.25, ground=0.72)

    # 100 px tall (a quarter of 400) and 50 px wide, centred, its feet at 72 % of the height (288).
    assert composite.size == (300, 400)
    for inside in [(150, 240), (130, 200), (170, 280)]:
        assert composite.getpixel(inside) == (200, 30, 30), inside
    for outside in [(150, 150), (115, 240), (185, 240), (150, 300)]:
        assert composite.getpixel(outside) == (90, 90, 90), outside
