"""Circles (issue #61): create, invite, accept, expiry, the cap, leaving, removal by the creator, several circles."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from tests.conftest import Clock
from tests.tokens import TestIssuer


def _create(client: TestClient, issuer: TestIssuer, sub: str = "ada", name: str = "Sunday group") -> dict[str, Any]:
    response = client.post(
        "/v1/circles", headers=issuer.headers(sub=sub), json={"name": name, "time_zone": "America/Los_Angeles"}
    )
    assert response.status_code == 201, response.text
    return response.json()


def _invite(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str = "ada") -> dict[str, Any]:
    response = client.post(f"/v1/circles/{circle_id}/invites", headers=issuer.headers(sub=sub))
    assert response.status_code == 201, response.text
    return response.json()


def _accept(client: TestClient, issuer: TestIssuer, token: str, sub: str) -> Any:
    return client.post(f"/v1/invites/{token}/accept", headers=issuer.headers(sub=sub))


def _join(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str, inviter: str = "ada") -> None:
    token = _invite(client, issuer, circle_id, sub=inviter)["token"]
    response = _accept(client, issuer, token, sub)
    assert response.status_code == 200, response.text


def _member_ids(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str = "ada") -> list[str]:
    response = client.get(f"/v1/circles/{circle_id}", headers=issuer.headers(sub=sub))
    assert response.status_code == 200, response.text
    return [member["id"] for member in response.json()["members"]]


def _circle_ids(client: TestClient, issuer: TestIssuer, sub: str) -> list[str]:
    return [circle["id"] for circle in client.get("/v1/circles", headers=issuer.headers(sub=sub)).json()["circles"]]


# Create.


def test_creating_a_circle_makes_the_creator_its_only_member(client: TestClient, issuer: TestIssuer) -> None:
    client.patch("/v1/account", headers=issuer.headers(sub="ada"), json={"display_name": "Ada"})
    circle = _create(client, issuer)
    assert circle["name"] == "Sunday group"
    assert circle["created_by"] == "ada"
    assert circle["is_creator"] is True
    assert circle["time_zone"] == "America/Los_Angeles"
    assert circle["member_count"] == 1
    assert circle["created_at"] == "2026-11-01T09:30:00Z"
    assert circle["members"] == [
        {"id": "ada", "display_name": "Ada", "joined_at": "2026-11-01T09:30:00Z", "is_creator": True}
    ]


def test_a_new_circle_is_listed(client: TestClient, issuer: TestIssuer) -> None:
    assert client.get("/v1/circles", headers=issuer.headers(sub="ada")).json() == {"circles": []}
    circle = _create(client, issuer)
    listed = client.get("/v1/circles", headers=issuer.headers(sub="ada")).json()["circles"]
    assert [(entry["id"], entry["name"], entry["member_count"]) for entry in listed] == [
        (circle["id"], "Sunday group", 1)
    ]


def test_the_name_is_trimmed(client: TestClient, issuer: TestIssuer) -> None:
    assert _create(client, issuer, name="  Family  ")["name"] == "Family"


@pytest.mark.parametrize("name", ["", "   ", "x" * 41, "tab\there"])
def test_a_blank_long_or_control_character_name_is_refused(
    client: TestClient, issuer: TestIssuer, name: str
) -> None:
    response = client.post("/v1/circles", headers=issuer.headers(), json={"name": name})
    assert response.status_code == 422
    assert client.get("/v1/circles", headers=issuer.headers()).json() == {"circles": []}


def test_an_unknown_time_zone_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    response = client.post("/v1/circles", headers=issuer.headers(), json={"name": "X", "time_zone": "Mars/Olympus"})
    assert response.status_code == 422


def test_the_time_zone_defaults_to_utc(client: TestClient, issuer: TestIssuer) -> None:
    response = client.post("/v1/circles", headers=issuer.headers(), json={"name": "X"})
    assert response.json()["time_zone"] == "UTC"


def test_circles_need_a_valid_token(client: TestClient, issuer: TestIssuer) -> None:
    assert client.get("/v1/circles").status_code == 401
    assert client.post("/v1/circles", json={"name": "X"}).status_code == 401
    assert client.post("/v1/circles", headers=issuer.headers(token_use="id"), json={"name": "X"}).status_code == 401


def test_a_circle_is_hidden_from_non_members(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    response = client.get(f"/v1/circles/{circle['id']}", headers=issuer.headers(sub="stranger"))
    assert response.status_code == 404
    assert client.get("/v1/circles/no-such-circle", headers=issuer.headers(sub="ada")).status_code == 404


# Invite.


def test_any_member_can_invite_with_a_link_that_expires_in_seven_days(
    client: TestClient, issuer: TestIssuer
) -> None:
    circle = _create(client, issuer)
    invite = _invite(client, issuer, circle["id"])
    assert invite["url"] == f"https://featherguild.matthewcelia.com/i/{invite['token']}"
    assert invite["expires_at"] == "2026-11-08T09:30:00Z"
    assert len(invite["token"]) >= 22
    _join(client, issuer, circle["id"], "bea")
    # Bea, not the creator, invites Cy.
    _join(client, issuer, circle["id"], "cy", inviter="bea")
    assert _member_ids(client, issuer, circle["id"]) == ["ada", "bea", "cy"]


def test_each_invite_has_its_own_token(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    assert _invite(client, issuer, circle["id"])["token"] != _invite(client, issuer, circle["id"])["token"]


def test_a_non_member_cannot_invite(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    response = client.post(f"/v1/circles/{circle['id']}/invites", headers=issuer.headers(sub="stranger"))
    assert response.status_code == 404


def test_the_invite_preview_names_the_circle_and_who_invited(client: TestClient, issuer: TestIssuer) -> None:
    client.patch("/v1/account", headers=issuer.headers(sub="ada"), json={"display_name": "Ada"})
    circle = _create(client, issuer)
    invite = _invite(client, issuer, circle["id"])
    preview = client.get(f"/v1/invites/{invite['token']}", headers=issuer.headers(sub="bea"))
    assert preview.status_code == 200
    body = preview.json()
    assert body["circle"]["name"] == "Sunday group"
    assert body["circle"]["member_count"] == 1
    assert body["invited_by"] == "Ada"
    assert body["expires_at"] == "2026-11-08T09:30:00Z"
    assert body["already_member"] is False
    # Previewing joins nothing.
    assert _member_ids(client, issuer, circle["id"]) == ["ada"]


def test_an_unknown_invite_is_not_found(client: TestClient, issuer: TestIssuer) -> None:
    assert client.get("/v1/invites/nope", headers=issuer.headers(sub="bea")).status_code == 404
    assert _accept(client, issuer, "nope", "bea").status_code == 404


# Accept.


def test_accepting_an_invite_joins_the_circle(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    client.patch("/v1/account", headers=issuer.headers(sub="bea"), json={"display_name": "Bea"})
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    clock.now += timedelta(hours=2)
    response = _accept(client, issuer, token, "bea")
    assert response.status_code == 200
    joined = response.json()
    assert joined["id"] == circle["id"]
    assert joined["is_creator"] is False
    assert joined["member_count"] == 2
    assert joined["members"][1] == {
        "id": "bea",
        "display_name": "Bea",
        "joined_at": "2026-11-01T11:30:00Z",
        "is_creator": False,
    }
    assert _circle_ids(client, issuer, "bea") == [circle["id"]]


def test_one_link_lets_several_friends_join(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    for friend in ("bea", "cy", "dot"):
        assert _accept(client, issuer, token, friend).status_code == 200
    assert _member_ids(client, issuer, circle["id"]) == ["ada", "bea", "cy", "dot"]


def test_accepting_twice_changes_nothing(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    _accept(client, issuer, token, "bea")
    again = _accept(client, issuer, token, "bea")
    assert again.status_code == 200
    assert again.json()["member_count"] == 2
    assert _member_ids(client, issuer, circle["id"]) == ["ada", "bea"]
    preview = client.get(f"/v1/invites/{token}", headers=issuer.headers(sub="bea")).json()
    assert preview["already_member"] is True


def test_the_creator_opening_their_own_link_changes_nothing(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    assert _accept(client, issuer, token, "ada").json()["member_count"] == 1


# Expiry.


def test_an_invite_works_until_seven_days_have_passed(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    clock.now += timedelta(days=7) - timedelta(seconds=1)
    assert _accept(client, issuer, token, "bea").status_code == 200


def test_an_expired_invite_is_refused(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    clock.now += timedelta(days=7)
    preview = client.get(f"/v1/invites/{token}", headers=issuer.headers(sub="bea"))
    assert preview.status_code == 410
    assert preview.json()["detail"] == "invite_expired"
    response = _accept(client, issuer, token, "bea")
    assert response.status_code == 410
    assert _member_ids(client, issuer, circle["id"]) == ["ada"]
    assert _circle_ids(client, issuer, "bea") == []


def test_an_invite_is_kept_for_dynamodb_to_expire_a_month_after_it_lapses(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    item = table.get_item(Key={"pk": f"INVITE#{token}", "sk": "INVITE"})["Item"]
    # The expiry, 2026-11-08T09:30Z, plus 30 days, in epoch seconds.
    assert int(item["ttl"]) == int(datetime(2026, 12, 8, 9, 30, tzinfo=UTC).timestamp())
    assert item["circle_id"] == circle["id"]


# The cap.


def test_the_twenty_first_member_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    for number in range(2, 21):
        assert _accept(client, issuer, token, f"friend-{number}").status_code == 200
    assert len(_member_ids(client, issuer, circle["id"])) == 20
    refused = _accept(client, issuer, token, "friend-21")
    assert refused.status_code == 409
    assert refused.json()["detail"] == "circle_full"
    assert len(_member_ids(client, issuer, circle["id"])) == 20
    assert _circle_ids(client, issuer, "friend-21") == []
    # A place opens when someone leaves.
    client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="friend-5"))
    assert _accept(client, issuer, token, "friend-21").status_code == 200
    listed = client.get("/v1/circles", headers=issuer.headers(sub="ada")).json()["circles"]
    assert listed[0]["member_count"] == 20


# Leaving.


def test_a_member_can_leave(client: TestClient, issuer: TestIssuer, table: Any, clock: Clock) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bea")
    clock.now += timedelta(days=1)
    response = client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="bea"))
    assert response.status_code == 204
    assert _member_ids(client, issuer, circle["id"]) == ["ada"]
    assert _circle_ids(client, issuer, "bea") == []
    assert client.get(f"/v1/circles/{circle['id']}", headers=issuer.headers(sub="bea")).status_code == 404
    # Members by circle keep joined and left times.
    member = table.get_item(Key={"pk": f"CIRCLE#{circle['id']}", "sk": "MEMBER#bea"})["Item"]
    assert member["joined_at"] == "2026-11-01T09:30:00+00:00"
    assert member["left_at"] == "2026-11-02T09:30:00+00:00"
    assert "removed_at" not in member


def test_leaving_a_circle_you_are_not_in_is_not_found(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    response = client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="stranger"))
    assert response.status_code == 404
    _join(client, issuer, circle["id"], "bea")
    client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="bea"))
    again = client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="bea"))
    assert again.status_code == 404
    listed = client.get("/v1/circles", headers=issuer.headers(sub="ada")).json()["circles"]
    assert listed[0]["member_count"] == 1


def test_a_member_who_left_can_rejoin_with_a_new_invite(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bea")
    client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="bea"))
    _join(client, issuer, circle["id"], "bea")
    assert _member_ids(client, issuer, circle["id"]) == ["ada", "bea"]


def test_a_creator_who_leaves_hands_the_circle_to_the_longest_standing_member(
    client: TestClient, issuer: TestIssuer, clock: Clock
) -> None:
    circle = _create(client, issuer)
    clock.now += timedelta(minutes=1)
    _join(client, issuer, circle["id"], "bea")
    clock.now += timedelta(minutes=1)
    _join(client, issuer, circle["id"], "cy")
    client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="ada"))
    after = client.get(f"/v1/circles/{circle['id']}", headers=issuer.headers(sub="bea")).json()
    assert after["created_by"] == "bea"
    assert after["is_creator"] is True
    assert [(member["id"], member["is_creator"]) for member in after["members"]] == [("bea", True), ("cy", False)]


def test_the_last_member_leaving_empties_the_circle(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    assert client.delete(f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="ada")).status_code == 204
    assert _circle_ids(client, issuer, "ada") == []


# Removal by the creator only.


def test_the_creator_can_remove_a_member(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bea")
    response = client.delete(f"/v1/circles/{circle['id']}/members/bea", headers=issuer.headers(sub="ada"))
    assert response.status_code == 204
    assert _member_ids(client, issuer, circle["id"]) == ["ada"]
    assert _circle_ids(client, issuer, "bea") == []
    member = table.get_item(Key={"pk": f"CIRCLE#{circle['id']}", "sk": "MEMBER#bea"})["Item"]
    assert member["removed_at"] == member["left_at"]


def test_only_the_creator_can_remove_a_member(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bea")
    _join(client, issuer, circle["id"], "cy")
    response = client.delete(f"/v1/circles/{circle['id']}/members/cy", headers=issuer.headers(sub="bea"))
    assert response.status_code == 403
    assert response.json()["detail"] == "creator_only"
    stranger = client.delete(f"/v1/circles/{circle['id']}/members/cy", headers=issuer.headers(sub="stranger"))
    assert stranger.status_code == 404
    assert _member_ids(client, issuer, circle["id"]) == ["ada", "bea", "cy"]


def test_removing_someone_who_is_not_a_member_is_not_found(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    response = client.delete(f"/v1/circles/{circle['id']}/members/nobody", headers=issuer.headers(sub="ada"))
    assert response.status_code == 404


def test_the_creator_cannot_remove_themselves(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    response = client.delete(f"/v1/circles/{circle['id']}/members/ada", headers=issuer.headers(sub="ada"))
    assert response.status_code == 422
    assert _member_ids(client, issuer, circle["id"]) == ["ada"]


def test_a_removed_member_cannot_come_back_with_an_old_invite(
    client: TestClient, issuer: TestIssuer, clock: Clock
) -> None:
    circle = _create(client, issuer)
    old_token = _invite(client, issuer, circle["id"])["token"]
    _accept(client, issuer, old_token, "bea")
    clock.now += timedelta(minutes=5)
    client.delete(f"/v1/circles/{circle['id']}/members/bea", headers=issuer.headers(sub="ada"))
    refused = _accept(client, issuer, old_token, "bea")
    assert refused.status_code == 403
    assert refused.json()["detail"] == "invite_revoked"
    # Someone else can still use the old link, and a new invite lets Bea back.
    assert _accept(client, issuer, old_token, "cy").status_code == 200
    clock.now += timedelta(minutes=5)
    _join(client, issuer, circle["id"], "bea")
    assert _member_ids(client, issuer, circle["id"]) == ["ada", "cy", "bea"]


# Several circles per account.


def test_an_account_can_be_in_several_circles(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    family = _create(client, issuer, sub="ada", name="Family")
    clock.now += timedelta(minutes=1)
    sunday = _create(client, issuer, sub="bea", name="Sunday group")
    clock.now += timedelta(minutes=1)
    own = _create(client, issuer, sub="cy", name="Cy's patch")
    _join(client, issuer, family["id"], "cy", inviter="ada")
    _join(client, issuer, sunday["id"], "cy", inviter="bea")
    listed = client.get("/v1/circles", headers=issuer.headers(sub="cy")).json()["circles"]
    assert [(circle["name"], circle["is_creator"]) for circle in listed] == [
        ("Family", False),
        ("Sunday group", False),
        ("Cy's patch", True),
    ]
    # Leaving one leaves the others alone.
    client.delete(f"/v1/circles/{sunday['id']}/members/me", headers=issuer.headers(sub="cy"))
    assert _circle_ids(client, issuer, "cy") == [family["id"], own["id"]]


def test_the_cap_holds_when_friends_join_at_the_same_moment(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    token = _invite(client, issuer, circle["id"])["token"]
    for number in range(2, 16):
        _accept(client, issuer, token, f"friend-{number}")
    # 15 members, 10 friends racing for the last 5 places.
    with ThreadPoolExecutor(max_workers=10) as pool:
        statuses = list(
            pool.map(lambda number: _accept(client, issuer, token, f"racer-{number}").status_code, range(10))
        )
    assert sorted(statuses) == [200] * 5 + [409] * 5
    assert len(_member_ids(client, issuer, circle["id"])) == 20
    assert client.get("/v1/circles", headers=issuer.headers(sub="ada")).json()["circles"][0]["member_count"] == 20


def test_the_creator_and_the_heir_leaving_at_once_leave_a_current_member_in_charge(
    client: TestClient, issuer: TestIssuer, clock: Clock
) -> None:
    for _ in range(5):
        circle = _create(client, issuer)
        clock.now += timedelta(minutes=1)
        _join(client, issuer, circle["id"], "bea")
        clock.now += timedelta(minutes=1)
        _join(client, issuer, circle["id"], "cy")
        with ThreadPoolExecutor(max_workers=2) as pool:
            statuses = list(
                pool.map(
                    lambda sub: client.delete(
                        f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub=sub)
                    ).status_code,
                    ["ada", "bea"],
                )
            )
        assert statuses == [204, 204]
        after = client.get(f"/v1/circles/{circle['id']}", headers=issuer.headers(sub="cy")).json()
        assert after["created_by"] == "cy"
        assert after["member_count"] == 1


def test_leaving_twice_at_once_counts_the_member_out_once(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bea")
    with ThreadPoolExecutor(max_workers=2) as pool:
        statuses = sorted(
            pool.map(
                lambda _: client.delete(
                    f"/v1/circles/{circle['id']}/members/me", headers=issuer.headers(sub="bea")
                ).status_code,
                range(2),
            )
        )
    assert statuses == [204, 404]
    assert client.get(f"/v1/circles/{circle['id']}", headers=issuer.headers(sub="ada")).json()["member_count"] == 1

# Guild identity (issue #181).


def test_a_chosen_emblem_is_stored_listed_and_previewed(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    emblem = {"mark": "bird.fill", "tone": "sage"}
    response = client.post("/v1/circles", headers=issuer.headers(sub="ada"), json={"name": "Birders", "emblem": emblem})
    assert response.status_code == 201, response.text
    circle = response.json()
    assert circle["emblem"] == emblem
    assert table.get_item(Key={"pk": f"CIRCLE#{circle['id']}", "sk": "META"})["Item"]["emblem"] == emblem
    assert client.get("/v1/circles", headers=issuer.headers(sub="ada")).json()["circles"][0]["emblem"] == emblem
    token = _invite(client, issuer, circle["id"])["token"]
    assert client.get(f"/v1/invites/{token}", headers=issuer.headers(sub="bob")).json()["circle"]["emblem"] == emblem


def test_only_the_creator_can_update_the_name_and_emblem(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bob")
    path = f"/v1/circles/{circle['id']}"
    body = {"name": "  Lake birders  ", "emblem": {"mark": "water.waves", "tone": "mist"}}
    assert client.patch(path, headers=issuer.headers(sub="bob"), json=body).status_code == 403
    assert client.patch(path, headers=issuer.headers(sub="stranger"), json=body).status_code == 404
    assert client.patch(path, json=body).status_code == 401
    response = client.patch(path, headers=issuer.headers(sub="ada"), json=body)
    assert response.status_code == 200, response.text
    assert response.json()["name"] == "Lake birders"
    assert response.json()["emblem"] == body["emblem"]
    member_copy = client.get(path, headers=issuer.headers(sub="bob")).json()
    assert member_copy["name"] == "Lake birders"
    assert member_copy["emblem"] == body["emblem"]
    assert not member_copy["is_creator"]


def test_partial_updates_preserve_the_other_field_and_old_guilds_have_no_emblem(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    assert circle["emblem"] is None
    path = f"/v1/circles/{circle['id']}"
    headers = issuer.headers(sub="ada")
    renamed = client.patch(path, headers=headers, json={"name": "Renamed"}).json()
    assert renamed["emblem"] is None
    emblem = {"mark": "tree.fill", "tone": "clay"}
    changed = client.patch(path, headers=headers, json={"emblem": emblem}).json()
    assert changed["name"] == "Renamed"
    assert changed["emblem"] == emblem
    assert client.patch(path, headers=headers, json={"name": "Again"}).json()["emblem"] == emblem


@pytest.mark.parametrize("body", [
    {}, {"name": None}, {"emblem": None}, {"name": ""}, {"name": "x" * 41}, {"name": "bad\tname"},
    {"emblem": {"mark": "star.fill", "tone": "sage"}}, {"emblem": {"mark": "bird.fill", "tone": "gold"}},
    {"emblem": {"mark": "bird.fill"}}, {"emblem": {"mark": "bird.fill", "tone": "sage", "extra": True}},
    {"created_by": "bob"}, {"name": "Okay", "emblem": None},
])
def test_invalid_guild_updates_are_rejected(client: TestClient, issuer: TestIssuer, body: dict[str, Any]) -> None:
    circle = _create(client, issuer)
    path = f"/v1/circles/{circle['id']}"
    assert client.patch(path, headers=issuer.headers(sub="ada"), json=body).status_code == 422
    unchanged = client.get(path, headers=issuer.headers(sub="ada")).json()
    assert unchanged["name"] == circle["name"]
    assert unchanged["emblem"] is None


@pytest.mark.parametrize("emblem", [
    {"mark": "unknown", "tone": "sage"}, {"mark": "bird.fill", "tone": "unknown"},
    {"tone": "sage"}, {"mark": "bird.fill", "tone": "sage", "extra": True},
])
def test_invalid_emblems_are_rejected_on_create(client: TestClient, issuer: TestIssuer, emblem: dict[str, Any]) -> None:
    assert client.post("/v1/circles", headers=issuer.headers(), json={"name": "Birders", "emblem": emblem}).status_code == 422


def test_edit_rights_follow_the_creator_handoff(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer)
    _join(client, issuer, circle["id"], "bob")
    path = f"/v1/circles/{circle['id']}"
    assert client.delete(path + "/members/me", headers=issuer.headers(sub="ada")).status_code == 204
    assert client.patch(path, headers=issuer.headers(sub="ada"), json={"name": "No"}).status_code == 404
    response = client.patch(path, headers=issuer.headers(sub="bob"), json={"name": "Bob's birds"})
    assert response.status_code == 200
    assert response.json()["created_by"] == "bob"
    assert response.json()["name"] == "Bob's birds"
