"""Reports and blocks (issue #71) through the API: a report of a find or an account stored and mailed to the
maintainer, who may report what, the daily cap; and what a block hides from the blocker (finds, reactions, compare,
pushes) and what it leaves alone."""

from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.pushes import PushKind
from tests.conftest import Clock, FakeApns, FakeMailer
from tests.test_circles import _create, _join
from tests.test_finds import PHOEBE, WREN, _feed, _feed_ids, _find, _put_ok
from tests.test_pushes import ADA_PHONE, BO_PHONE, CY_PHONE, _flush, _name, _register
from tests.tokens import TestIssuer


def _report(client: TestClient, issuer: TestIssuer, sub: str, **body: Any) -> Any:
    return client.post("/v1/reports", headers=issuer.headers(sub=sub), json={"reason": "inappropriate", **body})


def _block(client: TestClient, issuer: TestIssuer, sub: str, other: str) -> Any:
    return client.put(f"/v1/blocks/{other}", headers=issuer.headers(sub=sub))


def _unblock(client: TestClient, issuer: TestIssuer, sub: str, other: str) -> Any:
    return client.delete(f"/v1/blocks/{other}", headers=issuer.headers(sub=sub))


def _reports(client: TestClient) -> list[dict[str, Any]]:
    return client.app.state.reports.reports()  # type: ignore[attr-defined,no-any-return]


@pytest.fixture
def circle(client: TestClient, issuer: TestIssuer, apns: FakeApns) -> str:
    """Ada's Sunday group with Bo and Cy, every one named and with a phone."""
    circle_id = str(_create(client, issuer, sub="ada")["id"])
    _join(client, issuer, circle_id, "bo")
    _join(client, issuer, circle_id, "cy")
    for sub, name, phone in (("ada", "Ada Lovelace", ADA_PHONE), ("bo", "Bo", BO_PHONE), ("cy", "Cy", CY_PHONE)):
        _name(client, issuer, sub, name)
        assert _register(client, issuer, sub, phone).status_code == 204
    apns.clear()
    return circle_id


# Reports.


def test_a_find_reported_is_stored_and_mailed_with_what_the_reporter_saw(
    client: TestClient, issuer: TestIssuer, circle: str, mailer: FakeMailer
) -> None:
    sighting = _put_ok(client, issuer, "bo", _find(PHOEBE))
    response = _report(
        client, issuer, "ada", kind="find", account_id="bo", circle_id=circle, sighting_id=sighting,
        reason="inappropriate", details="Not a bird.",
    )
    assert response.status_code == 201, response.text
    (stored,) = _reports(client)
    assert (stored["kind"], stored["reporter"], stored["account"], stored["sighting_id"]) == ("find", "ada", "bo", sighting)
    assert stored["details"] == "Not a bird."
    assert stored["snapshot"]["common_name"] == "Black Phoebe"
    assert stored["snapshot"]["place"] == "Pasadena"
    ((subject, body),) = mailer.sent
    assert subject == "Featherguild report: a find by Bo (Inappropriate content)"
    assert "Not a bird." in body and "Black Phoebe" in body and "Sunday group" in body
    assert "Reported by: Ada Lovelace (ada)" in body
    assert "packs/us-ca-la/sayornis-nigricans.jpg" in body


def test_a_shared_cards_note_and_photo_are_in_the_report(
    client: TestClient, issuer: TestIssuer, circle: str, mailer: FakeMailer
) -> None:
    sighting = str(uuid4())
    shared = client.put(
        f"/v1/finds/{sighting}/card", headers=issuer.headers(sub="bo"),
        json={"find": _find(), "circle_ids": [circle], "note": "Look at this", "caption": "A caption"},
    )
    assert shared.status_code == 201, shared.text
    _report(client, issuer, "ada", kind="find", account_id="bo", circle_id=circle, sighting_id=sighting)
    snapshot = _reports(client)[0]["snapshot"]
    assert (snapshot["note"], snapshot["caption"]) == ("Look at this", "A caption")
    assert "Note: Look at this" in mailer.sent[0][1]


def test_an_account_reported(client: TestClient, issuer: TestIssuer, circle: str, mailer: FakeMailer) -> None:
    response = _report(client, issuer, "ada", kind="account", account_id="cy", circle_id=circle, reason="harassment")
    assert response.status_code == 201, response.text
    (stored,) = _reports(client)
    assert (stored["kind"], stored["account"], stored["reason"]) == ("account", "cy", "harassment")
    assert "sighting_id" not in stored
    assert mailer.sent[0][0] == "Featherguild report: an account by Cy (Harassment or bullying)"


def test_only_someone_sharing_the_circle_may_report(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    sighting = _put_ok(client, issuer, "bo", _find(PHOEBE))
    stranger = _report(client, issuer, "zed", kind="find", account_id="bo", circle_id=circle, sighting_id=sighting)
    assert stranger.status_code == 404
    # An account outside the circle named.
    outsider = _report(client, issuer, "ada", kind="account", account_id="zed", circle_id=circle)
    assert outsider.status_code == 404
    # A find that never reached the circle (made before Bo was in another circle with Ada) is not found either.
    elsewhere = str(_create(client, issuer, sub="bo", name="Bo's own")["id"])
    assert elsewhere
    unknown = _report(client, issuer, "ada", kind="find", account_id="bo", circle_id=circle, sighting_id=str(uuid4()))
    assert unknown.status_code == 404
    assert _reports(client) == []


def test_nobody_reports_themselves(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    assert _report(client, issuer, "ada", kind="account", account_id="ada", circle_id=circle).status_code == 422


def test_a_finds_report_names_the_find(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    assert _report(client, issuer, "ada", kind="find", account_id="bo", circle_id=circle).status_code == 422


@pytest.mark.parametrize(
    "body",
    [
        {"reason": "boring"},
        {"details": "x" * 1001},
        {"details": "bell \x07"},
        {"comment": "extra"},
    ],
)
def test_malformed_reports_are_refused(client: TestClient, issuer: TestIssuer, circle: str, body: dict[str, Any]) -> None:
    response = _report(client, issuer, "ada", kind="account", account_id="bo", circle_id=circle, **body)
    assert response.status_code == 422


def test_twenty_reports_a_day_then_429_and_again_tomorrow(
    client: TestClient, issuer: TestIssuer, circle: str, clock: Clock, mailer: FakeMailer
) -> None:
    for _ in range(20):
        assert _report(client, issuer, "ada", kind="account", account_id="bo", circle_id=circle).status_code == 201
    assert _report(client, issuer, "ada", kind="account", account_id="bo", circle_id=circle).status_code == 429
    assert len(mailer.sent) == 20
    from datetime import timedelta

    clock.now += timedelta(days=1)
    assert _report(client, issuer, "ada", kind="account", account_id="bo", circle_id=circle).status_code == 201


def test_a_failing_mail_never_fails_the_report(
    client: TestClient, issuer: TestIssuer, circle: str, mailer: FakeMailer
) -> None:
    mailer.failing = True
    assert _report(client, issuer, "ada", kind="account", account_id="bo", circle_id=circle).status_code == 201
    assert len(_reports(client)) == 1


def test_reports_need_a_token(client: TestClient, circle: str) -> None:
    response = client.post("/v1/reports", json={"kind": "account", "account_id": "bo", "circle_id": circle, "reason": "spam"})
    assert response.status_code == 401


# Blocks.


def test_a_blocked_accounts_finds_leave_the_blockers_feed_only(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    bos = _put_ok(client, issuer, "bo", _find(PHOEBE))
    cys = _put_ok(client, issuer, "cy", _find(WREN))
    assert _block(client, issuer, "ada", "bo").status_code == 204
    assert _feed_ids(client, issuer, circle, "ada") == [cys]
    # Cy still sees Bo's find: a block is the blocker's.
    assert set(_feed_ids(client, issuer, circle, "cy")) == {bos, cys}
    # And Bo still sees Ada's finds (the block hides Bo from Ada, not Ada from Bo).
    adas = _put_ok(client, issuer, "ada", _find(PHOEBE, found_at="2026-11-01T09:00:00Z"))
    assert adas in _feed_ids(client, issuer, circle, "bo")
    assert _unblock(client, issuer, "ada", "bo").status_code == 204
    assert bos in _feed_ids(client, issuer, circle, "ada")


def test_a_blocked_accounts_reactions_leave_the_blockers_counts(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    adas = _put_ok(client, issuer, "ada", _find(PHOEBE))
    for sub in ("bo", "cy"):
        assert client.put(f"/v1/finds/ada/{adas}/reactions/lovely", headers=issuer.headers(sub=sub)).status_code == 200
    _block(client, issuer, "ada", "bo")
    (item,) = _feed(client, issuer, circle, "ada")["items"]
    assert next(entry for entry in item["reactions"] if entry["kind"] == "lovely")["count"] == 1
    # Cy still counts Bo's.
    (item,) = _feed(client, issuer, circle, "cy")["items"]
    assert next(entry for entry in item["reactions"] if entry["kind"] == "lovely")["count"] == 2


def test_a_blocked_accounts_reactions_never_push_the_blocker(
    client: TestClient, issuer: TestIssuer, circle: str, apns: FakeApns
) -> None:
    adas = _put_ok(client, issuer, "ada", _find(PHOEBE))
    _block(client, issuer, "ada", "bo")
    apns.clear()
    client.put(f"/v1/finds/ada/{adas}/reactions/lovely", headers=issuer.headers(sub="bo"))
    assert [push for push in apns.to(ADA_PHONE) if push.kind is PushKind.REACTION] == []
    client.put(f"/v1/finds/ada/{adas}/reactions/lovely", headers=issuer.headers(sub="cy"))
    assert [push.title for push in apns.to(ADA_PHONE) if push.kind is PushKind.REACTION] == ["Cy reacted to your Black Phoebe"]


def test_a_blocked_accounts_finds_never_push_the_blocker(
    client: TestClient, issuer: TestIssuer, circle: str, apns: FakeApns
) -> None:
    _block(client, issuer, "ada", "bo")
    _put_ok(client, issuer, "bo", _find(PHOEBE, legendary=True))
    _put_ok(client, issuer, "bo", _find(WREN))
    assert apns.to(ADA_PHONE) == []
    # Cy hears of both as usual (each the circle's first of its species).
    assert [push.kind for push in apns.to(CY_PHONE)] == [PushKind.NOTABLE, PushKind.NOTABLE]


def test_a_block_after_buffering_drops_the_digest(
    client: TestClient, issuer: TestIssuer, circle: str, apns: FakeApns, clock: Clock
) -> None:
    from datetime import timedelta

    # Bo's circle-first Wren is notable; a second Wren is ordinary and waits in Ada's digest.
    _put_ok(client, issuer, "cy", _find(WREN, found_at="2026-10-01T08:00:00Z"))
    apns.clear()
    _put_ok(client, issuer, "bo", _find(WREN))
    # Buffered for Ada's digest, with a silent refresh.
    assert [push.kind for push in apns.to(ADA_PHONE)] == [PushKind.REFRESH]
    _block(client, issuer, "ada", "bo")
    apns.clear()
    clock.now += timedelta(minutes=15)
    assert _flush(client).dropped == 1
    assert [push for push in apns.to(ADA_PHONE) if push.kind is PushKind.DIGEST] == []


def test_compare_with_a_blocked_friend_is_not_found(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    _put_ok(client, issuer, "bo", _find(PHOEBE))
    assert client.get("/v1/friends/bo/compare", headers=issuer.headers(sub="ada")).status_code == 200
    _block(client, issuer, "ada", "bo")
    assert client.get("/v1/friends/bo/compare", headers=issuer.headers(sub="ada")).status_code == 404


def test_blocks_are_listed_with_names(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    _block(client, issuer, "ada", "bo")
    _block(client, issuer, "ada", "cy")
    response = client.get("/v1/blocks", headers=issuer.headers(sub="ada"))
    assert response.json() == {"accounts": [{"id": "bo", "display_name": "Bo"}, {"id": "cy", "display_name": "Cy"}]}
    assert client.get("/v1/blocks", headers=issuer.headers(sub="bo")).json() == {"accounts": []}


def test_only_someone_sharing_a_circle_can_be_blocked_and_unblocking_always_works(
    client: TestClient, issuer: TestIssuer, circle: str
) -> None:
    assert _block(client, issuer, "ada", "zed").status_code == 404
    assert _block(client, issuer, "ada", "ada").status_code == 422
    _block(client, issuer, "ada", "bo")
    client.delete(f"/v1/circles/{circle}/members/me", headers=issuer.headers(sub="bo"))
    # Bo left, and Ada can still unblock.
    assert _unblock(client, issuer, "ada", "bo").status_code == 204
    assert _unblock(client, issuer, "ada", "nobody").status_code == 204
    assert client.get("/v1/blocks", headers=issuer.headers(sub="ada")).json() == {"accounts": []}


def test_a_block_does_not_show_in_mutes(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    _block(client, issuer, "ada", "bo")
    assert client.get("/v1/mutes", headers=issuer.headers(sub="ada")).json() == {"circles": [], "friends": []}
