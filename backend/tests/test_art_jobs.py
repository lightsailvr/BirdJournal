"""Art jobs (issue #68): create, upload and submit, claim, ready, failed, expiry after 7 days, retry, received and
painted art's deletion, the auto-paint rule, the worker token."""

from datetime import timedelta
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.art import paint_policy
from birdjournal_api.settings import Settings
from tests.conftest import (
    ART_CDN,
    WORKER_TOKEN,
    Clock,
    FakeArtQueue,
    FakeArtStorage,
    FakeNotifier,
    FakeRetention,
)
from tests.tokens import TestIssuer

WORKER = {"Authorization": f"Bearer {WORKER_TOKEN}"}
SIGHTING = str(uuid4())


def _create(
    client: TestClient, issuer: TestIssuer, sub: str = "ada", job_id: str | None = None, sighting: str = SIGHTING, **fields: Any
) -> Any:
    body = {
        "id": job_id or str(uuid4()),
        "sighting_id": sighting,
        "kind": "scene",
        "scientific_name": "Haemorhous mexicanus",
        "edition": "us-ca-la",
        "legendary": True,
        "rarity": "common",
        **fields,
    }
    return client.post("/v1/art/jobs", headers=issuer.headers(sub=sub), json=body)


def _queued(client: TestClient, issuer: TestIssuer, storage: FakeArtStorage, sub: str = "ada", **fields: Any) -> dict[str, Any]:
    """A job created, its photo uploaded and submitted."""
    job = _create(client, issuer, sub=sub, **fields).json()
    storage.uploads[f"uploads/{sub}/{job['id']}.jpg"] = b"jpeg"
    response = client.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub=sub))
    assert response.status_code == 200, response.text
    return response.json()


def _claim(client: TestClient, job_id: str, sub: str = "ada") -> Any:
    return client.post(f"/internal/art/jobs/{sub}/{job_id}/claim", headers=WORKER)


def _ready(client: TestClient, claim: dict[str, Any], storage: FakeArtStorage) -> Any:
    storage.art[claim["output_key"]] = b"painting"
    return client.post(
        f"/internal/art/jobs/{claim['owner']}/{claim['id']}/ready",
        headers=WORKER,
        json={"output_key": claim["output_key"], "provenance": "FLUX.3 Image Klein, scene-art@2 prompts@10, dE 4.1"},
    )


def _get(client: TestClient, issuer: TestIssuer, job_id: str, sub: str = "ada") -> dict[str, Any]:
    response = client.get(f"/v1/art/jobs/{job_id}", headers=issuer.headers(sub=sub))
    assert response.status_code == 200, response.text
    return response.json()


def _open(client: TestClient, issuer: TestIssuer, sub: str = "ada") -> list[dict[str, Any]]:
    return client.get("/v1/art/jobs", headers=issuer.headers(sub=sub)).json()["jobs"]


# Create, upload, submit.


def test_a_new_job_waits_for_its_photo_with_a_presigned_upload(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_queue: FakeArtQueue
) -> None:
    job_id = str(uuid4())
    response = _create(client, issuer, job_id=job_id)
    assert response.status_code == 201, response.text
    job = response.json()
    assert job["id"] == job_id
    assert job["sighting_id"] == SIGHTING
    assert job["state"] == "awaiting_upload"
    assert job["legendary"] is True
    assert job["created_at"] == "2026-11-01T09:30:00Z"
    assert job["art_url"] is None
    assert job["upload"] == {
        "url": f"https://uploads.example/uploads/ada/{job_id}.jpg?expires=3600",
        "method": "PUT",
        "headers": {"Content-Type": "image/jpeg"},
        "expires_at": "2026-11-01T10:30:00Z",
    }
    # Nothing is queued before the photo is there.
    assert art_queue.messages == []


def test_creating_the_same_job_again_returns_it_and_creates_nothing(client: TestClient, issuer: TestIssuer) -> None:
    job_id = str(uuid4())
    first = _create(client, issuer, job_id=job_id).json()
    again = _create(client, issuer, job_id=job_id)
    assert again.status_code == 200
    assert again.json()["id"] == first["id"]
    assert again.json()["upload"]["url"] == first["upload"]["url"]
    assert [job["id"] for job in _open(client, issuer)] == [job_id]


def test_submitting_before_the_photo_arrives_is_refused(client: TestClient, issuer: TestIssuer, art_queue: FakeArtQueue) -> None:
    job = _create(client, issuer).json()
    response = client.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada"))
    assert response.status_code == 409
    assert response.json()["detail"] == "upload_missing"
    assert art_queue.messages == []


def test_submitting_queues_the_job_once(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_queue: FakeArtQueue
) -> None:
    job = _queued(client, issuer, art_storage)
    assert job["state"] == "queued"
    assert job["queued_at"] == "2026-11-01T09:30:00Z"
    assert job["expires_at"] == "2026-11-08T09:30:00Z"
    assert art_queue.messages == [("ada", job["id"])]
    again = client.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada"))
    assert again.json()["state"] == "queued"
    assert art_queue.messages == [("ada", job["id"])]
    # A create repeated after the submit (a lost response) offers no new upload.
    assert _create(client, issuer, job_id=job["id"]).json()["upload"] is None


def test_photo_art_is_a_job_kind_on_the_same_pipeline(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_queue: FakeArtQueue
) -> None:
    job = _queued(client, issuer, art_storage, kind="photo", requested=True)
    assert job["kind"] == "photo"
    assert art_queue.messages == [("ada", job["id"])]
    claim = _claim(client, job["id"]).json()
    assert claim["kind"] == "photo"
    assert _ready(client, claim, art_storage).status_code == 200
    assert _get(client, issuer, job["id"])["art_url"] == f"{ART_CDN}/{claim['output_key']}"


def test_an_unknown_kind_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    assert _create(client, issuer, kind="pack").status_code == 422


def test_photo_art_with_no_bird_fails_as_no_bird(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage, kind="photo", requested=True)
    _claim(client, job["id"])
    response = client.post(f"/internal/art/jobs/ada/{job['id']}/failed", headers=WORKER, json={"reason": "no_bird"})
    assert response.status_code == 200
    assert _get(client, issuer, job["id"])["failure"] == "no_bird"


def test_jobs_need_the_account_and_stay_their_owners(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage)
    assert client.get(f"/v1/art/jobs/{job['id']}").status_code == 401
    assert client.get(f"/v1/art/jobs/{job['id']}", headers=issuer.headers(sub="bea")).status_code == 404
    assert _open(client, issuer, sub="bea") == []


# The worker.


def test_the_worker_claims_paints_and_reports_ready(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_notifier: FakeNotifier
) -> None:
    job = _queued(client, issuer, art_storage)
    claim = _claim(client, job["id"])
    assert claim.status_code == 200, claim.text
    claimed = claim.json()
    assert claimed["id"] == job["id"]
    assert claimed["owner"] == "ada"
    assert claimed["kind"] == "scene"
    assert claimed["scientific_name"] == "Haemorhous mexicanus"
    assert claimed["edition"] == "us-ca-la"
    assert claimed["legendary"] is True
    assert claimed["input_key"] == f"uploads/ada/{job['id']}.jpg"
    assert claimed["output_key"].startswith("art/ada/") and claimed["output_key"].endswith(".jpg")
    # Unguessable: 24 random bytes.
    assert len(claimed["output_key"].removeprefix("art/ada/").removesuffix(".jpg")) == 32
    assert claimed["attempt"] == 1
    assert _get(client, issuer, job["id"])["state"] == "painting"

    response = _ready(client, claimed, art_storage)
    assert response.status_code == 200, response.text
    ready = _get(client, issuer, job["id"])
    assert ready["state"] == "ready"
    assert ready["art_url"] == f"{ART_CDN}/{claimed['output_key']}"
    assert ready["provenance"].startswith("FLUX.3 Image Klein")
    assert ready["finished_at"] == "2026-11-01T09:30:00Z"
    # The photo leaves the upload bucket as soon as the job ends.
    assert art_storage.uploads == {}
    assert art_notifier.finished == [(job["id"], "ready")]


def test_a_redelivered_job_is_claimed_again(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage)
    _claim(client, job["id"])
    again = _claim(client, job["id"])
    assert again.status_code == 200
    assert again.json()["attempt"] == 2


def test_a_finished_job_is_not_claimed(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage)
    _ready(client, _claim(client, job["id"]).json(), art_storage)
    response = _claim(client, job["id"])
    assert response.status_code == 409
    assert response.json()["detail"] == "wrong_state"


def test_a_job_awaiting_its_photo_is_not_claimed(client: TestClient, issuer: TestIssuer) -> None:
    job = _create(client, issuer).json()
    assert _claim(client, job["id"]).status_code == 409


def test_ready_must_name_the_jobs_own_key(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage)
    claimed = _claim(client, job["id"]).json()
    response = client.post(
        f"/internal/art/jobs/ada/{job['id']}/ready", headers=WORKER, json={"output_key": "art/ada/someone-elses.jpg"}
    )
    assert response.status_code == 409
    assert response.json()["detail"] == "wrong_output"
    assert _get(client, issuer, job["id"])["state"] == "painting"
    assert _ready(client, claimed, art_storage).status_code == 200


def test_the_worker_reports_a_failure(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_notifier: FakeNotifier
) -> None:
    job = _queued(client, issuer, art_storage)
    _claim(client, job["id"])
    response = client.post(f"/internal/art/jobs/ada/{job['id']}/failed", headers=WORKER, json={"reason": "filtered"})
    assert response.status_code == 200
    failed = _get(client, issuer, job["id"])
    assert failed["state"] == "failed"
    assert failed["failure"] == "filtered"
    assert failed["art_url"] is None
    assert art_storage.uploads == {}
    assert art_notifier.finished == [(job["id"], "failed")]


def test_an_unknown_failure_reason_is_refused(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage)
    response = client.post(f"/internal/art/jobs/ada/{job['id']}/failed", headers=WORKER, json={"reason": "bored"})
    assert response.status_code == 422


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": WORKER_TOKEN}])
def test_worker_routes_need_the_worker_token(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, headers: dict[str, str]
) -> None:
    job = _queued(client, issuer, art_storage)
    assert client.post(f"/internal/art/jobs/ada/{job['id']}/claim", headers=headers).status_code == 401
    assert client.post(
        f"/internal/art/jobs/ada/{job['id']}/failed", headers=headers, json={"reason": "filtered"}
    ).status_code == 401
    # Nor does a birder's access token reach them.
    assert client.post(f"/internal/art/jobs/ada/{job['id']}/claim", headers=issuer.headers(sub="ada")).status_code == 401
    assert _get(client, issuer, job["id"])["state"] == "queued"


def test_a_photo_gone_before_the_claim_sends_the_job_back_for_it(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_queue: FakeArtQueue, clock: Clock
) -> None:
    """The box was off longer than the upload bucket's one day: the phone uploads the photo again, the job keeps its
    first queueing time, and it is queued again."""
    job = _queued(client, issuer, art_storage)
    art_storage.uploads.clear()
    clock.now += timedelta(days=2)
    response = _claim(client, job["id"])
    assert response.status_code == 409
    assert response.json()["detail"] == "upload_expired"
    again = _create(client, issuer, job_id=job["id"]).json()
    assert again["state"] == "awaiting_upload"
    assert again["upload"]["url"].startswith(f"https://uploads.example/uploads/ada/{job['id']}.jpg")
    art_storage.uploads[f"uploads/ada/{job['id']}.jpg"] = b"jpeg"
    resubmitted = client.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada")).json()
    assert resubmitted["state"] == "queued"
    assert resubmitted["expires_at"] == job["expires_at"]
    assert art_queue.messages == [("ada", job["id"]), ("ada", job["id"])]
    assert _claim(client, job["id"]).status_code == 200


def test_a_painting_reported_after_its_job_expired_is_deleted(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock
) -> None:
    job = _queued(client, issuer, art_storage)
    claim = _claim(client, job["id"]).json()
    clock.now += timedelta(days=7)
    assert _get(client, issuer, job["id"])["failure"] == "expired"
    response = _ready(client, claim, art_storage)
    assert response.status_code == 409
    assert claim["output_key"] not in art_storage.art


def test_an_unknown_rule_in_the_environment_is_refused() -> None:
    with pytest.raises(ValueError, match="ART_AUTO_PAINT"):
        Settings.from_env({"TABLE_NAME": "t", "COGNITO_ISSUER": "i", "COGNITO_CLIENT_IDS": "c", "ART_AUTO_PAINT": "always"})


# Expiry.


def test_a_job_still_queued_after_7_days_fails_as_expired(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock, art_notifier: FakeNotifier
) -> None:
    job = _queued(client, issuer, art_storage)
    clock.now += timedelta(days=7) - timedelta(seconds=1)
    assert _get(client, issuer, job["id"])["state"] == "queued"
    clock.now += timedelta(seconds=1)
    expired = _get(client, issuer, job["id"])
    assert expired["state"] == "failed"
    assert expired["failure"] == "expired"
    assert art_storage.uploads == {}
    assert art_notifier.finished == [(job["id"], "failed")]
    # The box comes back and finds the message: the job is gone.
    response = _claim(client, job["id"])
    assert response.status_code == 409


def test_the_worker_claiming_an_expired_job_fails_it(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock) -> None:
    job = _queued(client, issuer, art_storage)
    clock.now += timedelta(days=8)
    response = _claim(client, job["id"])
    assert response.status_code == 410
    assert response.json()["detail"] == "expired"
    assert _get(client, issuer, job["id"])["failure"] == "expired"


def test_the_open_jobs_list_expires_overdue_jobs(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock) -> None:
    job = _queued(client, issuer, art_storage)
    clock.now += timedelta(days=7, hours=1)
    (listed,) = _open(client, issuer)
    assert (listed["id"], listed["state"], listed["failure"]) == (job["id"], "failed", "expired")


def test_a_job_never_uploaded_expires_7_days_after_creation(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    job = _create(client, issuer).json()
    clock.now += timedelta(days=7)
    assert _get(client, issuer, job["id"])["state"] == "failed"


def test_a_job_painting_for_7_days_expires_too(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock) -> None:
    """Its message went to the dead-letter queue after five tries; the phone still learns it failed."""
    job = _queued(client, issuer, art_storage)
    _claim(client, job["id"])
    clock.now += timedelta(days=7)
    assert _get(client, issuer, job["id"])["failure"] == "expired"


# Retry and received.


def test_a_retry_is_a_new_job_for_the_same_sighting(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock) -> None:
    first = _queued(client, issuer, art_storage)
    clock.now += timedelta(days=8)
    assert _get(client, issuer, first["id"])["state"] == "failed"
    retry = _queued(client, issuer, art_storage, requested=True)
    assert retry["id"] != first["id"]
    assert retry["sighting_id"] == first["sighting_id"] == SIGHTING
    assert retry["state"] == "queued"
    assert retry["expires_at"] == "2026-11-16T09:30:00Z"
    assert {job["id"]: job["state"] for job in _open(client, issuer)} == {first["id"]: "failed", retry["id"]: "queued"}


def test_try_again_on_ready_art_paints_a_second_job_and_keeps_the_first(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    first = _queued(client, issuer, art_storage)
    first_claim = _claim(client, first["id"]).json()
    _ready(client, first_claim, art_storage)
    again = _queued(client, issuer, art_storage, requested=True)
    second_claim = _claim(client, again["id"]).json()
    assert second_claim["output_key"] != first_claim["output_key"]
    assert first_claim["output_key"] in art_storage.art
    assert _get(client, issuer, first["id"])["state"] == "ready"


def test_received_ready_art_is_deleted_from_the_server_and_leaves_the_open_list(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock
) -> None:
    job = _queued(client, issuer, art_storage)
    claim = _claim(client, job["id"]).json()
    _ready(client, claim, art_storage)
    response = client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub="ada"))
    assert response.status_code == 200
    assert response.json()["received"] is True
    assert response.json()["art_url"] is None
    assert claim["output_key"] not in art_storage.art
    assert _open(client, issuer) == []
    # Saying so twice is fine.
    assert client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub="ada")).status_code == 200


def test_received_art_a_find_shows_stays_on_the_server(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, art_retention: FakeRetention
) -> None:
    job = _queued(client, issuer, art_storage)
    claim = _claim(client, job["id"]).json()
    _ready(client, claim, art_storage)
    art_retention.shown.add(claim["output_key"])
    client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub="ada"))
    assert claim["output_key"] in art_storage.art


def test_a_received_failure_leaves_the_open_list(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock) -> None:
    job = _queued(client, issuer, art_storage)
    clock.now += timedelta(days=7)
    client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub="ada"))
    assert _open(client, issuer) == []


def test_an_unfinished_job_cannot_be_received(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    job = _queued(client, issuer, art_storage)
    response = client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub="ada"))
    assert response.status_code == 409


def test_a_received_job_is_cleaned_up_by_time_to_live(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any, clock: Clock
) -> None:
    job = _queued(client, issuer, art_storage)
    _ready(client, _claim(client, job["id"]).json(), art_storage)
    client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub="ada"))
    item = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"ARTJOB#{job['id']}"})["Item"]
    assert int(item["ttl"]) == int((clock.now + timedelta(days=30)).timestamp())


# The auto-paint rule.


def test_the_friends_phase_paints_every_glasses_add() -> None:
    assert paint_policy("every_glasses_add", kind="scene", legendary=False, rarity="common", requested=False) == "free"
    assert paint_policy("every_glasses_add", kind="scene", legendary=False, rarity=None, requested=False) == "free"


@pytest.mark.parametrize(
    ("legendary", "rarity", "requested", "painted"),
    [
        (True, "common", False, True),
        (False, "rare", False, True),
        (False, "exceptional", False, True),
        (False, "uncommon", False, False),
        (False, None, False, False),
        (False, "common", True, True),
    ],
)
def test_the_public_launch_paints_legendary_and_rare_adds_and_requests(
    legendary: bool, rarity: str | None, requested: bool, painted: bool
) -> None:
    assert (paint_policy("legendary_or_rare", kind="scene", legendary=legendary, rarity=rarity, requested=requested) is not None) is painted


def test_the_rule_is_server_configuration(
    settings: Settings, issuer: TestIssuer, clock: Clock, art_storage: FakeArtStorage, art_queue: FakeArtQueue
) -> None:
    launch = Settings(**{**settings.__dict__, "art_auto_paint": "legendary_or_rare"})
    app = create_app(launch, signing_key=issuer.signing_key, clock=clock, art_storage=art_storage, art_queue=art_queue)
    with TestClient(app) as client:
        refused = _create(client, issuer, legendary=False, rarity="common")
        assert refused.status_code == 409
        assert refused.json()["detail"] == "not_eligible"
        assert art_storage.signed == []
        assert _create(client, issuer, legendary=False, rarity="rare").status_code == 201


def test_settings_read_the_art_configuration() -> None:
    settings = Settings.from_env(
        {
            "TABLE_NAME": "t",
            "COGNITO_ISSUER": "https://issuer",
            "COGNITO_CLIENT_IDS": "c",
            "UPLOAD_BUCKET": "uploads",
            "ART_BUCKET": "art",
            "ART_QUEUE_URL": "https://sqs/queue",
            "ART_CDN_BASE_URL": "https://d1.cloudfront.net/",
            "ART_WORKER_TOKEN_SECRET": "arn:secret",
            "ART_AUTO_PAINT": "legendary_or_rare",
        }
    )
    assert (settings.upload_bucket, settings.art_bucket, settings.art_queue_url) == ("uploads", "art", "https://sqs/queue")
    assert settings.art_cdn_base_url == "https://d1.cloudfront.net"
    assert settings.art_worker_token_secret == "arn:secret"
    assert settings.art_auto_paint == "legendary_or_rare"


def test_without_the_buckets_the_art_routes_are_unavailable(settings: Settings, issuer: TestIssuer, clock: Clock) -> None:
    app = create_app(settings, signing_key=issuer.signing_key, clock=clock)
    with TestClient(app) as client:
        assert _create(client, issuer).status_code == 503


# The real adapters, offline.


def test_the_upload_url_is_a_sigv4_put_for_a_jpeg_on_the_regional_bucket() -> None:
    import boto3

    from birdjournal_api.app import S3_CONFIG
    from birdjournal_api.art import S3ArtStorage

    s3 = boto3.client("s3", region_name="us-west-2", config=S3_CONFIG, aws_access_key_id="AKIDEXAMPLE", aws_secret_access_key="x")
    url = S3ArtStorage(s3, upload_bucket="birdjournal-uploads", art_bucket="art").upload_url("uploads/ada/j.jpg", timedelta(hours=1))
    assert url.startswith("https://birdjournal-uploads.s3.us-west-2.amazonaws.com/uploads/ada/j.jpg?")
    assert "X-Amz-Algorithm=AWS4-HMAC-SHA256" in url
    assert "X-Amz-Expires=3600" in url
    assert "content-type" in url.lower()


def test_the_queue_message_names_the_owner_and_the_job() -> None:
    import json

    from birdjournal_api.art import SqsArtQueue

    class Sqs:
        def __init__(self) -> None:
            self.sent: list[dict[str, str]] = []

        def send_message(self, **kwargs: str) -> None:
            self.sent.append(kwargs)

    sqs = Sqs()
    SqsArtQueue(sqs, "https://sqs/queue").send("ada", "job-1")
    (message,) = sqs.sent
    assert message["QueueUrl"] == "https://sqs/queue"
    assert json.loads(message["MessageBody"]) == {"owner": "ada", "job_id": "job-1"}


def test_the_worker_token_is_read_from_secrets_manager_once() -> None:
    from birdjournal_api.art import WorkerToken

    class Secrets:
        reads = 0

        def get_secret_value(self, SecretId: str) -> dict[str, str]:
            self.reads += 1
            assert SecretId == "arn:secret"
            return {"SecretString": "s3cret"}

    secrets_client = Secrets()
    token = WorkerToken(secret_id="arn:secret", secrets_client=secrets_client)
    assert token.matches("s3cret")
    assert not token.matches("guess")
    assert secrets_client.reads == 1
