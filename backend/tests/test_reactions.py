"""Reactions and Compare birds (issue #64) through the API with a fake APNs: the fixed kinds, put and delete, who may
react, counts on feed items, the owner's push collapsed per find within 10 minutes, the delete cascade, and the
compare query."""

from datetime import timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.handler import make_handler
from birdjournal_api.pushes import PushKind
from birdjournal_api.reactions import ReactionKind, reaction_words
from tests.conftest import Clock, FakeApns
from tests.test_circles import _create, _join
from tests.test_finds import GNATCATCHER, PHOEBE, WREN, _feed, _find, _put_ok
from tests.test_pushes import ADA_PHONE, BO_PHONE, CY_PHONE, _name, _register
from tests.tokens import TestIssuer


def _react(client: TestClient, issuer: TestIssuer, sub: str, owner: str, sighting: str, kind: str = "lovely") -> Any:
    return client.put(f"/v1/finds/{owner}/{sighting}/reactions/{kind}", headers=issuer.headers(sub=sub))


def _unreact(client: TestClient, issuer: TestIssuer, sub: str, owner: str, sighting: str, kind: str = "lovely") -> Any:
    return client.delete(f"/v1/finds/{owner}/{sighting}/reactions/{kind}", headers=issuer.headers(sub=sub))


def _counts(body: dict[str, Any]) -> dict[str, tuple[int, bool]]:
    return {entry["kind"]: (entry["count"], entry["mine"]) for entry in body["reactions"]}


def _flush(client: TestClient) -> Any:
    return client.app.state.reactions.flush()  # type: ignore[attr-defined]


def _reaction_alerts(apns: FakeApns, token: str) -> list[Any]:
    return [push for push in apns.to(token) if push.kind is PushKind.REACTION]


@pytest.fixture
def circle(client: TestClient, issuer: TestIssuer, apns: FakeApns) -> str:
    """Ada's Sunday group with Bo and Cy, every one named and with a phone."""
    circle_id = str(_create(client, issuer, sub="ada")["id"])
    _join(client, issuer, circle_id, "bo")
    _join(client, issuer, circle_id, "cy")
    for sub, name, phone in (("ada", "Ada Lovelace", ADA_PHONE), ("bo", "Bo", BO_PHONE), ("cy", "Cy", CY_PHONE)):
        _name(client, issuer, sub, name)
        assert _register(client, issuer, sub, phone).status_code == 204
    return circle_id


@pytest.fixture
def find(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> str:
    """Ada's Black Phoebe in the circle."""
    sighting = _put_ok(client, issuer, "ada", _find(PHOEBE))
    apns.clear()
    return sighting


# Put and delete.


def test_a_friend_reacts_and_the_counts_come_back(client: TestClient, issuer: TestIssuer, find: str, table: Any) -> None:
    response = _react(client, issuer, "bo", "ada", find)
    assert response.status_code == 200, response.text
    assert [entry["kind"] for entry in response.json()["reactions"]] == ["lovely", "jealous", "together"]
    assert _counts(response.json()) == {"lovely": (1, True), "jealous": (0, False), "together": (0, False)}
    assert "Item" in table.get_item(Key={"pk": f"FIND#ada#{find}", "sk": "REACTION#bo#lovely"})
    # Under the reactor too, for account deletion (#71).
    assert "Item" in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"REACTION#ada#{find}#lovely"})


def test_reacting_twice_with_one_kind_counts_once(client: TestClient, issuer: TestIssuer, find: str) -> None:
    _react(client, issuer, "bo", "ada", find)
    assert _counts(_react(client, issuer, "bo", "ada", find).json())["lovely"] == (1, True)


def test_one_friend_may_give_several_kinds(client: TestClient, issuer: TestIssuer, find: str) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    _react(client, issuer, "cy", "ada", find, "lovely")
    body = _react(client, issuer, "bo", "ada", find, "together").json()
    assert _counts(body) == {"lovely": (2, True), "jealous": (0, False), "together": (1, True)}


def test_a_reaction_is_taken_back(client: TestClient, issuer: TestIssuer, find: str, table: Any) -> None:
    _react(client, issuer, "bo", "ada", find, "jealous")
    response = _unreact(client, issuer, "bo", "ada", find, "jealous")
    assert response.status_code == 200
    assert _counts(response.json())["jealous"] == (0, False)
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"REACTION#ada#{find}#jealous"})
    # Taking back one that isn't there is no error.
    assert _unreact(client, issuer, "bo", "ada", find, "jealous").status_code == 200


@pytest.mark.parametrize("kind", ["like", "LOVELY", "comment", "heart"])
def test_only_the_fixed_kinds(client: TestClient, issuer: TestIssuer, find: str, kind: str) -> None:
    assert _react(client, issuer, "bo", "ada", find, kind).status_code == 422


def test_reactions_carry_no_comment(client: TestClient, issuer: TestIssuer, find: str) -> None:
    # There is no body to send: whatever comes is ignored, and nothing but the kind is stored.
    response = client.put(
        f"/v1/finds/ada/{find}/reactions/lovely", headers=issuer.headers(sub="bo"), json={"comment": "Wow!"}
    )
    assert response.status_code == 200
    assert set(response.json()) == {"reactions"}


def test_the_owner_cannot_react_to_their_own_find(client: TestClient, issuer: TestIssuer, find: str) -> None:
    assert _react(client, issuer, "ada", "ada", find).status_code == 422


def test_only_someone_sharing_a_circle_the_find_went_to_may_react(
    client: TestClient, issuer: TestIssuer, find: str, circle: str
) -> None:
    # A stranger, and a member of another of Ada's circles that the find never went to.
    assert _react(client, issuer, "zed", "ada", find).status_code == 404
    other = str(_create(client, issuer, sub="ada", name="Weekday walkers")["id"])
    _join(client, issuer, other, "dee")
    assert _react(client, issuer, "dee", "ada", find).status_code == 404
    # Bo leaves the circle: no more reacting.
    _react(client, issuer, "bo", "ada", find, "jealous")
    assert client.delete(f"/v1/circles/{circle}/members/me", headers=issuer.headers(sub="bo")).status_code == 204
    assert _react(client, issuer, "bo", "ada", find).status_code == 404
    # Taking one back still works, like unmuting.
    response = _unreact(client, issuer, "bo", "ada", find, "jealous")
    assert response.status_code == 200
    assert _counts(response.json())["jealous"] == (0, False)


def test_a_put_cut_short_is_finished_by_its_retry(client: TestClient, issuer: TestIssuer, find: str, table: Any) -> None:
    _react(client, issuer, "bo", "ada", find)
    # As if the Lambda stopped between the reaction and its copy under the reactor.
    table.delete_item(Key={"pk": "ACCOUNT#bo", "sk": f"REACTION#ada#{find}#lovely"})
    assert _react(client, issuer, "bo", "ada", find).status_code == 200
    assert "Item" in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"REACTION#ada#{find}#lovely"})


def test_an_unknown_find_or_bad_id_is_refused(client: TestClient, issuer: TestIssuer, find: str) -> None:
    assert _react(client, issuer, "bo", "ada", "00000000-0000-4000-8000-000000000000").status_code == 404
    assert _react(client, issuer, "bo", "ada", "not-a-uuid").status_code == 422
    assert client.put(f"/v1/finds/ada/{find}/reactions/lovely").status_code == 401


# Counts on feed items.


def test_feed_items_show_the_counts_and_the_reader_s_own(
    client: TestClient, issuer: TestIssuer, find: str, circle: str
) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    _react(client, issuer, "cy", "ada", find, "lovely")
    _react(client, issuer, "cy", "ada", find, "jealous")
    other = _put_ok(client, issuer, "bo", _find(WREN))
    by_bo = {item["sighting_id"]: item for item in _feed(client, issuer, circle, "bo")["items"]}
    assert _counts(by_bo[find]) == {"lovely": (2, True), "jealous": (1, False), "together": (0, False)}
    assert _counts(by_bo[other]) == {"lovely": (0, False), "jealous": (0, False), "together": (0, False)}
    by_ada = {item["sighting_id"]: item for item in _feed(client, issuer, circle, "ada")["items"]}
    assert _counts(by_ada[find]) == {"lovely": (2, False), "jealous": (1, False), "together": (0, False)}


def test_a_deleted_find_takes_its_reactions(client: TestClient, issuer: TestIssuer, find: str, table: Any) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    _react(client, issuer, "cy", "ada", find, "together")
    assert client.delete(f"/v1/finds/{find}", headers=issuer.headers(sub="ada")).status_code == 204
    assert table.query(KeyConditionExpression="pk = :pk", ExpressionAttributeValues={":pk": f"FIND#ada#{find}"})["Items"] == []
    for sub, kind in (("bo", "lovely"), ("cy", "together")):
        assert "Item" not in table.get_item(Key={"pk": f"ACCOUNT#{sub}", "sk": f"REACTION#ada#{find}#{kind}"})
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"REACTIONPUSH#{find}"})
    assert _react(client, issuer, "bo", "ada", find).status_code == 404


# The owner's push, collapsed per find within 10 minutes.


def test_the_first_reaction_pushes_the_owner_at_once(client: TestClient, issuer: TestIssuer, apns: FakeApns, find: str) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    (push,) = apns.to(ADA_PHONE)
    assert push.kind is PushKind.REACTION
    payload = push.payload()
    assert payload["aps"]["alert"] == {"title": "Bo reacted to your Black Phoebe", "body": "Lovely find"}
    assert payload["aps"]["thread-id"] == f"find-{find}"
    assert payload["sighting_id"] == find
    assert push.collapse_id == f"reaction-{find}"
    # Nobody else hears of it.
    assert apns.to(BO_PHONE) == [] and apns.to(CY_PHONE) == []


def test_reactions_within_ten_minutes_collapse_into_one_push(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str
) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    clock.now += timedelta(minutes=3)
    _react(client, issuer, "cy", "ada", find, "jealous")
    _react(client, issuer, "bo", "ada", find, "together")
    assert len(apns.to(ADA_PHONE)) == 1
    clock.now += timedelta(minutes=5)
    assert _flush(client).waiting == 1
    assert len(apns.to(ADA_PHONE)) == 1
    clock.now += timedelta(minutes=2)
    report = _flush(client)
    assert (report.sent, report.waiting) == (1, 0)
    first, second = apns.to(ADA_PHONE)
    # It replaces the first on the phone, so it names the first's reaction too.
    assert second.payload()["aps"]["alert"] == {
        "title": "Bo and Cy reacted to your Black Phoebe", "body": "Lovely find, Jealous! Let's go together",
    }
    # It replaces the first on the phone.
    assert first.collapse_id == second.collapse_id
    # Nothing is left to send.
    clock.now += timedelta(minutes=30)
    assert _flush(client).sent == 0


def test_a_reaction_after_the_window_pushes_at_once_with_anything_waiting(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str
) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    clock.now += timedelta(minutes=4)
    _react(client, issuer, "cy", "ada", find, "lovely")
    clock.now += timedelta(minutes=7)
    # Before the flush ran: Bo's second goes now, with Cy's that waited.
    _react(client, issuer, "bo", "ada", find, "jealous")
    pushes = _reaction_alerts(apns, ADA_PHONE)
    assert len(pushes) == 2
    assert pushes[1].payload()["aps"]["alert"] == {
        "title": "Bo and Cy reacted to your Black Phoebe", "body": "Lovely find, Jealous!",
    }
    assert _flush(client).sent == 0


def test_a_reaction_taken_back_before_the_flush_is_left_out(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str
) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    _react(client, issuer, "cy", "ada", find, "jealous")
    _unreact(client, issuer, "cy", "ada", find, "jealous")
    clock.now += timedelta(minutes=15)
    report = _flush(client)
    assert (report.sent, report.dropped) == (0, 1)
    assert len(apns.to(ADA_PHONE)) == 1


def test_windows_are_per_find(client: TestClient, issuer: TestIssuer, apns: FakeApns, find: str) -> None:
    other = _put_ok(client, issuer, "ada", _find(GNATCATCHER))
    apns.clear()
    _react(client, issuer, "bo", "ada", find)
    _react(client, issuer, "bo", "ada", other)
    titles = [push.title for push in _reaction_alerts(apns, ADA_PHONE)]
    assert titles == ["Bo reacted to your Black Phoebe", "Bo reacted to your California Gnatcatcher"]


def test_a_repeated_reaction_pushes_nothing(client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str) -> None:
    _react(client, issuer, "bo", "ada", find)
    clock.now += timedelta(minutes=20)
    _react(client, issuer, "bo", "ada", find)
    assert len(apns.to(ADA_PHONE)) == 1


def test_a_muted_friend_s_reactions_never_push(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str, circle: str
) -> None:
    assert client.put("/v1/friends/bo/mute", headers=issuer.headers(sub="ada")).status_code == 204
    _react(client, issuer, "bo", "ada", find)
    assert apns.to(ADA_PHONE) == []
    # A mute of the only circle the find went to holds for everyone.
    assert client.put(f"/v1/circles/{circle}/mute", headers=issuer.headers(sub="ada")).status_code == 204
    _react(client, issuer, "cy", "ada", find)
    assert apns.to(ADA_PHONE) == []


def test_a_mute_after_buffering_drops_the_waiting_push(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str
) -> None:
    _react(client, issuer, "bo", "ada", find, "lovely")
    _react(client, issuer, "cy", "ada", find, "lovely")
    client.put("/v1/friends/cy/mute", headers=issuer.headers(sub="ada"))
    clock.now += timedelta(minutes=15)
    assert _flush(client).dropped == 1
    assert len(apns.to(ADA_PHONE)) == 1


def test_an_owner_without_a_phone_gets_nothing_and_the_next_reaction_pushes(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, find: str
) -> None:
    client.delete(f"/v1/account/devices/{ADA_PHONE}", headers=issuer.headers(sub="ada"))
    _react(client, issuer, "bo", "ada", find)
    assert apns.sent == []
    _register(client, issuer, "ada", ADA_PHONE)
    _react(client, issuer, "cy", "ada", find)
    (push,) = apns.to(ADA_PHONE)
    # Bo's went to no phone and isn't sent again.
    assert push.title == "Cy reacted to your Black Phoebe"


def test_a_find_deleted_while_waiting_drops_its_push(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str, table: Any
) -> None:
    _react(client, issuer, "bo", "ada", find)
    _react(client, issuer, "cy", "ada", find)
    client.delete(f"/v1/finds/{find}", headers=issuer.headers(sub="ada"))
    assert "Item" not in table.get_item(Key={"pk": "REACTIONS", "sk": f"ada#{find}"})
    clock.now += timedelta(minutes=15)
    assert _flush(client).sent == 0


def test_the_schedule_flushes_reactions_with_the_digests(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, find: str
) -> None:
    handler = make_handler(client.app)  # type: ignore[arg-type]
    _react(client, issuer, "bo", "ada", find)
    _react(client, issuer, "cy", "ada", find)
    clock.now += timedelta(minutes=10)
    report = handler({"birdjournal_job": "flush_digests"}, None)
    assert report["reactions"] == {"sent": 1, "waiting": 0, "dropped": 0}
    assert len(_reaction_alerts(apns, ADA_PHONE)) == 2


def test_a_failing_apns_never_fails_the_reaction(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, find: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    def broken(*_: Any) -> Any:
        raise RuntimeError("APNs is down")

    monkeypatch.setattr(apns, "send", broken)
    assert _react(client, issuer, "bo", "ada", find).status_code == 200


def test_the_words() -> None:
    lovely, jealous, together = ReactionKind.LOVELY, ReactionKind.JEALOUS, ReactionKind.TOGETHER
    assert reaction_words(["Bo"], "Oak Titmouse", [lovely]) == ("Bo reacted to your Oak Titmouse", "Lovely find")
    assert reaction_words(["Bo", "Cy"], "Oak Titmouse", [together, lovely])[1] == "Lovely find, Let's go together"
    assert reaction_words(["Bo", "Cy", "Di"], "Oak Titmouse", [jealous])[0] == "Bo and 2 others reacted to your Oak Titmouse"
    assert reaction_words([], "Oak Titmouse", [jealous])[0] == "A friend reacted to your Oak Titmouse"


# Compare birds.


def _compare(client: TestClient, issuer: TestIssuer, sub: str, friend: str) -> Any:
    return client.get(f"/v1/friends/{friend}/compare", headers=issuer.headers(sub=sub))


def test_compare_gives_each_species_with_the_friend_s_best_method(
    client: TestClient, issuer: TestIssuer, circle: str
) -> None:
    _put_ok(client, issuer, "bo", _find(PHOEBE, method="heard"))
    _put_ok(client, issuer, "bo", _find(PHOEBE, method="seen", found_at="2026-10-30T07:00:00Z"))
    _put_ok(client, issuer, "bo", _find(PHOEBE, method="heard", found_at="2026-10-31T07:00:00Z"))
    _put_ok(client, issuer, "bo", _find(WREN, method="heard"))
    response = _compare(client, issuer, "ada", "bo")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["friend"] == {"id": "bo", "display_name": "Bo"}
    assert [(entry["common_name"], entry["method"]) for entry in body["species"]] == [
        ("Black Phoebe", "seen"), ("Northern House Wren", "heard"),
    ]
    assert body["species"][0]["scientific_name"] == "Sayornis nigricans"
    assert body["species"][0]["species_id"] == PHOEBE["species_id"]


def test_compare_reads_only_finds_in_circles_the_two_share(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    # Bo's own circle with Dee, which Ada isn't in: what Bo found there stays there.
    private = str(_create(client, issuer, sub="dee", name="Dee's walks")["id"])
    _join(client, issuer, private, "bo", inviter="dee")
    assert client.delete(f"/v1/circles/{circle}/members/me", headers=issuer.headers(sub="bo")).status_code == 204
    _put_ok(client, issuer, "bo", _find(GNATCATCHER, method="seen"))
    # Bo comes back to Ada's circle: the Gnatcatcher went only to Dee's (no backfill), so Ada doesn't see it.
    invite = client.post(f"/v1/circles/{circle}/invites", headers=issuer.headers(sub="ada")).json()
    client.post(f"/v1/invites/{invite['token']}/accept", headers=issuer.headers(sub="bo"))
    _put_ok(client, issuer, "bo", _find(WREN))
    names = [entry["common_name"] for entry in _compare(client, issuer, "ada", "bo").json()["species"]]
    assert names == ["Northern House Wren"]
    assert [entry["common_name"] for entry in _compare(client, issuer, "dee", "bo").json()["species"]] == [
        "California Gnatcatcher", "Northern House Wren",
    ]


def test_compare_needs_a_shared_circle(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    _put_ok(client, issuer, "bo", _find(PHOEBE))
    assert _compare(client, issuer, "zed", "bo").status_code == 404
    assert _compare(client, issuer, "ada", "nobody").status_code == 404
    assert _compare(client, issuer, "ada", "ada").status_code == 422
    assert client.get("/v1/friends/bo/compare").status_code == 401


def test_compare_with_a_friend_who_found_nothing_is_empty(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    assert _compare(client, issuer, "ada", "cy").json()["species"] == []


def test_compare_leaves_out_deleted_finds(client: TestClient, issuer: TestIssuer, circle: str) -> None:
    sighting = _put_ok(client, issuer, "bo", _find(PHOEBE, method="seen"))
    _put_ok(client, issuer, "bo", _find(PHOEBE, method="heard", found_at="2026-10-31T07:00:00Z"))
    client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="bo"))
    assert [(e["common_name"], e["method"]) for e in _compare(client, issuer, "ada", "bo").json()["species"]] == [
        ("Black Phoebe", "heard"),
    ]
