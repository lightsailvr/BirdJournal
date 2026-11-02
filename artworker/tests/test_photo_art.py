"""Photo art (issue #69): the birder's own photo of the bird, embellished, against the stub ComfyUI."""

from __future__ import annotations

import io
import zlib

import numpy as np
from PIL import Image

from tests.conftest import comfy_stub


def bird_photo(box=(0.6, 0.2, 0.8, 0.6), size=(1600, 1200), colours=((180, 60, 40), (120, 95, 70))) -> bytes:
    """A landscape photo from a real camera: the bird off to the right on the stub's green, which the cut-out leaves
    out."""
    image = comfy_stub.bird_on(Image.new("RGB", size, comfy_stub.BACKGROUND), box=box, colours=colours)
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=95)
    return buffer.getvalue()


def _photo_job(aws, api, job_id: str = "photo-1", photo: bytes | None = None, **fields) -> dict:
    claim = api.claim_for("ada", job_id, kind="photo", **fields)
    aws.upload(claim["input_key"], photo or bird_photo())
    aws.send({"owner": "ada", "job_id": job_id})
    return claim


def test_photo_art_is_painted_from_the_photo_and_reported_ready(aws, api, comfy, content_filter, make_worker) -> None:
    claim = _photo_job(aws, api)

    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)

    assert outcome.result == "painted"
    ready = api.calls[-1][1]
    assert ready["output_key"] == claim["output_key"]
    assert ready["provenance"].startswith("FLUX.3 Image Klein; photo-art@")
    assert "from the birder's photo" in ready["provenance"]
    assert "against the photo" in ready["provenance"]
    # No reference bird: one input, the birder's photo, on the photo-art workflow.
    (painting,) = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/photo-art"]
    assert len(painting.images) == 1
    assert painting.seed == zlib.crc32(b"photo-1")
    assert not [job for job in comfy.paintings if job.filename_prefix == "birdjournal/scene-art"]
    (key, data), = aws.art().items()
    assert key == claim["output_key"]
    assert Image.open(io.BytesIO(data)).size == (864, 1152)
    assert len(content_filter.seen) == 1


def test_the_photo_is_cropped_to_the_card_around_the_bird(aws, api, comfy, make_worker) -> None:
    _photo_job(aws, api)
    make_worker(comfy.url).poll_once(wait_seconds=0)
    (painting,) = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/photo-art"]
    crop = Image.open(io.BytesIO(painting.images[0])).convert("RGB")
    width, height = crop.size
    assert abs(width / height - 3 / 4) < 0.01
    # The whole bird is in the crop, with green around it on every side.
    pixels = np.asarray(crop).astype(int)
    bird = ~np.all(np.abs(pixels - comfy_stub.BACKGROUND) < 30, axis=-1)
    rows, columns = np.flatnonzero(bird.any(axis=1)), np.flatnonzero(bird.any(axis=0))
    assert rows[0] > 0 and columns[0] > 0 and rows[-1] < height - 1 and columns[-1] < width - 1


def test_no_photo_art_prompt_names_the_species(aws, api, comfy, make_worker) -> None:
    _photo_job(aws, api)
    make_worker(comfy.url).poll_once(wait_seconds=0)
    for job in comfy.paintings:
        for name in ("Haemorhous", "mexicanus", "House Finch", "finch"):
            assert name.lower() not in job.prompt.lower()


def test_legendary_photo_art_gets_the_legendary_light(aws, api, comfy, make_worker) -> None:
    from packbuilder.art import ArtPrompts

    _photo_job(aws, api, legendary=True)
    make_worker(comfy.url).poll_once(wait_seconds=0)
    (painting,) = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/photo-art"]
    assert ArtPrompts.load().light["legendary"] in painting.prompt


def test_photo_art_of_a_species_with_no_reference_bird_is_still_painted(aws, api, comfy, make_worker) -> None:
    # The birder's photo is the identity: no pack needs a reference for it.
    _photo_job(aws, api, scientific_name="Aquila chrysaetos", edition=None)
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "painted"


def test_a_photo_with_no_bird_fails_as_no_bird(aws, api, comfy, make_worker) -> None:
    empty = io.BytesIO()
    Image.new("RGB", (1600, 1200), comfy_stub.BACKGROUND).save(empty, "JPEG", quality=95)
    _photo_job(aws, api, photo=empty.getvalue())
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:no_bird"
    assert api.calls[-1][1] == {"reason": "no_bird"}
    assert aws.art() == {}
    assert aws.messages() == {"visible": 0, "in_flight": 0}


def test_unfaithful_photo_art_fails_the_job(aws, api, comfy, make_worker) -> None:
    comfy.unfaithful.add("birdjournal/photo-art")
    _photo_job(aws, api)
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:painting_failed"
    assert len([job for job in comfy.paintings if job.filename_prefix == "birdjournal/photo-art"]) == 3
    assert aws.art() == {}
