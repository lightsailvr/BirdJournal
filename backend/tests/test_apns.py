"""The APNs sender (issue #63) against a mock transport: the request APNs expects, the provider token, and what its
answers mean."""

import json
from typing import Any

import httpx2
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from birdjournal_api.apns import TOKEN_LIFETIME_SECONDS, ApnsCredentials, ApnsSender
from birdjournal_api.devices import Device, Environment
from birdjournal_api.pushes import Push, PushKind, SendResult

TOPIC = "com.matthewcelia.mybirdjournal"
TOKEN = "ab" * 32


@pytest.fixture
def key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


@pytest.fixture
def credentials(key: ec.EllipticCurvePrivateKey) -> ApnsCredentials:
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return ApnsCredentials(key_id="KEY1234567", team_id="647FZYVR5Q", private_key=pem.decode())


class Apns:
    def __init__(self) -> None:
        self.requests: list[httpx2.Request] = []
        self.answers: list[tuple[int, dict[str, Any] | None]] = []

    def __call__(self, request: httpx2.Request) -> httpx2.Response:
        self.requests.append(request)
        status, body = self.answers.pop(0) if self.answers else (200, None)
        return httpx2.Response(status, json=body) if body is not None else httpx2.Response(status)


class Clock:
    def __init__(self) -> None:
        self.now = 1_793_525_400.0

    def __call__(self) -> float:
        return self.now


def _sender(credentials: ApnsCredentials | None, apns: Apns, clock: Clock) -> ApnsSender:
    return ApnsSender(lambda: credentials, TOPIC, client=httpx2.Client(transport=httpx2.MockTransport(apns)), now=clock)


NOTABLE = Push(kind=PushKind.NOTABLE, title="Maya found a Black Phoebe", body="Legendary · Pasadena", data={"find": {"sighting_id": "s"}}, thread_id="friend-maya")
REFRESH = Push(kind=PushKind.REFRESH, data={"circle_ids": ["c"]})


def test_an_alert_goes_to_the_device_s_environment_with_a_signed_token(
    credentials: ApnsCredentials, key: ec.EllipticCurvePrivateKey
) -> None:
    apns, clock = Apns(), Clock()
    sender = _sender(credentials, apns, clock)
    assert sender.send(Device(TOKEN, Environment.SANDBOX), NOTABLE) is SendResult.SENT
    assert sender.send(Device(TOKEN, Environment.PRODUCTION), NOTABLE) is SendResult.SENT
    sandbox, production = apns.requests
    assert str(sandbox.url) == f"https://api.sandbox.push.apple.com/3/device/{TOKEN}"
    assert str(production.url) == f"https://api.push.apple.com/3/device/{TOKEN}"
    assert sandbox.headers["apns-topic"] == TOPIC
    assert sandbox.headers["apns-push-type"] == "alert"
    assert sandbox.headers["apns-priority"] == "10"
    assert int(sandbox.headers["apns-expiration"]) == int(clock.now) + 24 * 3600
    body = json.loads(sandbox.content)
    assert body["aps"] == {
        "content-available": 1,
        "alert": {"title": "Maya found a Black Phoebe", "body": "Legendary · Pasadena"},
        "sound": "default",
        "thread-id": "friend-maya",
    }
    assert body["find"] == {"sighting_id": "s"}
    token = sandbox.headers["authorization"].removeprefix("bearer ")
    assert jwt.get_unverified_header(token) == {"alg": "ES256", "kid": "KEY1234567", "typ": "JWT"}
    claims = jwt.decode(token, key.public_key(), algorithms=["ES256"])
    assert claims == {"iss": "647FZYVR5Q", "iat": int(clock.now)}


def test_a_silent_refresh_is_a_background_push_at_priority_five(credentials: ApnsCredentials) -> None:
    apns = Apns()
    _sender(credentials, apns, Clock()).send(Device(TOKEN, Environment.SANDBOX), REFRESH)
    (request,) = apns.requests
    assert request.headers["apns-push-type"] == "background"
    assert request.headers["apns-priority"] == "5"
    assert json.loads(request.content) == {"aps": {"content-available": 1}, "kind": "refresh", "circle_ids": ["c"]}


def test_a_digest_carries_its_collapse_id(credentials: ApnsCredentials) -> None:
    apns = Apns()
    digest = Push(kind=PushKind.DIGEST, body="Maya found 6 birds in Pasadena", collapse_id="digest-maya")
    _sender(credentials, apns, Clock()).send(Device(TOKEN, Environment.SANDBOX), digest)
    assert apns.requests[0].headers["apns-collapse-id"] == "digest-maya"


def test_the_provider_token_is_reused_for_fifty_minutes(credentials: ApnsCredentials) -> None:
    apns, clock = Apns(), Clock()
    sender = _sender(credentials, apns, clock)
    device = Device(TOKEN, Environment.SANDBOX)
    sender.send(device, NOTABLE)
    clock.now += TOKEN_LIFETIME_SECONDS - 1
    sender.send(device, NOTABLE)
    clock.now += 1
    sender.send(device, NOTABLE)
    first, second, third = (request.headers["authorization"] for request in apns.requests)
    assert first == second != third


@pytest.mark.parametrize(
    ("status", "reason"), [(410, "Unregistered"), (400, "BadDeviceToken"), (400, "DeviceTokenNotForTopic")]
)
def test_a_dead_token_is_gone(credentials: ApnsCredentials, status: int, reason: str) -> None:
    apns = Apns()
    apns.answers.append((status, {"reason": reason}))
    assert _sender(credentials, apns, Clock()).send(Device(TOKEN, Environment.SANDBOX), NOTABLE) is SendResult.GONE


def test_an_expired_provider_token_is_made_again_and_the_push_retried(credentials: ApnsCredentials) -> None:
    apns = Apns()
    apns.answers.append((403, {"reason": "ExpiredProviderToken"}))
    clock = Clock()
    sender = _sender(credentials, apns, clock)
    clock.now += 1
    assert sender.send(Device(TOKEN, Environment.SANDBOX), NOTABLE) is SendResult.SENT
    assert len(apns.requests) == 2


def test_other_refusals_and_network_errors_fail(credentials: ApnsCredentials) -> None:
    apns = Apns()
    apns.answers.append((429, {"reason": "TooManyRequests"}))
    sender = _sender(credentials, apns, Clock())
    assert sender.send(Device(TOKEN, Environment.SANDBOX), NOTABLE) is SendResult.FAILED

    def unreachable(request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("no route", request=request)

    offline = ApnsSender(lambda: credentials, TOPIC, client=httpx2.Client(transport=httpx2.MockTransport(unreachable)))
    assert offline.send(Device(TOKEN, Environment.SANDBOX), NOTABLE) is SendResult.FAILED


def test_without_a_key_pushes_are_skipped_and_the_key_looked_for_again_later(credentials: ApnsCredentials) -> None:
    apns, clock = Apns(), Clock()
    stored: list[ApnsCredentials] = []
    loads = 0

    def load() -> ApnsCredentials | None:
        nonlocal loads
        loads += 1
        return stored[0] if stored else None

    sender = ApnsSender(load, TOPIC, client=httpx2.Client(transport=httpx2.MockTransport(apns)), now=clock)
    device = Device(TOKEN, Environment.SANDBOX)
    assert sender.send(device, NOTABLE) is SendResult.SKIPPED
    stored.append(credentials)
    assert sender.send(device, NOTABLE) is SendResult.SKIPPED
    assert loads == 1
    clock.now += 5 * 60
    assert sender.send(device, NOTABLE) is SendResult.SENT
    assert loads == 2
    clock.now += 3600
    sender.send(device, NOTABLE)
    assert loads == 2
    assert apns.requests
