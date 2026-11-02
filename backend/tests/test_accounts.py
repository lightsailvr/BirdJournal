"""The account: created on the first authenticated call, read back after, and renamed by its owner."""

from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from tests.conftest import Clock
from tests.tokens import TestIssuer


def test_the_first_call_creates_the_account_and_returns_it(client: TestClient, issuer: TestIssuer) -> None:
    response = client.get("/v1/account", headers=issuer.headers(sub="apple-sub-1"))
    assert response.status_code == 200
    assert response.json() == {
        "id": "apple-sub-1",
        "display_name": None,
        "created_at": "2026-11-01T09:30:00Z",
        # From the token's username (signinwithapple_…): the app asks Apple again at deletion (#71).
        "provider": "apple",
    }


def test_a_google_account_says_so(client: TestClient, issuer: TestIssuer) -> None:
    headers = issuer.headers(sub="g-1", username="google_1234")
    assert client.get("/v1/account", headers=headers).json()["provider"] == "google"


def test_later_calls_return_the_same_account(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    first = client.get("/v1/account", headers=issuer.headers()).json()
    clock.now += timedelta(days=3)
    second = client.get("/v1/account", headers=issuer.headers()).json()
    assert second == first


def test_each_subject_has_its_own_account(client: TestClient, issuer: TestIssuer) -> None:
    client.patch("/v1/account", headers=issuer.headers(sub="a"), json={"display_name": "Ada"})
    other = client.get("/v1/account", headers=issuer.headers(sub="b")).json()
    assert other["id"] == "b"
    assert other["display_name"] is None


def test_the_display_name_can_be_updated(client: TestClient, issuer: TestIssuer) -> None:
    client.get("/v1/account", headers=issuer.headers())
    response = client.patch("/v1/account", headers=issuer.headers(), json={"display_name": "Matt C."})
    assert response.status_code == 200
    assert response.json()["display_name"] == "Matt C."
    assert client.get("/v1/account", headers=issuer.headers()).json()["display_name"] == "Matt C."


def test_updating_before_any_read_creates_the_account(client: TestClient, issuer: TestIssuer) -> None:
    response = client.patch("/v1/account", headers=issuer.headers(sub="new"), json={"display_name": "Wren"})
    assert response.status_code == 200
    assert response.json() == {
        "id": "new", "display_name": "Wren", "created_at": "2026-11-01T09:30:00Z", "provider": "apple"
    }


def test_the_display_name_is_trimmed(client: TestClient, issuer: TestIssuer) -> None:
    response = client.patch("/v1/account", headers=issuer.headers(), json={"display_name": "  Robin  "})
    assert response.json()["display_name"] == "Robin"


@pytest.mark.parametrize("name", ["", "   ", "x" * 41, "tab\there", "new\nline"])
def test_a_blank_long_or_control_character_name_is_refused(
    client: TestClient, issuer: TestIssuer, name: str
) -> None:
    client.patch("/v1/account", headers=issuer.headers(), json={"display_name": "Kept"})
    response = client.patch("/v1/account", headers=issuer.headers(), json={"display_name": name})
    assert response.status_code == 422
    assert client.get("/v1/account", headers=issuer.headers()).json()["display_name"] == "Kept"


def test_updating_needs_a_valid_token(client: TestClient, issuer: TestIssuer) -> None:
    response = client.patch(
        "/v1/account", headers=issuer.headers(client_id="some-other-client"), json={"display_name": "X"}
    )
    assert response.status_code == 401
