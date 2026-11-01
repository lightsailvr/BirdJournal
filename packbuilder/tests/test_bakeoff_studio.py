"""The bake-off's retries: a painting whose bird isn't faithful to its photo is painted again with the next seed."""

import io

import numpy as np
from PIL import Image, ImageDraw

from packbuilder.art import ArtPrompts, Workflow
from packbuilder.bakeoff import ATTEMPTS, Studio
from packbuilder.comfy import Painting


def _bird(colours):
    image = Image.new("RGB", (864, 1152), (128, 128, 128))
    draw = ImageDraw.Draw(image)
    draw.ellipse((350, 500, 590, 760), fill=colours[1])
    draw.ellipse((400, 360, 540, 520), fill=colours[0])
    return image


def _png(image):
    data = io.BytesIO()
    image.save(data, "PNG")
    return data.getvalue()


class FakeComfy:
    """Paints `by_seed[seed]`; the cut-out returns the non-grey pixels as the bird."""

    def __init__(self, by_seed):
        self.by_seed, self.seeds = by_seed, []

    def paint(self, workflow, images, prompt=None, seed=None, size=None):
        if workflow.name == "bird-cutout":
            image = Image.open(io.BytesIO(images[0][1])).convert("RGB")
            bird = np.any(np.asarray(image) != 128, axis=-1)
            cutout = image.convert("RGBA")
            cutout.putalpha(Image.fromarray((bird * 255).astype(np.uint8)))
            return Painting(image=_png(cutout), seconds=1.0)
        self.seeds.append(seed)
        return Painting(image=_png(self.by_seed[seed]), seconds=10.0)


RIGHT, SWAPPED = ((170, 60, 50), (110, 90, 70)), ((110, 90, 70), (170, 60, 50))


def _studio(tmp_path, client):
    return Studio({"scenes": [], "species": []}, ArtPrompts.load(), client, tmp_path, tmp_path)


def _photo(studio):
    photo = _bird(RIGHT)
    return photo, studio.mask("photos/1", photo)


def test_an_unfaithful_painting_is_painted_again_with_the_next_seed(tmp_path):
    client = FakeComfy({7: _bird(SWAPPED), 8: _bird(RIGHT)})
    studio = _studio(tmp_path, client)

    best, attempts = studio.best_of(Workflow.load("pack-art"), [("bird.png", b"")], "p", 7, *_photo(studio), name="paintings/x/pack")

    assert client.seeds == [7, 8] and attempts == 2
    assert best.seed == 8 and best.after.faithful


def test_with_no_faithful_painting_the_closest_is_kept_for_review(tmp_path):
    client = FakeComfy({seed: _bird(SWAPPED) for seed in range(7, 7 + ATTEMPTS)})
    studio = _studio(tmp_path, client)

    best, attempts = studio.best_of(Workflow.load("pack-art"), [("bird.png", b"")], "p", 7, *_photo(studio), name="paintings/x/pack")

    assert attempts == ATTEMPTS and len(client.seeds) == ATTEMPTS
    assert not best.after.faithful
