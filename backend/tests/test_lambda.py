"""The Lambda adapter: an API Gateway HTTP API event reaches the app, and the settings come from the environment."""

import json
from typing import Any

import pytest
from mangum import Mangum

from birdjournal_api.app import create_app
from birdjournal_api.settings import Settings
from tests.conftest import Clock
from tests.tokens import TestIssuer


def _http_api_event(method: str, path: str, headers: dict[str, str]) -> dict[str, Any]:
    """An HTTP API payload format 2.0 event, as API Gateway sends it."""
    return {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": path,
        "rawQueryString": "",
        "headers": {"host": "api.example.com", **{name.lower(): value for name, value in headers.items()}},
        "requestContext": {
            "accountId": "123456789012",
            "apiId": "api",
            "domainName": "api.example.com",
            "http": {"method": method, "path": path, "protocol": "HTTP/1.1", "sourceIp": "203.0.113.1", "userAgent": "test"},
            "requestId": "request-1",
            "routeKey": "$default",
            "stage": "$default",
            "time": "01/Nov/2026:09:30:00 +0000",
            "timeEpoch": 1793525400000,
        },
        "isBase64Encoded": False,
    }


def test_an_http_api_event_reaches_the_account(settings: Settings, issuer: TestIssuer, clock: Clock) -> None:
    handler = Mangum(create_app(settings, signing_key=issuer.signing_key, clock=clock), lifespan="off")
    response = handler(_http_api_event("GET", "/v1/account", issuer.headers(sub="lambda-sub")), None)
    assert response["statusCode"] == 200
    assert json.loads(response["body"])["id"] == "lambda-sub"


def test_settings_come_from_the_stacks_environment() -> None:
    settings = Settings.from_env(
        {
            "TABLE_NAME": "birdjournal",
            "COGNITO_ISSUER": "https://cognito-idp.us-west-2.amazonaws.com/us-west-2_Pool",
            "COGNITO_CLIENT_IDS": "ios-client, other-client",
            "AWS_REGION": "us-west-2",
        }
    )
    assert settings.table_name == "birdjournal"
    assert settings.cognito_client_ids == frozenset({"ios-client", "other-client"})
    assert settings.dynamodb_endpoint is None
    assert settings.invite_base_url == "https://birdquest.matthewcelia.com"


def test_the_invite_base_url_comes_from_the_environment() -> None:
    settings = Settings.from_env(
        {"TABLE_NAME": "t", "COGNITO_ISSUER": "x", "COGNITO_CLIENT_IDS": "y", "INVITE_BASE_URL": "https://example.test/"}
    )
    assert settings.invite_base_url == "https://example.test"


def test_missing_settings_fail_at_start() -> None:
    with pytest.raises(KeyError, match="TABLE_NAME"):
        Settings.from_env({"COGNITO_ISSUER": "x", "COGNITO_CLIENT_IDS": "y"})


def test_the_apns_key_secret_and_topic_come_from_the_environment() -> None:
    base = {"TABLE_NAME": "t", "COGNITO_ISSUER": "x", "COGNITO_CLIENT_IDS": "y"}
    assert Settings.from_env(base).apns_secret_name is None
    settings = Settings.from_env({**base, "APNS_SECRET_NAME": "birdjournal/apns", "APNS_TOPIC": "com.example.app"})
    assert settings.apns_secret_name == "birdjournal/apns"
    assert settings.apns_topic == "com.example.app"
    assert Settings.from_env(base).apns_topic == "com.matthewcelia.mybirdjournal"
