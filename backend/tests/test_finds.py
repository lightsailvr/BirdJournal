"""Finds (issue #62): fan-out at write time, no backfill on join, past items kept after leaving, repeated puts,
cascading deletes, "First for the circle", the paged feed with art, and what the server refuses to hold."""

from dataclasses import replace
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import uuid4

import pytest
from boto3.dynamodb.conditions import Key
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.settings import Settings
from tests.conftest import Clock
from tests.test_circles import _accept, _create, _invite, _join
from tests.tokens import TestIssuer

PHOEBE = {
    "species_id": "Sayornis nigricans_Black Phoebe",
    "scientific_name": "Sayornis nigricans",
    "common_name": "Black Phoebe",
}
WREN = {
    "species_id": "Troglodytes aedon_Northern House Wren",
    "scientific_name": "Troglodytes aedon",
    "common_name": "Northern House Wren",
}
GNATCATCHER = {
    "species_id": "Polioptila californica_California Gnatcatcher",
    "scientific_name": "Polioptila californica",
    "common_name": "California Gnatcatcher",
}


def _find(species: dict[str, str] = PHOEBE, **overrides: Any) -> dict[str, Any]:
    return {
        **species,
        "method": "heard",
        "place": "Pasadena",
        "found_at": "2026-11-01T08:15:00Z",
        "new_patch": False,
        "rarity": "common",
        "threatened": False,
        "art": {"kind": "pack", "key": "packs/us-ca-la/sayornis-nigricans.jpg"},
        **overrides,
    }


def _put(
    client: TestClient, issuer: TestIssuer, sub: str, body: dict[str, Any], sighting_id: str | None = None
) -> tuple[str, Any]:
    sighting_id = sighting_id or str(uuid4())
    return sighting_id, client.put(f"/v1/finds/{sighting_id}", headers=issuer.headers(sub=sub), json=body)


def _put_ok(client: TestClient, issuer: TestIssuer, sub: str, body: dict[str, Any], sighting_id: str | None = None) -> str:
    sighting_id, response = _put(client, issuer, sub, body, sighting_id)
    assert response.status_code in (200, 201), response.text
    return sighting_id


def _feed(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str, **params: Any) -> dict[str, Any]:
    response = client.get(f"/v1/circles/{circle_id}/feed", headers=issuer.headers(sub=sub), params=params)
    assert response.status_code == 200, response.text
    return response.json()


def _feed_ids(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str) -> list[str]:
    return [item["sighting_id"] for item in _feed(client, issuer, circle_id, sub)["items"]]


def _two_friends(client: TestClient, issuer: TestIssuer) -> str:
    """Ada's circle with Ben in it."""
    for sub, name in (("ada", "Ada"), ("ben", "Ben")):
        client.patch("/v1/account", headers=issuer.headers(sub=sub), json={"display_name": name})
    circle = _create(client, issuer, sub="ada")["id"]
    _join(client, issuer, circle, "ben")
    return circle


# Fan-out.


def test_a_find_reaches_every_circle_the_owner_is_in(client: TestClient, issuer: TestIssuer) -> None:
    sunday = _two_friends(client, issuer)
    family = _create(client, issuer, sub="ada", name="Family")["id"]
    _join(client, issuer, family, "cy")
    lonely = _create(client, issuer, sub="ben", name="Ben's own")["id"]

    sighting, response = _put(client, issuer, "ada", _find())
    assert response.status_code == 201, response.text
    assert sorted(response.json()["circle_ids"]) == sorted([sunday, family])

    item = _feed(client, issuer, sunday, "ben")["items"][0]
    assert item["sighting_id"] == sighting
    assert item["owner"] == {"id": "ada", "display_name": "Ada"}
    assert item["is_mine"] is False
    assert (item["common_name"], item["method"], item["place"], item["found_at"]) == (
        "Black Phoebe", "heard", "Pasadena", "2026-11-01T08:15:00Z"
    )
    assert _feed_ids(client, issuer, family, "cy") == [sighting]
    assert _feed(client, issuer, family, "ada")["items"][0]["is_mine"] is True
    assert _feed_ids(client, issuer, lonely, "ben") == [], "only the owner's circles"


def test_a_find_with_no_circles_is_kept_and_goes_nowhere(client: TestClient, issuer: TestIssuer) -> None:
    sighting, response = _put(client, issuer, "ada", _find())
    assert response.status_code == 201
    assert response.json()["circle_ids"] == []


def test_joining_does_not_backfill(client: TestClient, issuer: TestIssuer) -> None:
    circle = _create(client, issuer, sub="ada")["id"]
    before = _put_ok(client, issuer, "ben", _find())
    _join(client, issuer, circle, "ben")
    assert _feed_ids(client, issuer, circle, "ada") == []

    after = _put_ok(client, issuer, "ben", _find(found_at="2026-11-01T09:00:00Z"))
    assert _feed_ids(client, issuer, circle, "ada") == [after]
    # A repeated put of the old find doesn't bring it in either.
    _put_ok(client, issuer, "ben", _find(method="seen"), sighting_id=before)
    assert _feed_ids(client, issuer, circle, "ada") == [after]


def test_past_items_stay_after_leaving(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    kept = _put_ok(client, issuer, "ben", _find())
    assert client.delete(f"/v1/circles/{circle}/members/me", headers=issuer.headers(sub="ben")).status_code == 204

    _put_ok(client, issuer, "ben", _find(found_at="2026-11-01T10:00:00Z"))
    assert _feed_ids(client, issuer, circle, "ada") == [kept], "the old item stays, the new find doesn't come"
    assert client.get(f"/v1/circles/{circle}/feed", headers=issuer.headers(sub="ben")).status_code == 404

    # Deleting the sighting later still takes its find out of the circle it left.
    assert client.delete(f"/v1/finds/{kept}", headers=issuer.headers(sub="ben")).status_code == 204
    assert _feed_ids(client, issuer, circle, "ada") == []


# Repeated puts.


def test_a_repeated_put_updates_without_a_duplicate(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    circle = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find())
    clock.now += timedelta(hours=1)
    _, response = _put(client, issuer, "ada", _find(method="seen", rarity="rare"), sighting_id=sighting)
    assert response.status_code == 200, "an update, not a new find"
    _, again = _put(client, issuer, "ada", _find(method="seen", rarity="rare"), sighting_id=sighting)
    assert again.status_code == 200

    items = _feed(client, issuer, circle, "ben")["items"]
    assert [(item["sighting_id"], item["method"], item["rarity"]) for item in items] == [(sighting, "seen", "rare")]


def test_a_repeated_put_keeps_the_circles_of_the_first(client: TestClient, issuer: TestIssuer) -> None:
    first = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find())
    second = _create(client, issuer, sub="ben", name="Later")["id"]
    _join(client, issuer, second, "ada", inviter="ben")

    _, response = _put(client, issuer, "ada", _find(method="seen"), sighting_id=sighting)
    assert response.json()["circle_ids"] == [first]
    assert _feed_ids(client, issuer, second, "ben") == []


def test_a_put_that_moves_the_time_moves_the_item(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    circle = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find())
    _put_ok(client, issuer, "ada", _find(found_at="2026-11-01T07:00:00Z"), sighting_id=sighting)
    items = _feed(client, issuer, circle, "ben")["items"]
    assert [(item["sighting_id"], item["found_at"]) for item in items] == [(sighting, "2026-11-01T07:00:00Z")]
    species = table.query(KeyConditionExpression=Key("pk").eq(f"CIRCLE#{circle}#SPECIES"))["Items"]
    assert len(species) == 1


def test_a_sighting_id_is_the_owners_own(client: TestClient, issuer: TestIssuer) -> None:
    """Two accounts with the same sighting id (never in practice: they are UUIDs) don't touch each other's finds."""
    circle = _two_friends(client, issuer)
    shared = str(uuid4())
    _put_ok(client, issuer, "ada", _find(), sighting_id=shared)
    _put_ok(client, issuer, "ben", _find(WREN), sighting_id=shared)
    client.delete(f"/v1/finds/{shared}", headers=issuer.headers(sub="ben"))
    items = _feed(client, issuer, circle, "ada")["items"]
    assert [(item["owner"]["id"], item["common_name"]) for item in items] == [("ada", "Black Phoebe")]


# Deletes.


def test_a_delete_removes_the_find_its_feed_items_and_its_reactions(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    circle = _two_friends(client, issuer)
    other = _create(client, issuer, sub="ada", name="Family")["id"]
    sighting = _put_ok(client, issuer, "ada", _find())
    kept = _put_ok(client, issuer, "ada", _find(WREN))
    # Reactions are #63's; it writes them under the find's partition.
    for sub in ("ben", "cy"):
        table.put_item(Item={"pk": f"FIND#ada#{sighting}", "sk": f"REACTION#{sub}#lovely", "created_at": "x"})

    assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada")).status_code == 204

    assert _feed_ids(client, issuer, circle, "ben") == [kept]
    assert _feed_ids(client, issuer, other, "ada") == [kept]
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})
    assert table.query(KeyConditionExpression=Key("pk").eq(f"FIND#ada#{sighting}"))["Items"] == []
    for partition in (f"CIRCLE#{circle}#SPECIES", f"CIRCLE#{other}#SPECIES"):
        species = table.query(KeyConditionExpression=Key("pk").eq(partition))["Items"]
        assert [item["sighting_id"] for item in species] == [kept]


def test_deleting_twice_or_a_find_never_put_is_fine(client: TestClient, issuer: TestIssuer) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    for _ in range(2):
        assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada")).status_code == 204
    assert client.delete(f"/v1/finds/{uuid4()}", headers=issuer.headers(sub="ada")).status_code == 204


def test_only_the_owner_deletes_a_find(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find())
    # Ben's delete addresses Ben's own find with that id, which doesn't exist.
    assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ben")).status_code == 204
    assert _feed_ids(client, issuer, circle, "ben") == [sighting]


# First for the circle.


def test_the_earliest_find_of_a_species_is_first_for_the_circle(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    early = _put_ok(client, issuer, "ben", _find(found_at="2026-11-01T07:00:00Z"))
    late = _put_ok(client, issuer, "ada", _find(found_at="2026-11-01T08:00:00Z"))
    wren = _put_ok(client, issuer, "ada", _find(WREN, found_at="2026-11-01T09:00:00Z"))

    firsts = {item["sighting_id"]: item["circle_first"] for item in _feed(client, issuer, circle, "ada")["items"]}
    assert firsts == {early: True, late: False, wren: True}


def test_circle_first_passes_on_after_a_delete(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    early = _put_ok(client, issuer, "ben", _find(found_at="2026-11-01T07:00:00Z"))
    late = _put_ok(client, issuer, "ada", _find(found_at="2026-11-01T08:00:00Z"))
    client.delete(f"/v1/finds/{early}", headers=issuer.headers(sub="ben"))

    items = _feed(client, issuer, circle, "ada")["items"]
    assert [(item["sighting_id"], item["circle_first"]) for item in items] == [(late, True)]


def test_circle_first_is_per_circle_and_apart_from_a_new_patch(client: TestClient, issuer: TestIssuer) -> None:
    first = _two_friends(client, issuer)
    _put_ok(client, issuer, "ben", _find(found_at="2026-11-01T07:00:00Z", new_patch=True))
    second = _create(client, issuer, sub="ada", name="Family")["id"]
    mine = _put_ok(client, issuer, "ada", _find(found_at="2026-11-01T08:00:00Z", new_patch=False))

    in_first = {item["sighting_id"]: item["circle_first"] for item in _feed(client, issuer, first, "ada")["items"]}
    assert in_first[mine] is False
    in_second = _feed(client, issuer, second, "ada")["items"]
    assert [(item["sighting_id"], item["circle_first"], item["new_patch"]) for item in in_second] == [
        (mine, True, False)
    ]


def test_a_new_patch_reaches_the_feed_with_its_edition(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    sighting, response = _put(client, issuer, "ada", _find(new_patch=True, edition="us-ca-la"))
    assert response.status_code == 201
    assert (response.json()["new_patch"], response.json()["edition"]) == (True, "us-ca-la")
    (item,) = _feed(client, issuer, circle, "ben")["items"]
    assert (item["sighting_id"], item["new_patch"], item["edition"]) == (sighting, True, "us-ca-la")


def test_a_repeat_or_a_find_outside_every_set_says_so(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    _put_ok(client, issuer, "ada", _find(new_patch=False, edition="us-ca-la"))
    _put_ok(client, issuer, "ben", _find(WREN, new_patch=True, edition=None))
    by_species = {item["scientific_name"]: item for item in _feed(client, issuer, circle, "ada")["items"]}
    assert (by_species[PHOEBE["scientific_name"]]["new_patch"], by_species[PHOEBE["scientific_name"]]["edition"]) == (False, "us-ca-la")
    assert (by_species[WREN["scientific_name"]]["new_patch"], by_species[WREN["scientific_name"]]["edition"]) == (True, None)


@pytest.mark.parametrize("edition", ["", "US-CA-LA", "us ca la", "us-ca-la#1", "../etc", "x" * 65])
def test_an_edition_is_a_pack_id(client: TestClient, issuer: TestIssuer, edition: str) -> None:
    _, response = _put(client, issuer, "ada", _find(edition=edition))
    assert response.status_code == 422


# Until the deploy has settled and every beta phone has updated (the compatibility notes in finds.py and finds_api.py).


def test_a_phone_from_before_136_is_taken_as_it_sends_a_find(client: TestClient, issuer: TestIssuer) -> None:
    """Exactly what `FindPolicy.Find` encodes on `dev` before #136 and #137: `legendary`, no `new_patch` or `edition`, a
    watercolour's thumbnail with no `fallback` (it is only sent beside a painting), and nulls for what is absent. Its outbox
    treats a 422 as final and drops the find."""
    with_art = {
        **PHOEBE, "method": "heard", "place": "Pasadena", "found_at": "2026-11-01T08:15:00Z", "legendary": True,
        "rarity": "common", "threatened": False, "art": {"kind": "pack", "key": "packs/us-ca-la/sayornis-nigricans.jpg"},
    }
    _, response = _put(client, issuer, "ada", with_art)
    assert response.status_code == 201, response.text
    assert response.json()["art"]["kind"] == "pack"
    assert response.json()["new_patch"] is True
    bare = {**with_art, "place": None, "rarity": None, "art": None, "legendary": False, "found_at": "2026-11-01T09:15:00Z"}
    _, response = _put(client, issuer, "ada", bare)
    assert response.status_code == 201, response.text
    assert response.json()["art"] is None


def test_an_old_clients_legendary_is_a_new_patch(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    for legendary in (True, False):
        body = _find(legendary=legendary, found_at=f"2026-11-01T0{int(legendary)}:00:00Z")
        del body["new_patch"]
        sighting, response = _put(client, issuer, "ada", body)
        assert response.status_code == 201, response.text
        assert response.json()["new_patch"] is legendary
        item = next(item for item in _feed(client, issuer, circle, "ben")["items"] if item["sighting_id"] == sighting)
        assert item["new_patch"] is legendary


def test_a_new_clients_feed_still_answers_an_old_client(client: TestClient, issuer: TestIssuer) -> None:
    """An old phone's `FeedItem` can't decode an item without `legendary`, so a new server keeps sending it."""
    circle = _two_friends(client, issuer)
    _, response = _put(client, issuer, "ada", _find(new_patch=True, edition="us-ca-la"))
    assert response.json()["legendary"] is True
    (item,) = _feed(client, issuer, circle, "ben")["items"]
    assert item["legendary"] is True


def test_nothing_new_is_stored_under_legendary(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    circle = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(new_patch=True, edition="us-ca-la"))
    stored = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})["Item"]
    assert stored["new_patch"] is True and stored["edition"] == "us-ca-la" and "legendary" not in stored
    (item,) = table.query(KeyConditionExpression=Key("pk").eq(f"CIRCLE#{circle}#FEED"))["Items"]
    assert item["new_patch"] is True and "legendary" not in item


def test_a_find_stored_before_the_rename_reads_as_a_new_patch(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    """Items already in the table keep `legendary` until they are next put."""
    circle = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(new_patch=True))
    for key in (
        {"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"},
        next(
            {"pk": item["pk"], "sk": item["sk"]}
            for item in table.query(KeyConditionExpression=Key("pk").eq(f"CIRCLE#{circle}#FEED"))["Items"]
        ),
    ):
        table.update_item(
            Key=key, UpdateExpression="SET legendary = :true REMOVE new_patch, edition", ExpressionAttributeValues={":true": True}
        )
    (item,) = _feed(client, issuer, circle, "ben")["items"]
    assert (item["new_patch"], item["edition"]) == (True, None)
    # Put again, it moves to the new attribute.
    _put_ok(client, issuer, "ada", _find(new_patch=True, method="seen"), sighting_id=sighting)
    stored = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})["Item"]
    assert stored["new_patch"] is True and "legendary" not in stored


def test_a_find_older_than_the_first_takes_the_mark(client: TestClient, issuer: TestIssuer) -> None:
    """An offline add published later, from earlier in the day, is the earlier find."""
    circle = _two_friends(client, issuer)
    late = _put_ok(client, issuer, "ada", _find(found_at="2026-11-01T08:00:00Z"))
    early = _put_ok(client, issuer, "ben", _find(found_at="2026-11-01T06:00:00Z"))
    firsts = {item["sighting_id"]: item["circle_first"] for item in _feed(client, issuer, circle, "ada")["items"]}
    assert firsts == {early: True, late: False}


# The feed.


def test_the_feed_is_paged_newest_first(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    start = datetime(2026, 11, 1, 6, 0, tzinfo=UTC)
    ids = [
        _put_ok(client, issuer, "ada" if n % 2 else "ben", _find(found_at=(start + timedelta(minutes=n)).isoformat()))
        for n in range(23)
    ]
    newest_first = list(reversed(ids))

    seen: list[str] = []
    cursor = None
    pages = 0
    while True:
        params: dict[str, Any] = {"limit": 10, **({"cursor": cursor} if cursor else {})}
        page = _feed(client, issuer, circle, "ben", **params)
        seen += [item["sighting_id"] for item in page["items"]]
        pages += 1
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert seen == newest_first
    assert pages == 3
    assert len(_feed(client, issuer, circle, "ben")["items"]) == 20, "twenty by default"


def test_the_feed_is_for_members_only(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    assert client.get(f"/v1/circles/{circle}/feed", headers=issuer.headers(sub="eve")).status_code == 404
    assert client.get(f"/v1/circles/{circle}/feed").status_code == 401
    assert client.get("/v1/circles/nope/feed", headers=issuer.headers(sub="ada")).status_code == 404


@pytest.mark.parametrize("params", [{"cursor": "!!!"}, {"cursor": "bm90LWEta2V5"}, {"limit": 0}, {"limit": 51}])
def test_a_bad_cursor_or_limit_is_refused(client: TestClient, issuer: TestIssuer, params: dict[str, Any]) -> None:
    circle = _two_friends(client, issuer)
    response = client.get(f"/v1/circles/{circle}/feed", headers=issuer.headers(sub="ada"), params=params)
    assert response.status_code == 422


def test_feed_items_carry_their_art_on_the_art_cdn(
    settings: Settings, issuer: TestIssuer, clock: Clock
) -> None:
    app = create_app(
        replace(settings, art_cdn_base_url="https://d111.cloudfront.net"), signing_key=issuer.signing_key, clock=clock
    )
    with TestClient(app) as client:
        circle = _two_friends(client, issuer)
        _put_ok(client, issuer, "ada", _find())
        _put_ok(client, issuer, "ada", _find(WREN, art=None))
        items = {item["common_name"]: item for item in _feed(client, issuer, circle, "ben")["items"]}
    assert items["Black Phoebe"]["art"] == {
        "kind": "pack",
        "key": "packs/us-ca-la/sayornis-nigricans.jpg",
        "url": "https://d111.cloudfront.net/packs/us-ca-la/sayornis-nigricans.jpg",
    }
    assert items["Northern House Wren"]["art"] is None, "the phone falls back to the reference photo or a tile"


def test_without_an_art_cdn_the_feed_gives_keys_alone(settings: Settings, issuer: TestIssuer, clock: Clock) -> None:
    app = create_app(replace(settings, art_cdn_base_url=None), signing_key=issuer.signing_key, clock=clock)
    with TestClient(app) as client:
        circle = _two_friends(client, issuer)
        _put_ok(client, issuer, "ada", _find())
        assert _feed(client, issuer, circle, "ben")["items"][0]["art"]["url"] is None


def test_the_display_name_is_read_with_the_feed(client: TestClient, issuer: TestIssuer) -> None:
    circle = _two_friends(client, issuer)
    _put_ok(client, issuer, "ada", _find())
    client.patch("/v1/account", headers=issuer.headers(sub="ada"), json={"display_name": "Ada L."})
    assert _feed(client, issuer, circle, "ben")["items"][0]["owner"]["display_name"] == "Ada L."


# What the server holds: never a coordinate, the secret spot, the minute.


def test_a_threatened_species_is_always_at_a_secret_spot(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    circle = _two_friends(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(GNATCATCHER, threatened=True, place="Palos Verdes"))
    _put_ok(client, issuer, "ada", _find(GNATCATCHER, threatened=True, place=None, found_at="2026-11-01T09:00:00Z"))
    places = [item["place"] for item in _feed(client, issuer, circle, "ben")["items"]]
    assert places == ["a secret spot", "a secret spot"]
    stored = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})["Item"]
    assert "Palos Verdes" not in str(stored)


@pytest.mark.parametrize(
    "extra",
    [
        {"latitude": 34.1365, "longitude": -118.2942},
        {"location": {"latitude": 34.1365, "longitude": -118.2942}},
        {"coordinate": "34.1365,-118.2942"},
        {"note": "Tail dipping over the pond."},
    ],
)
def test_fields_beyond_the_find_policys_are_refused(
    client: TestClient, issuer: TestIssuer, table: Any, extra: dict[str, Any]
) -> None:
    sighting, response = _put(client, issuer, "ada", {**_find(), **extra})
    assert response.status_code == 422
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})


@pytest.mark.parametrize(
    "place", ["34.1365, -118.2942", "Near 34.13 -118.29", "34°08'N 118°17'W", "34 8' N", "x" * 81, "Pasa\ndena"]
)
def test_a_place_that_holds_a_coordinate_or_is_malformed_is_refused(
    client: TestClient, issuer: TestIssuer, place: str
) -> None:
    _, response = _put(client, issuer, "ada", _find(place=place))
    assert response.status_code == 422


@pytest.mark.parametrize("place", ["Pasadena", "Los Angeles, CA", "St. John's", "Twentynine Palms", "29 Palms"])
def test_city_names_are_kept(client: TestClient, issuer: TestIssuer, place: str) -> None:
    _, response = _put(client, issuer, "ada", _find(place=place))
    assert response.status_code == 201, response.text
    assert response.json()["place"] == place


def test_the_time_is_kept_to_the_minute_in_utc(client: TestClient, issuer: TestIssuer) -> None:
    _, response = _put(client, issuer, "ada", _find(found_at="2026-11-01T01:15:42.5-07:00"))
    assert response.json()["found_at"] == "2026-11-01T08:15:00Z"
    _, naive = _put(client, issuer, "ada", _find(found_at="2026-11-01T08:15:00"))
    assert naive.status_code == 422


@pytest.mark.parametrize(
    "art",
    [
        {"kind": "pack", "key": "art/ada/x.jpg"},
        {"kind": "painted", "key": "art/ada/x.jpg"},
        {"kind": "painted", "key": "packs/us-ca-la/x.jpg"},
        {"kind": "pack", "key": "packs/us-ca-la/x.jpg", "fallback": {"kind": "pack", "key": "packs/us-ca-la/y.jpg"}},
        {"kind": "pack", "key": "packs/../secrets.jpg"},
        {"kind": "pack", "key": "https://example.com/x.jpg"},
        {"kind": "pack", "key": "packs/us-ca-la/x.gif"},
        {"kind": "sticker", "key": "packs/us-ca-la/x.jpg"},
    ],
)
def test_art_must_be_an_art_cdn_key_of_its_kind(client: TestClient, issuer: TestIssuer, art: dict[str, Any]) -> None:
    _, response = _put(client, issuer, "ada", _find(art=art))
    assert response.status_code == 422


@pytest.mark.parametrize(
    "overrides",
    [{"method": "smelled"}, {"rarity": "legendary"}, {"common_name": ""}, {"scientific_name": "Sayornis#nigricans"}],
)
def test_malformed_finds_are_refused(client: TestClient, issuer: TestIssuer, overrides: dict[str, Any]) -> None:
    _, response = _put(client, issuer, "ada", _find(**overrides))
    assert response.status_code == 422


def test_the_sighting_id_is_a_uuid(client: TestClient, issuer: TestIssuer) -> None:
    response = client.put("/v1/finds/not-a-uuid", headers=issuer.headers(sub="ada"), json=_find())
    assert response.status_code == 422
    upper = str(uuid4()).upper()
    _, put = _put(client, issuer, "ada", _find(), sighting_id=upper)
    assert put.json()["sighting_id"] == upper.lower()


def test_finds_need_a_token(client: TestClient) -> None:
    assert client.put(f"/v1/finds/{uuid4()}", json=_find()).status_code == 401
    assert client.delete(f"/v1/finds/{uuid4()}").status_code == 401


def test_a_member_reading_after_joining_sees_only_later_finds(client: TestClient, issuer: TestIssuer) -> None:
    """Two devices, two accounts: an add on one appears in the other's feed (the API side of the device check)."""
    circle = _create(client, issuer, sub="ada")["id"]
    token = _invite(client, issuer, circle)["token"]
    assert _accept(client, issuer, token, "ben").status_code == 200
    sighting = _put_ok(client, issuer, "ada", _find())
    assert _feed_ids(client, issuer, circle, "ben") == [sighting]


def test_a_put_cut_short_is_finished_into_the_circles_it_first_named(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    """The find is written before its feed items, so a retry after a failure part way uses the circles it named then,
    even if the owner left one since, and a later delete still reaches that circle."""
    circle = _two_friends(client, issuer)
    sighting = str(uuid4())
    # What a put that failed right after writing the find leaves: the find, no feed items.
    table.put_item(Item={
        "pk": "ACCOUNT#ben", "sk": f"FIND#{sighting}", "species_id": PHOEBE["species_id"],
        "scientific_name": PHOEBE["scientific_name"], "common_name": PHOEBE["common_name"], "method": "heard",
        "found_at": "2026-11-01T08:15Z", "legendary": False, "threatened": False, "circle_ids": [circle],
        "created_at": "2026-11-01T09:30:00+00:00", "updated_at": "2026-11-01T09:30:00+00:00",
    })
    client.delete(f"/v1/circles/{circle}/members/me", headers=issuer.headers(sub="ben"))
    _put_ok(client, issuer, "ben", _find(), sighting_id=sighting)
    assert _feed_ids(client, issuer, circle, "ada") == [sighting]
    client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ben"))
    assert _feed_ids(client, issuer, circle, "ada") == []
