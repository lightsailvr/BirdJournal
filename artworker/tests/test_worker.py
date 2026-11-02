"""The art worker (issue #68) against a stub ComfyUI, a local queue and buckets, and a stub API."""

from __future__ import annotations

import io
import socket
import zlib

import numpy as np
import pytest
import requests
from PIL import Image

from artworker.content_filter import preprocess
from artworker.scene import NEUTRAL_EDITION, NoReference
from packbuilder.art import ArtPrompts
from tests.conftest import TOKEN, glasses_photo

PROMPTS = ArtPrompts.load()


def _job(aws, api, job_id: str = "job-1", owner: str = "ada", upload: bool = True, **fields) -> dict:
    claim = api.claim_for(owner, job_id, **fields)
    if upload:
        aws.upload(claim["input_key"], glasses_photo())
    aws.send({"owner": owner, "job_id": job_id})
    return claim


def test_a_job_is_claimed_painted_filtered_uploaded_and_reported_ready(aws, api, comfy, content_filter, make_worker) -> None:
    claim = _job(aws, api)

    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)

    assert outcome.result == "painted"
    # Claimed, then ready with the job's own key, each with the worker token.
    assert api.paths() == ["/internal/art/jobs/ada/job-1/claim", "/internal/art/jobs/ada/job-1/ready"]
    assert all(authorization == f"Bearer {TOKEN}" for _, _, authorization in api.calls)
    ready = api.calls[1][1]
    assert ready["output_key"] == claim["output_key"]
    assert ready["provenance"].startswith("FLUX.3 Image Klein; scene-art@")
    assert "reference photo 677925555 (us-ca-la)" in ready["provenance"]
    # The painting is in the art bucket at that key: a 3:4 card JPEG.
    (key, data), = aws.art().items()
    assert key == claim["output_key"]
    painting = Image.open(io.BytesIO(data))
    assert (painting.format, painting.size) == ("JPEG", (864, 1152))
    assert aws.s3.head_object(Bucket="birdjournal-art", Key=key)["ContentType"] == "image/jpeg"
    # The filter saw the painting before it went up.
    assert [image.size for image in content_filter.seen] == [(864, 1152)]
    # The message is gone from the queue.
    assert aws.messages() == {"visible": 0, "in_flight": 0}


def test_the_painting_takes_the_reference_bird_and_the_telephoto_crop(aws, api, comfy, make_worker) -> None:
    _job(aws, api)
    make_worker(comfy.url).poll_once(wait_seconds=0)
    (scene,) = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/scene-art"]
    bird, crop = (Image.open(io.BytesIO(image)) for image in scene.images)
    assert bird.size == (432, 576)
    # The crop of the glasses photo, zoomed for a 14 cm finch, painted at card size.
    assert crop.size == (864, 1152)
    assert scene.seed == zlib.crc32(b"job-1")


def test_no_prompt_names_the_species(aws, api, comfy, make_worker) -> None:
    _job(aws, api)
    make_worker(comfy.url).poll_once(wait_seconds=0)
    for job in comfy.paintings:
        for name in ("Haemorhous", "mexicanus", "House Finch", "finch"):
            assert name.lower() not in job.prompt.lower()


def test_the_edition_lights_the_scene_and_legendary_cards_get_the_legendary_light(aws, api, comfy, make_worker) -> None:
    _job(aws, api, "standard")
    _job(aws, api, "first", legendary=True)
    worker = make_worker(comfy.url)
    worker.poll_once(wait_seconds=0)
    worker.poll_once(wait_seconds=0)
    prompts = {job.seed: job.prompt for job in comfy.paintings if job.filename_prefix == "birdjournal/scene-art"}
    standard, legendary = prompts[zlib.crc32(b"standard")], prompts[zlib.crc32(b"first")]
    edition = PROMPTS.editions["us-ca-la"]
    assert edition["light"] in standard and edition["light"] in legendary
    assert PROMPTS.light["standard"] in standard
    assert PROMPTS.light["legendary"] in legendary


def test_a_card_outside_every_lit_edition_keeps_its_photos_light_and_finds_its_bird_in_any_pack(aws, api, comfy, make_worker) -> None:
    _job(aws, api, scientific_name="Buteo jamaicensis", edition="us-fl-orlando")
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "painted"
    (scene,) = [job for job in comfy.paintings if job.filename_prefix == "birdjournal/scene-art"]
    assert NEUTRAL_EDITION["light"] in scene.prompt
    assert "reference photo 2 (us-ca-sd)" in api.calls[-1][1]["provenance"]


def test_a_bigger_bird_is_zoomed_less(references) -> None:
    from packbuilder.art import telephoto_zoom

    finch = references.find("Haemorhous mexicanus", "us-ca-la")
    hawk = references.find("Buteo jamaicensis", None)
    assert telephoto_zoom(hawk.length_cm) < telephoto_zoom(finch.length_cm)


def test_a_species_without_a_reference_bird_fails_with_no_reference(aws, api, comfy, make_worker, references) -> None:
    _job(aws, api, scientific_name="Psaltriparus minimus")
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:no_reference"
    assert api.paths()[-1] == "/internal/art/jobs/ada/job-1/failed"
    assert api.calls[-1][1] == {"reason": "no_reference"}
    assert comfy.paintings == []
    assert aws.messages() == {"visible": 0, "in_flight": 0}
    with pytest.raises(NoReference):
        references.find("Psaltriparus minimus", "us-ca-la")


def test_a_painting_the_filter_refuses_never_reaches_the_art_bucket(aws, api, comfy, content_filter, make_worker) -> None:
    content_filter.refuse = True
    _job(aws, api)
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:filtered"
    assert api.calls[-1][1] == {"reason": "filtered"}
    assert aws.art() == {}


def test_a_bird_that_never_keeps_its_markings_fails_after_three_paintings(aws, api, comfy, make_worker) -> None:
    comfy.unfaithful = {"birdjournal/scene-art"}
    _job(aws, api)
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:painting_failed"
    seeds = [job.seed for job in comfy.paintings if job.filename_prefix == "birdjournal/scene-art"]
    base = zlib.crc32(b"job-1")
    assert seeds == [base, base + 1, base + 2]
    assert aws.art() == {}


def test_with_comfyui_down_the_job_waits_in_the_queue(aws, api, make_worker) -> None:
    _job(aws, api)
    # Nothing listens there: the box's ComfyUI is off.
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        closed_port = probe.getsockname()[1]
    worker = make_worker(f"http://127.0.0.1:{closed_port}")
    # Without the builder's retries and their back-off, which the service keeps.
    worker.painter.painter.client.http = requests.Session()
    (outcome,) = worker.poll_once(wait_seconds=0)
    assert outcome.result == "later"
    assert not outcome.delete
    # Claimed but never reported: the job stays painting until the message comes back, or expires after 7 days.
    assert api.paths() == ["/internal/art/jobs/ada/job-1/claim"]
    assert aws.messages() == {"visible": 0, "in_flight": 1}


def test_a_job_the_api_says_is_gone_is_dropped_unpainted(aws, api, comfy, make_worker) -> None:
    aws.send({"owner": "ada", "job_id": "finished-long-ago"})
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "gone"
    assert comfy.paintings == []
    assert aws.messages() == {"visible": 0, "in_flight": 0}


def test_with_the_api_down_the_message_is_kept(aws, api, comfy, make_worker) -> None:
    _job(aws, api)
    api.status = 503
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "later"
    assert comfy.paintings == []
    assert aws.messages()["in_flight"] == 1


def test_a_missing_photo_fails_with_bad_input(aws, api, comfy, make_worker) -> None:
    _job(aws, api, upload=False)
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:bad_input"
    assert api.calls[-1][1] == {"reason": "bad_input"}


def test_a_photo_that_isnt_an_image_fails_with_bad_input(aws, api, comfy, make_worker) -> None:
    claim = _job(aws, api, upload=False)
    aws.upload(claim["input_key"], b"not a jpeg")
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "refused:bad_input"


def test_an_unreadable_message_is_dropped(aws, api, comfy, make_worker) -> None:
    aws.send("not json")
    (outcome,) = make_worker(comfy.url).poll_once(wait_seconds=0)
    assert outcome.result == "gone"
    assert api.calls == []


def test_try_again_is_a_new_job_and_paints_a_new_picture(aws, api, comfy, make_worker) -> None:
    _job(aws, api, "first-try")
    _job(aws, api, "try-again")
    worker = make_worker(comfy.url)
    worker.poll_once(wait_seconds=0)
    worker.poll_once(wait_seconds=0)
    seeds = {job.seed for job in comfy.paintings if job.filename_prefix == "birdjournal/scene-art"}
    assert seeds == {zlib.crc32(b"first-try"), zlib.crc32(b"try-again")}
    assert len(aws.art()) == 2


def test_the_reference_cut_out_is_kept_between_jobs(aws, api, comfy, make_worker, tmp_path) -> None:
    _job(aws, api, "one")
    _job(aws, api, "two")
    worker = make_worker(comfy.url)
    worker.poll_once(wait_seconds=0)
    worker.poll_once(wait_seconds=0)
    assert (tmp_path / "cutouts" / "references" / "us-ca-la" / "haemorhous-mexicanus.png").exists()
    reference_cutouts = [job for job in comfy.jobs if job.kind == "cutout" and job.images and Image.open(io.BytesIO(job.images[0])).size == (432, 576)]
    assert len(reference_cutouts) == 1


# The content filter's preprocessing (the model itself: test_content_filter.py).


def test_the_filter_sees_a_224_pixel_image_scaled_to_plus_minus_one() -> None:
    white = preprocess(Image.new("RGB", (864, 1152), "white"))
    black = preprocess(Image.new("RGB", (100, 100), "black"))
    assert white.shape == (1, 3, 224, 224) and white.dtype == np.float32
    assert np.allclose(white, 1.0) and np.allclose(black, -1.0)

