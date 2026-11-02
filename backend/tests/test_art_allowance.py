"""The painting allowance and the switch between the friends phase and the public launch (issue #69): which jobs are
painted automatically, which come out of the 5 a day per account, "N left today", and the day starting again."""

from collections.abc import Iterator
from datetime import timedelta
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.art import paint_policy
from birdjournal_api.settings import Settings
from tests.conftest import Clock, FakeArtQueue, FakeArtStorage
from tests.tokens import TestIssuer


@pytest.fixture
def launch(settings: Settings, issuer: TestIssuer, clock: Clock, art_storage: FakeArtStorage, art_queue: FakeArtQueue) -> Iterator[TestClient]:
    """The API with the public-launch rules switched on."""
    public = Settings(**{**settings.__dict__, "art_auto_paint": "legendary_or_rare"})
    app = create_app(public, signing_key=issuer.signing_key, clock=clock, art_storage=art_storage, art_queue=art_queue)
    with TestClient(app) as client:
        yield client


def _create(client: TestClient, issuer: TestIssuer, sub: str = "ada", job_id: str | None = None, **fields: Any) -> Any:
    body = {
        "id": job_id or str(uuid4()),
        "sighting_id": str(uuid4()),
        "kind": "scene",
        "scientific_name": "Haemorhous mexicanus",
        "edition": "us-ca-la",
        "legendary": False,
        "rarity": "common",
        **fields,
    }
    return client.post("/v1/art/jobs", headers=issuer.headers(sub=sub), json=body)


def _photo(client: TestClient, issuer: TestIssuer, sub: str = "ada", **fields: Any) -> Any:
    return _create(client, issuer, sub=sub, kind="photo", requested=True, **fields)


def _allowance(client: TestClient, issuer: TestIssuer, sub: str = "ada") -> dict[str, Any]:
    response = client.get("/v1/art/allowance", headers=issuer.headers(sub=sub))
    assert response.status_code == 200, response.text
    return response.json()


# The policy, both ways.


@pytest.mark.parametrize(
    ("kind", "legendary", "rarity", "requested", "cost"),
    [
        ("scene", True, "common", False, "free"),
        ("scene", False, "rare", False, "free"),
        ("scene", False, "exceptional", False, "free"),
        ("scene", False, "uncommon", False, None),
        ("scene", False, None, False, None),
        ("scene", False, "common", True, "allowance"),
        ("scene", True, "common", True, "allowance"),
        ("photo", True, "rare", True, "allowance"),
        ("photo", False, "common", False, "allowance"),
    ],
)
def test_the_public_launch_paints_legendary_and_rare_adds_and_the_rest_on_the_allowance(
    kind: str, legendary: bool, rarity: str | None, requested: bool, cost: str | None
) -> None:
    assert paint_policy("legendary_or_rare", kind=kind, legendary=legendary, rarity=rarity, requested=requested) == cost  # type: ignore[arg-type]


@pytest.mark.parametrize("kind", ["scene", "photo"])
@pytest.mark.parametrize("requested", [False, True])
def test_the_friends_phase_paints_everything_free(kind: str, requested: bool) -> None:
    assert paint_policy("every_glasses_add", kind=kind, legendary=False, rarity=None, requested=requested) == "free"  # type: ignore[arg-type]


# The friends phase over the API: no allowance.


def test_the_friends_phase_has_no_allowance(client: TestClient, issuer: TestIssuer) -> None:
    for _ in range(7):
        assert _photo(client, issuer).status_code == 201
        assert _create(client, issuer, requested=True).status_code == 201
    allowance = _allowance(client, issuer)
    assert allowance["daily"] is None
    assert allowance["left"] is None


# The public launch over the API.


def test_five_paintings_on_request_a_day_then_refused(launch: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    assert _allowance(launch, issuer) == {"daily": 5, "used": 0, "left": 5, "resets_at": "2026-11-02T00:00:00Z"}
    for left in (4, 3, 2):
        assert _photo(launch, issuer).status_code == 201
        assert _allowance(launch, issuer)["left"] == left
    assert _create(launch, issuer, requested=True).status_code == 201
    assert _photo(launch, issuer).status_code == 201
    assert _allowance(launch, issuer)["left"] == 0
    signed = list(art_storage.signed)

    refused = _photo(launch, issuer)
    assert refused.status_code == 409
    assert refused.json()["detail"] == "allowance_spent"
    assert _create(launch, issuer, requested=True).json()["detail"] == "allowance_spent"
    # No job, and no upload offered, for a refused painting.
    assert art_storage.signed == signed
    assert len(launch.get("/v1/art/jobs", headers=issuer.headers(sub="ada")).json()["jobs"]) == 5
    assert _allowance(launch, issuer) == {"daily": 5, "used": 5, "left": 0, "resets_at": "2026-11-02T00:00:00Z"}


def test_legendary_and_rare_adds_cost_nothing(launch: TestClient, issuer: TestIssuer) -> None:
    for _ in range(6):
        assert _create(launch, issuer, legendary=True).status_code == 201
        assert _create(launch, issuer, rarity="rare").status_code == 201
    assert _allowance(launch, issuer)["left"] == 5


def test_an_ordinary_add_is_not_painted_and_costs_nothing(launch: TestClient, issuer: TestIssuer) -> None:
    refused = _create(launch, issuer, rarity="uncommon")
    assert refused.status_code == 409
    assert refused.json()["detail"] == "not_eligible"
    assert _allowance(launch, issuer)["left"] == 5


def test_a_repeated_create_costs_one_painting(launch: TestClient, issuer: TestIssuer) -> None:
    job_id = str(uuid4())
    assert _photo(launch, issuer, job_id=job_id).status_code == 201
    again = _photo(launch, issuer, job_id=job_id)
    assert again.status_code == 200
    assert again.json()["id"] == job_id
    assert _allowance(launch, issuer)["left"] == 4


def test_a_repeated_create_after_the_allowance_is_spent_still_returns_its_job(launch: TestClient, issuer: TestIssuer) -> None:
    job_id = str(uuid4())
    _photo(launch, issuer, job_id=job_id)
    for _ in range(4):
        _photo(launch, issuer)
    assert _photo(launch, issuer, job_id=job_id).status_code == 200


def test_the_allowance_is_per_account(launch: TestClient, issuer: TestIssuer) -> None:
    for _ in range(5):
        _photo(launch, issuer, sub="ada")
    assert _photo(launch, issuer, sub="ada").status_code == 409
    assert _photo(launch, issuer, sub="grace").status_code == 201
    assert _allowance(launch, issuer, sub="grace")["left"] == 4


def test_the_allowance_starts_again_at_midnight_utc(launch: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    for _ in range(5):
        _photo(launch, issuer)
    clock.now = clock.now.replace(hour=23, minute=59, second=59)
    assert _photo(launch, issuer).status_code == 409
    clock.now += timedelta(seconds=1)
    assert _allowance(launch, issuer) == {"daily": 5, "used": 0, "left": 5, "resets_at": "2026-11-03T00:00:00Z"}
    assert _photo(launch, issuer).status_code == 201


def test_a_failed_painting_still_counts(launch: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, clock: Clock) -> None:
    job = _photo(launch, issuer).json()
    art_storage.uploads[f"uploads/ada/{job['id']}.jpg"] = b"jpeg"
    launch.post(f"/v1/art/jobs/{job['id']}/submit", headers=issuer.headers(sub="ada"))
    launch.post(f"/internal/art/jobs/ada/{job['id']}/claim", headers={"Authorization": "Bearer test-worker-token"})
    launch.post(f"/internal/art/jobs/ada/{job['id']}/failed", headers={"Authorization": "Bearer test-worker-token"}, json={"reason": "painting_failed"})
    assert _allowance(launch, issuer)["left"] == 4


def test_a_smaller_allowance_is_configuration(settings: Settings, issuer: TestIssuer, clock: Clock, art_storage: FakeArtStorage) -> None:
    two = Settings(**{**settings.__dict__, "art_auto_paint": "legendary_or_rare", "art_daily_allowance": 2})
    with TestClient(create_app(two, signing_key=issuer.signing_key, clock=clock, art_storage=art_storage)) as client:
        assert _photo(client, issuer).status_code == 201
        assert _photo(client, issuer).status_code == 201
        assert _photo(client, issuer).status_code == 409
        assert _allowance(client, issuer)["daily"] == 2


def test_the_allowance_needs_the_account(launch: TestClient) -> None:
    assert launch.get("/v1/art/allowance").status_code == 401


def test_settings_read_the_allowance() -> None:
    env = {"TABLE_NAME": "t", "COGNITO_ISSUER": "https://issuer", "COGNITO_CLIENT_IDS": "c"}
    assert Settings.from_env(env).art_daily_allowance == 5
    assert Settings.from_env({**env, "ART_DAILY_ALLOWANCE": "3"}).art_daily_allowance == 3
    with pytest.raises(ValueError, match="ART_DAILY_ALLOWANCE"):
        Settings.from_env({**env, "ART_DAILY_ALLOWANCE": "lots"})
