"""Account deletion (issue #71) through the API: everything the server holds about the account goes, the circles it
made pass on or go, the Cognito user is deleted and the Apple token revoked; and afterwards a scan of the whole table
finds no item naming the account."""

from collections.abc import Iterator
from datetime import timedelta
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.settings import Settings
from tests.conftest import (
    Clock,
    FakeApns,
    FakeApple,
    FakeMailer,
    FakeModerator,
    FakeUsers,
)
from tests.photos import MemoryPhotoStore
from tests.test_circles import _create, _invite, _join
from tests.test_finds import GNATCATCHER, PHOEBE, WREN, _feed, _feed_ids, _find, _put_ok
from tests.test_goals import _goal_ok, _goals
from tests.test_pushes import _register
from tests.tokens import TestIssuer

# Distinctive, so a scan for it can't match anything else.
ADA = "ada-0e7c4b1f"
ADA_PHONE = "a1" * 32
BO_PHONE = "b2" * 32
CY_PHONE = "c3" * 32


@pytest.fixture
def photos() -> MemoryPhotoStore:
    return MemoryPhotoStore()


@pytest.fixture
def full(
    settings: Settings, issuer: TestIssuer, clock: Clock, apns: FakeApns,
    mailer: FakeMailer, moderator: FakeModerator, users: FakeUsers, apple: FakeApple, photos: MemoryPhotoStore,
) -> Iterator[TestClient]:
    """The whole API: shared photos, pushes, reports."""
    app = create_app(
        settings, signing_key=issuer.signing_key, clock=clock,
        push_sender=apns, mailer=mailer, moderator=moderator, users=users, apple=apple,
        photos=photos,
    )
    with TestClient(app) as client:
        yield client


def _h(issuer: TestIssuer, sub: str) -> dict[str, str]:
    return issuer.headers(sub=sub)


def _delete(client: TestClient, issuer: TestIssuer, sub: str = ADA, **body: Any) -> Any:
    return client.request("DELETE", "/v1/account", headers=_h(issuer, sub), json=body or None)


def _mentions(value: Any, needle: str) -> bool:
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(_mentions(key, needle) or _mentions(item, needle) for key, item in value.items())
    if isinstance(value, (list, set, tuple, frozenset)):
        return any(_mentions(item, needle) for item in value)
    return False


def _scan(table: Any) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {"ConsistentRead": True}
    while True:
        response = table.scan(**kwargs)
        items.extend(response["Items"])
        if "LastEvaluatedKey" not in response:
            return items
        kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]


@pytest.fixture
def busy(
    full: TestClient, issuer: TestIssuer, table: Any, photos: MemoryPhotoStore, clock: Clock
) -> dict[str, Any]:
    """Ada with something of everything: circles she made (one shared, one alone), one of Bo's she is in and one of
    Cy's she left; finds automatic and shared by hand with a photo; reactions both ways; pushes, mutes,
    blocks, digests, goals, invites and reports."""
    c = full
    for sub, name in ((ADA, "Ada Lovelace"), ("bo", "Bo"), ("cy", "Cy")):
        assert c.patch("/v1/account", headers=_h(issuer, sub), json={"display_name": name}).status_code == 200
    # Cy's Old circle, which Ada joins and leaves.
    old = str(_create(c, issuer, sub="cy", name="Old")["id"])
    _join(c, issuer, old, ADA, inviter="cy")
    assert c.delete(f"/v1/circles/{old}/members/me", headers=_h(issuer, ADA)).status_code == 204
    # Ada's Sunday with Bo (joined first) and Cy; her Solo; Bo's Ridge with Ada in it.
    sunday = str(_create(c, issuer, sub=ADA, name="Sunday")["id"])
    _join(c, issuer, sunday, "bo", inviter=ADA)
    _join(c, issuer, sunday, "cy", inviter=ADA)
    solo = str(_create(c, issuer, sub=ADA, name="Solo")["id"])
    ridge = str(_create(c, issuer, sub="bo", name="Ridge")["id"])
    _join(c, issuer, ridge, ADA, inviter="bo")
    _invite(c, issuer, sunday, sub=ADA)
    # Goals: Ada's own in Sunday, and Bo's that Ada's find completes.
    adas_goal = _goal_ok(c, issuer, sunday, sub=ADA, title="Ada's Big Day", target=5)
    bos_goal = _goal_ok(c, issuer, sunday, sub="bo", title="Gnatcatcher hunt", target=1)
    # Phones.
    for sub, phone in ((ADA, ADA_PHONE), ("bo", BO_PHONE), ("cy", CY_PHONE)):
        assert _register(c, issuer, sub, phone).status_code == 204
    # Finds by Ada: automatic (a Gnatcatcher that completes Bo's goal), ordinary (buffered in Bo's digest), and shared by
    # hand with a photo.
    gnat = _put_ok(c, issuer, ADA, _find(GNATCATCHER, found_at="2026-11-01T08:00:00Z"))
    _put_ok(c, issuer, "cy", _find(WREN, found_at="2026-10-01T08:00:00Z"))
    ordinary = _put_ok(c, issuer, ADA, _find(WREN, found_at="2026-11-01T08:20:00Z"))
    card = str(uuid4())
    response = c.post(f"/v1/finds/{card}/photo", headers=_h(issuer, ADA))
    photo_key = response.json()["key"]
    photos.arrive(photo_key)
    shared = c.put(
        f"/v1/finds/{card}/card", headers=_h(issuer, ADA),
        json={"find": _find(PHOEBE), "circle_ids": [sunday], "note": "Hi", "photo": {"key": photo_key}},
    )
    assert shared.status_code == 201, shared.text
    # Reactions both ways: Bo on Ada's, Ada on Bo's (twice in the window, so one waits in a buffer).
    bos = _put_ok(c, issuer, "bo", _find(PHOEBE, found_at="2026-11-01T06:00:00Z"))
    assert c.put(f"/v1/finds/{ADA}/{gnat}/reactions/lovely", headers=_h(issuer, "bo")).status_code == 200
    assert c.put(f"/v1/finds/bo/{bos}/reactions/lovely", headers=_h(issuer, "cy")).status_code == 200
    assert c.put(f"/v1/finds/bo/{bos}/reactions/jealous", headers=_h(issuer, ADA)).status_code == 200
    clock.now += timedelta(minutes=1)
    assert c.put(f"/v1/finds/bo/{bos}/reactions/lovely", headers=_h(issuer, ADA)).status_code == 200
    # Bo's ordinary find in Ada's digest.
    _put_ok(c, issuer, "bo", _find(WREN, found_at="2026-11-01T08:30:00Z"))
    # Mutes and blocks both ways.
    assert c.put(f"/v1/friends/{ADA}/mute", headers=_h(issuer, "bo")).status_code == 204
    assert c.put(f"/v1/blocks/{ADA}", headers=_h(issuer, "cy")).status_code == 204
    assert c.put("/v1/friends/cy/mute", headers=_h(issuer, ADA)).status_code == 204
    assert c.put("/v1/blocks/bo", headers=_h(issuer, ADA)).status_code == 204
    assert c.put(f"/v1/circles/{ridge}/mute", headers=_h(issuer, ADA)).status_code == 204
    # Reports both ways.
    reported = c.post(
        "/v1/reports", headers=_h(issuer, ADA),
        json={"kind": "account", "account_id": "bo", "circle_id": sunday, "reason": "spam"},
    )
    assert reported.status_code == 201
    about = c.post(
        "/v1/reports", headers=_h(issuer, "cy"),
        json={"kind": "find", "account_id": ADA, "circle_id": sunday, "sighting_id": card, "reason": "inappropriate"},
    )
    assert about.status_code == 201
    return {
        "sunday": sunday, "solo": solo, "ridge": ridge, "old": old, "photo": photo_key,
        "bos": bos, "ordinary": ordinary, "adas_goal": adas_goal["id"], "bos_goal": bos_goal["id"],
    }


def test_deleting_an_account_leaves_nothing_behind(
    full: TestClient, issuer: TestIssuer, table: Any, busy: dict[str, Any], users: FakeUsers, apple: FakeApple,
    photos: MemoryPhotoStore,
) -> None:
    before = [item for item in _scan(table) if _mentions(item, ADA)]
    # The fixture really did leave Ada all over the table.
    assert len(before) > 40
    response = _delete(full, issuer, apple_authorization_code="c0de")
    assert response.status_code == 204, response.text
    left = [item for item in _scan(table) if _mentions(item, ADA)]
    assert left == []
    # The Cognito user, by its username, and Apple's token.
    assert users.deleted == [f"signinwithapple_{ADA}"]
    assert apple.revoked == ["c0de"]
    # Her shared photo is gone from the bucket.
    assert busy["photo"] in photos.deleted and busy["photo"] not in photos.objects


def test_a_circle_she_made_passes_to_its_longest_standing_member_and_her_solo_circle_goes(
    full: TestClient, issuer: TestIssuer, table: Any, busy: dict[str, Any]
) -> None:
    _delete(full, issuer)
    sunday = full.get(f"/v1/circles/{busy['sunday']}", headers=_h(issuer, "bo")).json()
    assert sunday["created_by"] == "bo"
    assert [member["id"] for member in sunday["members"]] == ["bo", "cy"]
    assert "Item" not in table.get_item(Key={"pk": f"CIRCLE#{busy['solo']}", "sk": "META"})
    assert table.query(KeyConditionExpression="pk = :pk", ExpressionAttributeValues={":pk": f"CIRCLE#{busy['solo']}#GOALS"})["Items"] == []
    # Bo's Ridge and Cy's Old carry on without her.
    ridge = full.get(f"/v1/circles/{busy['ridge']}", headers=_h(issuer, "bo")).json()
    assert [member["id"] for member in ridge["members"]] == ["bo"]
    assert full.get(f"/v1/circles/{busy['old']}", headers=_h(issuer, "cy")).status_code == 200


def test_the_others_carry_on(full: TestClient, issuer: TestIssuer, busy: dict[str, Any], apns: FakeApns) -> None:
    _delete(full, issuer)
    sunday = busy["sunday"]
    # Her finds are out of the feed, Bo's stay with Cy's reaction and without hers.
    ids = _feed_ids(full, issuer, sunday, "cy")
    assert busy["bos"] in ids and busy["ordinary"] not in ids
    item = next(item for item in _feed(full, issuer, sunday, "cy")["items"] if item["sighting_id"] == busy["bos"])
    assert {entry["kind"]: entry["count"] for entry in item["reactions"]} == {"lovely": 1, "jealous": 0, "together": 0}
    # Her custom goal stays with the circle, naming nobody; the one her find completed forgets which find.
    goals = {goal["id"]: goal for goal in _goals(full, issuer, sunday, "bo")}
    assert goals[busy["adas_goal"]]["created_by"] is None
    assert goals[busy["adas_goal"]]["can_delete"] is True  # Bo is Sunday's creator now.
    assert goals[busy["bos_goal"]]["created_by"]["id"] == "bo"
    # The flushes run without her.
    assert full.app.state.pushes.flush_digests() is not None  # type: ignore[attr-defined]
    assert full.app.state.reactions.flush() is not None  # type: ignore[attr-defined]
    # Bo can still use a new invite to Sunday.
    assert _invite(full, issuer, sunday, sub="bo")["token"]


def test_without_an_apple_code_or_if_apple_refuses_the_deletion_still_goes_ahead(
    full: TestClient, issuer: TestIssuer, table: Any, users: FakeUsers, apple: FakeApple
) -> None:
    full.get("/v1/account", headers=_h(issuer, ADA))
    assert _delete(full, issuer).status_code == 204
    assert apple.revoked == [] and users.deleted == [f"signinwithapple_{ADA}"]
    apple.refusing = True
    full.get("/v1/account", headers=_h(issuer, "bo"))
    assert _delete(full, issuer, sub="bo", apple_authorization_code="bad").status_code == 204
    assert users.deleted[-1] == "signinwithapple_bo"
    assert [item for item in _scan(table) if _mentions(item, "bo")] == []


def test_a_google_account_is_deleted_by_its_username(full: TestClient, issuer: TestIssuer, users: FakeUsers) -> None:
    headers = issuer.headers(sub="g-1", username="google_118")
    full.get("/v1/account", headers=headers)
    assert full.request("DELETE", "/v1/account", headers=headers).status_code == 204
    assert users.deleted == ["google_118"]


def test_deleting_again_is_harmless(full: TestClient, issuer: TestIssuer, busy: dict[str, Any], table: Any) -> None:
    assert _delete(full, issuer).status_code == 204
    assert _delete(full, issuer).status_code == 204
    assert [item for item in _scan(table) if _mentions(item, ADA)] == []


def test_the_last_member_of_a_circle_others_left_takes_it_with_her(
    full: TestClient, issuer: TestIssuer, table: Any
) -> None:
    circle = str(_create(full, issuer, sub=ADA, name="Ghost town")["id"])
    _join(full, issuer, circle, "bo", inviter=ADA)
    _put_ok(full, issuer, "bo", _find(PHOEBE))
    assert full.delete(f"/v1/circles/{circle}/members/me", headers=_h(issuer, "bo")).status_code == 204
    _delete(full, issuer)
    # Bo's old feed item went with the circle; his find itself stays his.
    assert table.query(KeyConditionExpression="pk = :pk", ExpressionAttributeValues={":pk": f"CIRCLE#{circle}#FEED"})["Items"] == []
    assert table.query(KeyConditionExpression="pk = :pk", ExpressionAttributeValues={":pk": f"CIRCLE#{circle}"})["Items"] == []
    assert [item for item in _scan(table) if _mentions(item, circle) and not str(item["sk"]).startswith("FIND#")] == []


def test_a_circle_she_left_last_and_still_names_her_goes(full: TestClient, issuer: TestIssuer, table: Any) -> None:
    circle = str(_create(full, issuer, sub=ADA, name="Empty")["id"])
    assert full.delete(f"/v1/circles/{circle}/members/me", headers=_h(issuer, ADA)).status_code == 204
    _delete(full, issuer)
    assert table.query(KeyConditionExpression="pk = :pk", ExpressionAttributeValues={":pk": f"CIRCLE#{circle}"})["Items"] == []


def test_the_deleted_accounts_last_tokens_reach_nothing_but_a_retried_deletion(
    full: TestClient, issuer: TestIssuer, table: Any, clock: Clock
) -> None:
    full.get("/v1/account", headers=_h(issuer, ADA))
    assert _delete(full, issuer).status_code == 204
    # An outbox put or a refresh still in flight with a token from before is refused, and writes nothing back.
    assert full.get("/v1/account", headers=_h(issuer, ADA)).status_code == 401
    assert full.put(f"/v1/finds/{uuid4()}", headers=_h(issuer, ADA), json=_find()).status_code == 401
    assert _delete(full, issuer).status_code == 204
    assert [item for item in _scan(table) if _mentions(item, ADA)] == []
    # Two hours on, every token of hers has long expired at Cognito; the tombstone no longer matters.
    clock.now += timedelta(hours=3)
    assert full.get("/v1/account", headers=_h(issuer, ADA)).status_code == 200


def test_deletion_needs_a_token(full: TestClient) -> None:
    assert full.delete("/v1/account").status_code == 401


# The Apple adapter, offline.


class _Response:
    def __init__(self, status_code: int, body: dict[str, Any] | None = None) -> None:
        self.status_code = status_code
        self._body = body or {}
        self.text = str(self._body)

    def json(self) -> dict[str, Any]:
        return self._body


def _apple(responses: list[_Response]) -> tuple[Any, list[tuple[str, dict[str, str]]], Any]:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    from birdjournal_api.deletion import AppleSignIn

    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    posts: list[tuple[str, dict[str, str]]] = []

    def post(url: str, data: dict[str, str]) -> _Response:
        posts.append((url, data))
        return responses.pop(0)

    secret = {"services_id": "com.example.signin", "team_id": "TEAM123456", "key_id": "KEY1234567", "private_key": pem.decode()}
    return AppleSignIn(lambda: secret, "com.matthewcelia.mybirdjournal", post), posts, key.public_key()


def test_apple_exchanges_the_code_and_revokes_the_refresh_token() -> None:
    import jwt

    apple, posts, public_key = _apple([_Response(200, {"refresh_token": "r-1", "access_token": "a-1"}), _Response(200)])
    assert apple.revoke("code-1") is True
    (token_url, token_form), (revoke_url, revoke_form) = posts
    assert token_url == "https://appleid.apple.com/auth/token"
    assert token_form["grant_type"] == "authorization_code" and token_form["code"] == "code-1"
    assert token_form["client_id"] == "com.matthewcelia.mybirdjournal"
    assert revoke_url == "https://appleid.apple.com/auth/revoke"
    assert (revoke_form["token"], revoke_form["token_type_hint"]) == ("r-1", "refresh_token")
    claims = jwt.decode(
        revoke_form["client_secret"], public_key, algorithms=["ES256"], audience="https://appleid.apple.com"
    )
    assert (claims["iss"], claims["sub"]) == ("TEAM123456", "com.matthewcelia.mybirdjournal")
    assert jwt.get_unverified_header(revoke_form["client_secret"])["kid"] == "KEY1234567"


def test_apple_refusing_the_code_revokes_nothing() -> None:
    apple, posts, _ = _apple([_Response(400, {"error": "invalid_grant"})])
    assert apple.revoke("stale") is False
    assert len(posts) == 1


def test_the_pool_id_from_the_issuer_and_the_safety_settings() -> None:
    from birdjournal_api.deletion import user_pool_id

    assert user_pool_id("https://cognito-idp.us-west-2.amazonaws.com/us-west-2_AbC123") == "us-west-2_AbC123"
    env = {
        "TABLE_NAME": "t", "COGNITO_ISSUER": "https://i", "COGNITO_CLIENT_IDS": "c", "REPORT_EMAIL": "me@example.com",
        "APPLE_SIGN_IN_SECRET_NAME": "birdjournal/apple-sign-in",
    }
    settings = Settings.from_env(env)
    assert (settings.report_email, settings.report_sender) == ("me@example.com", "me@example.com")
    assert settings.apple_sign_in_secret_name == "birdjournal/apple-sign-in"
    assert settings.apple_client_id == "com.matthewcelia.mybirdjournal"
