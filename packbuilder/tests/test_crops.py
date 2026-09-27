from packbuilder.crops import LENS_HEIGHT, LENS_WIDTH, PHONE_MAX_SIZE, lens_crop_box, phone_crop_box, render_lens, render_phone
from packbuilder.geometry import Box
from tests.conftest import synthetic_photo


def test_lens_crop_is_a_card_shaped_box_around_the_bird_inside_the_image():
    left, top, right, bottom = lens_crop_box(Box(0.4, 0.3, 0.6, 0.5), (400, 300))
    assert (right - left) / (bottom - top) == 1.5
    assert 0 <= left < right <= 400 and 0 <= top < bottom <= 300
    assert left <= 160 and right >= 240 and top <= 90 and bottom >= 150


def test_lens_crop_pads_a_wide_bird_on_both_axes():
    left, top, right, bottom = lens_crop_box(Box(0.2, 0.45, 0.8, 0.55), (1000, 1000))
    assert left < 200 and right > 800 and top < 450 and bottom > 550
    assert (right - left) / (bottom - top) == 1.5


def test_lens_crop_near_an_edge_is_shifted_not_shrunk():
    left, top, right, bottom = lens_crop_box(Box(0.9, 0.0, 1.0, 0.1), (400, 300))
    assert right == 400 and top == 0
    assert (right - left) / (bottom - top) == 1.5


def test_lens_crop_in_a_narrow_image_keeps_the_card_shape():
    left, top, right, bottom = lens_crop_box(Box(0.1, 0.1, 0.9, 0.9), (300, 900))
    assert left == 0 and right == 300
    assert bottom - top == 200


def test_lens_crop_keeps_the_head_when_a_tall_bird_cannot_fit_the_card():
    # A portrait original: the widest 3:2 box is 300 × 200, shorter than the 480-pixel bird, so the crop starts at
    # the bird's head (with a little headroom) and loses the tail, not both ends.
    left, top, right, bottom = lens_crop_box(Box(0.2, 0.2, 0.8, 0.8), (300, 800))
    assert (left, right) == (0, 300) and bottom - top == 200
    assert top == 160 - 12


def test_rendered_sizes():
    photo = synthetic_photo(size=(1600, 1200))
    lens = render_lens(photo, Box(0.3, 0.3, 0.7, 0.7))
    assert lens.size == (LENS_WIDTH, LENS_HEIGHT) == (552, 368)
    phone = render_phone(photo, Box(0.3, 0.3, 0.7, 0.7))
    assert max(phone.size) <= PHONE_MAX_SIZE
    assert phone.size[0] > lens.size[0]


def test_phone_crop_keeps_context_around_the_bird():
    left, top, right, bottom = phone_crop_box(Box(0.4, 0.4, 0.6, 0.6), (1000, 1000))
    assert left < 400 and right > 600 and top < 400 and bottom > 600
