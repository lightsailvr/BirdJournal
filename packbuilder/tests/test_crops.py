from packbuilder.crops import LENS_SIZE, PHONE_MAX_SIZE, lens_crop_box, phone_crop_box, render_lens, render_phone
from packbuilder.scoring import Box
from tests.conftest import synthetic_photo


def test_lens_crop_is_a_square_around_the_bird_inside_the_image():
    box = lens_crop_box(Box(0.4, 0.3, 0.6, 0.5), (400, 300))
    left, top, right, bottom = box
    assert right - left == bottom - top
    assert 0 <= left < right <= 400 and 0 <= top < bottom <= 300
    assert left <= 160 and right >= 240 and top <= 90 and bottom >= 150


def test_lens_crop_near_an_edge_is_shifted_not_shrunk():
    left, top, right, bottom = lens_crop_box(Box(0.9, 0.0, 1.0, 0.1), (400, 300))
    assert right == 400 and top == 0
    assert right - left == bottom - top


def test_rendered_sizes():
    photo = synthetic_photo(size=(1600, 1200))
    lens = render_lens(photo, Box(0.3, 0.3, 0.7, 0.7))
    assert lens.size == (LENS_SIZE, LENS_SIZE)
    phone = render_phone(photo, Box(0.3, 0.3, 0.7, 0.7))
    assert max(phone.size) <= PHONE_MAX_SIZE
    assert phone.size[0] > lens.size[0]


def test_phone_crop_keeps_context_around_the_bird():
    left, top, right, bottom = phone_crop_box(Box(0.4, 0.4, 0.6, 0.6), (1000, 1000))
    assert left < 400 and right > 600 and top < 400 and bottom > 600
