"""The painted bird against its photo: Lab conversion, registration, the dE measure and the colour fit, on synthetic
birds whose truth is known."""

import numpy as np
import pytest
from PIL import Image, ImageDraw

from packbuilder.fidelity import bird_mask, fit_colours, from_lab, lab, measure, on_white, register

GREY = (128, 128, 128)


def _bird(size=(600, 800), centre=(300, 400), scale=1.0, colours=((170, 60, 50), (110, 90, 70))):
    """A two-tone "bird" (a red head over a brown body, ellipses) on grey, and its mask."""
    image = Image.new("RGB", size, GREY)
    draw = ImageDraw.Draw(image)
    cx, cy = centre
    body = (cx - 120 * scale, cy - 60 * scale, cx + 120 * scale, cy + 160 * scale)
    head = (cx - 70 * scale, cy - 200 * scale, cx + 70 * scale, cy - 40 * scale)
    draw.ellipse(body, fill=colours[1])
    draw.ellipse(head, fill=colours[0])
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).ellipse(body, fill=255)
    ImageDraw.Draw(mask).ellipse(head, fill=255)
    return image, np.asarray(mask) > 127


def test_lab_round_trips_within_a_unit():
    rgb = np.random.default_rng(1).integers(0, 256, (32, 32, 3), dtype=np.uint8)
    back = np.asarray(from_lab(lab(Image.fromarray(rgb)))).astype(int)

    assert np.abs(back - rgb).max() <= 1


def test_registration_finds_the_painted_birds_size_and_place():
    _, photo = _bird(centre=(300, 400), scale=1.0)
    _, painted = _bird(size=(864, 1152), centre=(470, 640), scale=1.3)

    found = register(photo, painted)

    # x' = 1.3 x + (470 - 1.3 * 300), y' = 1.3 y + (640 - 1.3 * 400)
    assert found.scale == pytest.approx(1.3, rel=0.02)
    assert found.dx == pytest.approx(470 - 1.3 * 300, abs=6)
    assert found.dy == pytest.approx(640 - 1.3 * 400, abs=6)
    assert found.iou > 0.97


def test_the_same_bird_elsewhere_and_bigger_measures_as_faithful():
    photo, photo_mask = _bird()
    painting, painted_mask = _bird(size=(864, 1152), centre=(470, 640), scale=1.3)

    found = measure(painting, painted_mask, photo, photo_mask)

    assert found.dE_mean < 1 and found.dL == pytest.approx(0, abs=0.5)


def test_a_lighter_bird_shows_as_a_lightness_shift():
    photo, photo_mask = _bird()
    painting, painted_mask = _bird(size=(864, 1152), centre=(470, 640), scale=1.3, colours=((200, 90, 80), (140, 120, 100)))

    found = measure(painting, painted_mask, photo, photo_mask)

    assert found.dL > 8 and found.dE_mean > 8


def test_the_colour_fit_brings_a_relit_bird_back_and_leaves_the_rest_alone():
    photo, photo_mask = _bird()
    painting, painted_mask = _bird(size=(864, 1152), centre=(470, 640), scale=1.3, colours=((200, 90, 80), (140, 120, 100)))
    background = (40, 160, 60)
    painting = Image.fromarray(np.where(painted_mask[..., None], np.asarray(painting), np.array(background, dtype=np.uint8)))

    fitted, before, after = fit_colours(painting, painted_mask, photo, photo_mask)

    assert before.dE_mean > 8 and after.dE_mean < 2.3
    # Outside the bird (beyond the fit's soft edge) nothing moves.
    assert fitted.getpixel((20, 20)) == background and fitted.getpixel((850, 1140)) == background


def test_the_bird_is_the_largest_piece_of_a_cut_out():
    cutout = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
    draw = ImageDraw.Draw(cutout)
    draw.ellipse((40, 40, 160, 160), fill=(120, 80, 60, 255))
    draw.rectangle((5, 5, 15, 15), fill=(60, 120, 60, 255))  # a scrap of leaf

    mask = bird_mask(cutout)

    assert mask[100, 100] and not mask[10, 10]


def test_an_isolated_bird_goes_on_white():
    image, mask = _bird()

    out = on_white(image, mask)

    assert out.getpixel((5, 5)) == (255, 255, 255) and out.getpixel((300, 450)) == (110, 90, 70)


def test_a_mask_without_a_bird_is_refused():
    _, photo = _bird()
    with pytest.raises(ValueError):
        register(photo, np.zeros((10, 10), dtype=bool))


def test_the_fit_keeps_the_birds_contrast_where_the_outlines_differ():
    # The painted bird is a different shape from the photo's, so pixel pairs don't line up; a line fitted pixel by
    # pixel then flattened the bird into a silhouette. Matching each bird's own spread keeps its pattern.
    photo, photo_mask = _bird()
    painting, painted_mask = _bird(size=(864, 1152), centre=(470, 640), scale=1.3, colours=((200, 90, 80), (140, 120, 100)))
    wide = Image.new("L", painting.size, 0)
    ImageDraw.Draw(wide).ellipse((250, 300, 690, 900), fill=255)
    painted_mask = painted_mask | (np.asarray(wide) > 127)

    fitted, _, _ = fit_colours(painting, painted_mask, photo, photo_mask)

    head, body = fitted.getpixel((470, 440)), fitted.getpixel((470, 700))
    assert abs(head[0] - body[0]) > 30  # still a red head over a brown body


def test_a_bird_with_a_different_pattern_is_not_faithful_even_after_the_fit():
    photo, photo_mask = _bird()
    # The same outline, but the painted head and body swap tones: a pattern the photo doesn't have.
    painting, painted_mask = _bird(size=(864, 1152), centre=(470, 640), scale=1.3, colours=((110, 90, 70), (170, 60, 50)))

    _, _, after = fit_colours(painting, painted_mask, photo, photo_mask)

    assert not after.faithful


def test_a_relit_bird_is_faithful_once_fitted():
    photo, photo_mask = _bird()
    painting, painted_mask = _bird(size=(864, 1152), centre=(470, 640), scale=1.3, colours=((200, 90, 80), (140, 120, 100)))

    _, before, after = fit_colours(painting, painted_mask, photo, photo_mask)

    assert after.faithful and after.as_dict()["faithful"] is True
