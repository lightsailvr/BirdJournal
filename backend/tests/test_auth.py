"""Only a valid access token from the app's own client reaches an account."""

import time
from typing import Any

from fastapi.testclient import TestClient

from tests.tokens import TestIssuer


def test_health_needs_no_token(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_no_token_is_refused(client: TestClient) -> None:
    response = client.get("/v1/account")
    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"


def test_an_expired_token_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    an_hour_ago = int(time.time()) - 3600
    response = client.get("/v1/account", headers=issuer.headers(exp=an_hour_ago))
    assert response.status_code == 401


def test_a_token_from_another_app_client_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    response = client.get("/v1/account", headers=issuer.headers(client_id="some-other-client"))
    assert response.status_code == 401


def test_a_token_from_another_user_pool_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    other_pool = "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_OtherPool"
    response = client.get("/v1/account", headers=issuer.headers(iss=other_pool))
    assert response.status_code == 401


def test_an_id_token_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    response = client.get("/v1/account", headers=issuer.headers(token_use="id"))
    assert response.status_code == 401


def test_a_token_signed_by_an_unknown_key_is_refused(client: TestClient) -> None:
    response = client.get(
        "/v1/account", headers={"Authorization": f"Bearer {TestIssuer.forged_token()}"}
    )
    assert response.status_code == 401


def test_a_malformed_header_is_refused(client: TestClient) -> None:
    response = client.get("/v1/account", headers={"Authorization": "Basic dXNlcjpwYXNz"})
    assert response.status_code == 401


def test_a_refused_request_creates_no_account(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    client.get("/v1/account", headers=issuer.headers(client_id="some-other-client"))
    client.get("/v1/account", headers=issuer.headers(exp=int(time.time()) - 60))
    assert table.scan()["Count"] == 0
