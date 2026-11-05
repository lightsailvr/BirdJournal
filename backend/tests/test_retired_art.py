"""Scene art, photo art and painted art are retired (issue #137): the routes that painted are gone."""

from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from tests.tokens import TestIssuer


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("POST", "/v1/art/jobs"),
        ("GET", "/v1/art/jobs"),
        ("GET", "/v1/art/allowance"),
        ("GET", f"/v1/art/jobs/{uuid4()}"),
        ("POST", f"/v1/art/jobs/{uuid4()}/submit"),
        ("POST", f"/v1/art/jobs/{uuid4()}/received"),
        ("POST", f"/internal/art/jobs/ada/{uuid4()}/claim"),
        ("POST", f"/internal/art/jobs/ada/{uuid4()}/ready"),
        ("POST", f"/internal/art/jobs/ada/{uuid4()}/failed"),
    ],
)
def test_the_art_routes_are_gone(client: TestClient, issuer: TestIssuer, method: str, path: str) -> None:
    assert client.request(method, path, headers=issuer.headers(sub="ada"), json={}).status_code == 404
