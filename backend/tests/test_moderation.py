"""Moderation (issue #71) through the API, with Rekognition faked: art-job inputs at submit, paintings when the worker
reports them ready, and shared original photos, each withheld when flagged, and never checked with the switch off."""

from collections.abc import Iterator
from dataclasses import replace
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.moderation import UNREADABLE, Moderation, RekognitionModerator
from birdjournal_api.settings import Settings
from tests.conftest import (
    Clock,
    FakeApns,
    FakeApple,
    FakeArtQueue,
    FakeArtStorage,
    FakeMailer,
    FakeModerator,
    FakeNotifier,
    FakeUsers,
)
from tests.photos import MemoryPhotoStore
from tests.test_art_jobs import _claim, _create, _get, _queued, _ready
from tests.test_cards import _circles, _share, _upload
from tests.test_finds import _feed
from tests.tokens import TestIssuer

EXPLICIT = ("Explicit Nudity", "Explicit")


@pytest.fixture
def photos() -> MemoryPhotoStore:
    return MemoryPhotoStore()


def _app(settings: Settings, issuer: TestIssuer, clock: Clock, art_storage: FakeArtStorage, moderator: FakeModerator,
         photos: MemoryPhotoStore, **kwargs: Any) -> Any:
    return create_app(
        settings, signing_key=issuer.signing_key, clock=clock, art_storage=art_storage, art_queue=FakeArtQueue(),
        art_notifier=FakeNotifier(), push_sender=FakeApns(), mailer=FakeMailer(), moderator=moderator,
        users=FakeUsers(), apple=FakeApple(), photos=photos, **kwargs,
    )


@pytest.fixture
def moderated(
    settings: Settings, issuer: TestIssuer, clock: Clock, art_storage: FakeArtStorage, moderator: FakeModerator,
    photos: MemoryPhotoStore,
) -> Iterator[TestClient]:
    on = replace(settings, moderation=True, upload_bucket="birdjournal-uploads", art_bucket="birdjournal-art")
    with TestClient(_app(on, issuer, clock, art_storage, moderator, photos)) as client:
        yield client


@pytest.fixture
def unmoderated(
    settings: Settings, issuer: TestIssuer, clock: Clock, art_storage: FakeArtStorage, moderator: FakeModerator,
    photos: MemoryPhotoStore,
) -> Iterator[TestClient]:
    off = replace(settings, upload_bucket="birdjournal-uploads", art_bucket="birdjournal-art")
    with TestClient(_app(off, issuer, clock, art_storage, moderator, photos)) as client:
        yield client


# Art-job inputs.


def test_a_flagged_photo_fails_its_job_at_submit_and_is_never_queued(
    moderated: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, moderator: FakeModerator
) -> None:
    job = _create(moderated, issuer).json()
    key = f"uploads/ada/{job['id']}.jpg"
    art_storage.uploads[key] = b"jpeg"
    moderator.flagged[key] = EXPLICIT
    response = moderated.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada"))
    assert response.status_code == 200, response.text
    assert (response.json()["state"], response.json()["failure"]) == ("failed", "flagged")
    assert key not in art_storage.uploads
    assert moderator.asked == [("birdjournal-uploads", key)]
    assert moderated.app.state.art_jobs._queue.messages == []  # type: ignore[attr-defined]
    # The worker can't claim it.
    assert _claim(moderated, job["id"]).status_code == 409


def test_a_clean_photo_is_queued(
    moderated: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, moderator: FakeModerator
) -> None:
    job = _queued(moderated, issuer, art_storage)
    assert job["state"] == "queued"
    assert len(moderator.asked) == 1


# Art-job outputs.


def test_a_flagged_painting_fails_its_job_and_is_deleted(
    moderated: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, moderator: FakeModerator
) -> None:
    job = _queued(moderated, issuer, art_storage)
    claim = _claim(moderated, job["id"]).json()
    moderator.flagged[claim["output_key"]] = ("Graphic Violence", "Violence")
    response = _ready(moderated, claim, art_storage)
    assert response.status_code == 200, response.text
    assert response.json() == {"state": "failed"}
    assert claim["output_key"] not in art_storage.art
    assert ("birdjournal-art", claim["output_key"]) in moderator.asked
    read = _get(moderated, issuer, job["id"])
    assert (read["state"], read["failure"], read["art_url"], read["art_key"]) == ("failed", "flagged", None, None)


def test_a_clean_painting_is_ready(
    moderated: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, moderator: FakeModerator
) -> None:
    job = _queued(moderated, issuer, art_storage)
    claim = _claim(moderated, job["id"]).json()
    assert _ready(moderated, claim, art_storage).json() == {"state": "ready"}
    assert claim["output_key"] in art_storage.art


def test_swimwear_and_alcohol_are_left_alone(
    moderated: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, moderator: FakeModerator
) -> None:
    job = _create(moderated, issuer).json()
    key = f"uploads/ada/{job['id']}.jpg"
    art_storage.uploads[key] = b"jpeg"
    moderator.flagged[key] = ("Alcoholic Beverages", "Alcohol")
    response = moderated.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada"))
    assert response.json()["state"] == "queued"


# Shared photos.


def test_a_flagged_shared_photo_is_withheld_and_the_card_can_go_without_it(
    moderated: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore, moderator: FakeModerator
) -> None:
    sunday, _ = _circles(moderated, issuer)
    sighting = str(uuid4())
    key = _upload(moderated, issuer, photos, sighting)
    moderator.flagged[key] = (UNREADABLE, "")
    _, response = _share(moderated, issuer, [sunday], sighting_id=sighting, photo={"key": key})
    assert response.status_code == 422
    assert response.json()["detail"] == "photo_flagged"
    assert key in photos.deleted
    # Nothing was written.
    assert _feed(moderated, issuer, sunday, "ben")["items"] == []
    _, again = _share(moderated, issuer, [sunday], sighting_id=sighting, note="Without the photo")
    assert again.status_code == 201, again.text
    (item,) = _feed(moderated, issuer, sunday, "ben")["items"]
    assert item["card"]["photo"] is None


def test_a_clean_shared_photo_reaches_the_circle(
    moderated: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore, moderator: FakeModerator
) -> None:
    sunday, _ = _circles(moderated, issuer)
    sighting = str(uuid4())
    key = _upload(moderated, issuer, photos, sighting)
    _, response = _share(moderated, issuer, [sunday], sighting_id=sighting, photo={"key": key})
    assert response.status_code == 201, response.text
    assert ("birdjournal-art", key) in moderator.asked
    (item,) = _feed(moderated, issuer, sunday, "ben")["items"]
    assert item["card"]["photo"]["key"] == key


# The switch off.


def test_with_the_switch_off_nothing_is_checked(
    unmoderated: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, moderator: FakeModerator,
    photos: MemoryPhotoStore,
) -> None:
    moderator.flagged = {"anything": EXPLICIT}
    job = _create(unmoderated, issuer).json()
    key = f"uploads/ada/{job['id']}.jpg"
    art_storage.uploads[key] = b"jpeg"
    moderator.flagged[key] = EXPLICIT
    submitted = unmoderated.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada")).json()
    assert submitted["state"] == "queued"
    claim = _claim(unmoderated, job["id"]).json()
    moderator.flagged[claim["output_key"]] = EXPLICIT
    assert _ready(unmoderated, claim, art_storage).json() == {"state": "ready"}
    sunday, _ = _circles(unmoderated, issuer)
    sighting = str(uuid4())
    photo = _upload(unmoderated, issuer, photos, sighting)
    moderator.flagged[photo] = EXPLICIT
    _, shared = _share(unmoderated, issuer, [sunday], sighting_id=sighting, photo={"key": photo})
    assert shared.status_code == 201
    assert moderator.asked == []


def test_the_switch_is_off_by_default() -> None:
    settings = Settings.from_env({"TABLE_NAME": "t", "COGNITO_ISSUER": "https://i", "COGNITO_CLIENT_IDS": "c"})
    assert settings.moderation is False
    on = Settings.from_env({"TABLE_NAME": "t", "COGNITO_ISSUER": "https://i", "COGNITO_CLIENT_IDS": "c", "MODERATION": "on"})
    assert on.moderation is True
    with pytest.raises(ValueError):
        Settings.from_env({"TABLE_NAME": "t", "COGNITO_ISSUER": "https://i", "COGNITO_CLIENT_IDS": "c", "MODERATION": "yes"})


# The Rekognition adapter.


class _Rekognition:
    class exceptions:  # noqa: N801 - boto3's shape
        class InvalidImageFormatException(Exception):
            pass

        class ImageTooLargeException(Exception):
            pass

    def __init__(self, labels: list[dict[str, Any]] | None = None, error: type[Exception] | None = None) -> None:
        self.calls: list[dict[str, Any]] = []
        self._labels = labels or []
        self._error = error

    def detect_moderation_labels(self, **kwargs: Any) -> dict[str, Any]:
        self.calls.append(kwargs)
        if self._error is not None:
            raise self._error()
        return {"ModerationLabels": self._labels}


def test_rekognition_reads_the_object_in_place_at_60_percent() -> None:
    rekognition = _Rekognition([{"Name": "Explicit Nudity", "ParentName": "Explicit", "Confidence": 91.0}])
    moderation = Moderation(enabled=True, moderator=RekognitionModerator(rekognition), upload_bucket="u", art_bucket="a")
    assert moderation.art_flag("photos/ada/x.jpg") == "Explicit"
    assert rekognition.calls == [{"Image": {"S3Object": {"Bucket": "a", "Name": "photos/ada/x.jpg"}}, "MinConfidence": 60.0}]


def test_an_image_rekognition_cant_read_is_withheld() -> None:
    rekognition = _Rekognition(error=_Rekognition.exceptions.InvalidImageFormatException)
    moderation = Moderation(enabled=True, moderator=RekognitionModerator(rekognition), upload_bucket="u", art_bucket="a")
    assert moderation.upload_flag("uploads/ada/x.jpg") == UNREADABLE


def test_no_labels_pass() -> None:
    moderation = Moderation(enabled=True, moderator=RekognitionModerator(_Rekognition()), upload_bucket="u", art_bucket="a")
    assert moderation.upload_flag("uploads/ada/x.jpg") is None
