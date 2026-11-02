"""Painted art in finds (issue #70, ADR-0004): a find or a card shared by hand points at the painting through a repeated
put that pushes nothing, and the server keeps painted art only while a find or shared card shows it, deleting it
otherwise once the phone has it. Every retention path, through the API."""

from typing import Any
from uuid import uuid4

from boto3.dynamodb.conditions import Key
from fastapi.testclient import TestClient

from tests.conftest import ART_CDN, Clock, FakeApns, FakeArtStorage
from tests.test_art_jobs import _claim, _queued, _ready
from tests.test_circles import _create, _join
from tests.test_finds import _feed, _find, _put, _put_ok
from tests.test_pushes import _register
from tests.tokens import TestIssuer

PACK = {"kind": "pack", "key": "packs/us-ca-la/sayornis-nigricans.jpg"}
ADA_PHONE = "a" * 64
BEN_PHONE = "b" * 64


def _circle(client: TestClient, issuer: TestIssuer) -> str:
    """Ada's circle with Ben in it, both named."""
    for sub, name in (("ada", "Ada"), ("ben", "Ben")):
        client.patch("/v1/account", headers=issuer.headers(sub=sub), json={"display_name": name})
    circle = str(_create(client, issuer, sub="ada")["id"])
    _join(client, issuer, circle, "ben")
    return circle


def _painting(
    client: TestClient, issuer: TestIssuer, storage: FakeArtStorage, sighting: str, sub: str = "ada", **fields: Any
) -> dict[str, Any]:
    """A job for the sighting painted and ready, not yet received: the job as the phone sees it."""
    job = _queued(client, issuer, storage, sub=sub, sighting=sighting, **fields)
    claim = _claim(client, job["id"], sub=sub).json()
    assert _ready(client, claim, storage).status_code == 200
    response = client.get(f"/v1/art/jobs/{job['id']}", headers=issuer.headers(sub=sub))
    ready: dict[str, Any] = response.json()
    assert ready["state"] == "ready" and ready["art_key"] == claim["output_key"]
    return ready


def _painted(job: dict[str, Any], fallback: dict[str, str] | None = PACK) -> dict[str, Any]:
    art: dict[str, Any] = {"kind": "painted", "key": job["art_key"]}
    if fallback is not None:
        art["fallback"] = fallback
    return art


def _received(client: TestClient, issuer: TestIssuer, job: dict[str, Any], sub: str = "ada") -> None:
    assert client.post(f"/v1/art/jobs/{job['id']}/received", headers=issuer.headers(sub=sub)).status_code == 200


def _art_in_feed(client: TestClient, issuer: TestIssuer, circle: str, sighting: str, sub: str = "ben") -> Any:
    items = _feed(client, issuer, circle, sub)["items"]
    return next(item for item in items if item["sighting_id"] == sighting)["art"]


def _stored_art(table: Any, sighting: str, sub: str = "ada") -> Any:
    item = table.get_item(Key={"pk": f"ACCOUNT#{sub}", "sk": f"FIND#{sighting}"})["Item"]
    return item.get("art_kind"), item.get("art_key")


# Kept while something shows it.


def test_a_painting_a_find_shows_stays_after_the_phone_has_it(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    circle = _circle(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find())
    job = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    _received(client, issuer, job)
    assert job["art_key"] in art_storage.art
    assert _art_in_feed(client, issuer, circle, sighting) == {
        "kind": "painted", "key": job["art_key"], "url": f"{ART_CDN}/{job['art_key']}",
    }


def test_a_painting_only_a_card_shared_by_hand_shows_stays(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    """A private birder: no automatic find, only the card shared by hand to one circle."""
    circle = _circle(client, issuer)
    sighting = str(uuid4())
    job = _painting(client, issuer, art_storage, sighting)
    body = {"find": _find(art=_painted(job)), "circle_ids": [circle]}
    assert client.put(f"/v1/finds/{sighting}/card", headers=issuer.headers(sub="ada"), json=body).status_code == 201
    _received(client, issuer, job)
    assert job["art_key"] in art_storage.art
    assert _art_in_feed(client, issuer, circle, sighting)["key"] == job["art_key"]


def test_a_painting_on_a_card_shared_by_hand_goes_when_the_card_does(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    circle = _circle(client, issuer)
    sighting = str(uuid4())
    job = _painting(client, issuer, art_storage, sighting)
    body = {"find": _find(art=_painted(job)), "circle_ids": [circle]}
    client.put(f"/v1/finds/{sighting}/card", headers=issuer.headers(sub="ada"), json=body)
    _received(client, issuer, job)
    assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada")).status_code == 204
    assert job["art_key"] not in art_storage.art


# Deleted once the phone has it and nothing shows it.


def test_a_private_birders_painting_goes_once_the_phone_has_it(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    """No find at all: nothing on the server shows it."""
    job = _painting(client, issuer, art_storage, str(uuid4()))
    assert job["art_key"] in art_storage.art, "kept until the phone has it"
    _received(client, issuer, job)
    assert job["art_key"] not in art_storage.art


def test_a_painting_the_find_never_showed_goes_once_the_phone_has_it(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    job = _painting(client, issuer, art_storage, sighting)
    _received(client, issuer, job)
    assert job["art_key"] not in art_storage.art


def test_a_put_naming_a_deleted_painting_shows_the_pack_art_instead(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    """A put that reached the server after the phone said it had the painting (and nothing showed it then) never
    points the find at nothing."""
    circle = _circle(client, issuer)
    sighting = str(uuid4())
    job = _painting(client, issuer, art_storage, sighting)
    _received(client, issuer, job)
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    assert _stored_art(table, sighting) == ("pack", PACK["key"])
    assert _art_in_feed(client, issuer, circle, sighting)["kind"] == "pack"


# Deleted with the find.


def test_deleting_the_find_deletes_its_painting(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    job = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    _received(client, issuer, job)
    assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada")).status_code == 204
    assert job["art_key"] not in art_storage.art
    # A removal undone puts the find back, with its pack art: the painting is gone from the server.
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    assert _stored_art(table, sighting) == ("pack", PACK["key"])


def test_a_find_deleted_before_the_phone_has_its_painting_leaves_it_for_the_phone(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    job = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada"))
    assert job["art_key"] in art_storage.art, "the phone hasn't downloaded it yet"
    _received(client, issuer, job)
    assert job["art_key"] not in art_storage.art


# The repeated put.


def test_a_repeated_put_swaps_pack_art_for_the_painting_without_a_push(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, apns: FakeApns, table: Any, clock: Clock
) -> None:
    circle = _circle(client, issuer)
    for sub, phone in (("ada", ADA_PHONE), ("ben", BEN_PHONE)):
        assert _register(client, issuer, sub, phone).status_code == 204
    sighting, first = _put(client, issuer, "ada", _find(legendary=True))
    assert first.status_code == 201
    assert len(apns.to(BEN_PHONE)) == 1, "the new Legendary find pushes once"
    apns.clear()
    digests_before = table.query(KeyConditionExpression=Key("pk").eq("DIGEST"))["Items"]

    job = _painting(client, issuer, art_storage, sighting)
    _, again = _put(client, issuer, "ada", _find(legendary=True, art=_painted(job)), sighting)
    assert again.status_code == 200
    assert again.json()["art"]["kind"] == "painted"
    assert apns.sent == [], "no alert, no silent push"
    assert table.query(KeyConditionExpression=Key("pk").eq("DIGEST"))["Items"] == digests_before
    feed = _feed(client, issuer, circle, "ben")["items"]
    assert [item["sighting_id"] for item in feed] == [sighting], "updated, not duplicated"
    assert feed[0]["art"]["key"] == job["art_key"]
    clock.now = clock.now.replace(hour=12)
    client.app.state.pushes.flush_digests()  # type: ignore[attr-defined]
    assert apns.sent == []


def test_a_put_after_a_card_shared_by_hand_pushes_nothing(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, apns: FakeApns
) -> None:
    circle = _circle(client, issuer)
    assert _register(client, issuer, "ben", BEN_PHONE).status_code == 204
    sighting = str(uuid4())
    body: dict[str, Any] = {"find": _find(), "circle_ids": [circle]}
    client.put(f"/v1/finds/{sighting}/card", headers=issuer.headers(sub="ada"), json=body)
    apns.clear()
    job = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    assert apns.sent == []
    assert _art_in_feed(client, issuer, circle, sighting)["key"] == job["art_key"]


# Try again, Use pack art, photo art.


def test_try_again_replaces_the_painting_and_the_old_one_goes(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    circle = _circle(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find())
    first = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(first)), sighting)
    _received(client, issuer, first)

    again = _painting(client, issuer, art_storage, sighting, requested=True)
    assert first["art_key"] in art_storage.art, "the find still shows the first until the phone puts the second"
    _put_ok(client, issuer, "ada", _find(art=_painted(again)), sighting)
    assert first["art_key"] not in art_storage.art, "nothing shows it any more and the phone has it"
    _received(client, issuer, again)
    assert again["art_key"] in art_storage.art
    assert _art_in_feed(client, issuer, circle, sighting)["key"] == again["art_key"]


def test_a_replaced_painting_the_phone_hasnt_downloaded_goes_when_it_does(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    first = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(first)), sighting)
    again = _painting(client, issuer, art_storage, sighting, requested=True)
    _put_ok(client, issuer, "ada", _find(art=_painted(again)), sighting)
    assert first["art_key"] in art_storage.art, "not received yet"
    _received(client, issuer, first)
    assert first["art_key"] not in art_storage.art
    _received(client, issuer, again)
    assert again["art_key"] in art_storage.art


def test_use_pack_art_lets_the_painting_go_and_it_never_comes_back_to_nothing(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    job = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    _received(client, issuer, job)
    _put_ok(client, issuer, "ada", _find(), sighting)
    assert job["art_key"] not in art_storage.art
    # Use painted art again on the phone: the server no longer has it, so the find keeps its pack art.
    _put_ok(client, issuer, "ada", _find(art=_painted(job)), sighting)
    assert _stored_art(table, sighting) == ("pack", PACK["key"])


def test_approved_photo_art_on_the_find_stays(client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage) -> None:
    sighting = _put_ok(client, issuer, "ada", _find())
    photo = _painting(client, issuer, art_storage, sighting, kind="photo", requested=True)
    _put_ok(client, issuer, "ada", _find(art=_painted(photo)), sighting)
    _received(client, issuer, photo)
    assert photo["art_key"] in art_storage.art


def test_photo_art_kept_original_instead_of_approved_goes(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    """The find shows the scene painting; the photo painting waits for approval, then the birder keeps the original:
    the phone says it has the photo painting and nothing shows it."""
    sighting = _put_ok(client, issuer, "ada", _find())
    scene = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=_painted(scene)), sighting)
    _received(client, issuer, scene)
    photo = _painting(client, issuer, art_storage, sighting, kind="photo", requested=True)
    _received(client, issuer, photo)
    assert photo["art_key"] not in art_storage.art
    assert scene["art_key"] in art_storage.art
    assert _stored_art(table, sighting) == ("painted", scene["art_key"])


# Whose painting.


def test_a_find_cannot_show_another_accounts_or_another_sightings_painting(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    bens = _painting(client, issuer, art_storage, str(uuid4()), sub="ben")
    other = _painting(client, issuer, art_storage, str(uuid4()))
    sighting = _put_ok(client, issuer, "ada", _find(art=_painted(bens)))
    assert _stored_art(table, sighting) == ("pack", PACK["key"])
    _put_ok(client, issuer, "ada", _find(art=_painted(other)), sighting)
    assert _stored_art(table, sighting) == ("pack", PACK["key"])
    _received(client, issuer, bens, sub="ben")
    assert bens["art_key"] not in art_storage.art, "Ada's find never kept Ben's painting"


def test_with_no_fallback_a_painting_the_server_lacks_keeps_what_the_find_showed(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find(art=None))
    _put_ok(client, issuer, "ada", _find(art={"kind": "painted", "key": "art/ada/never-painted.jpg"}), sighting)
    assert _stored_art(table, sighting) == (None, None)


def test_only_painted_art_falls_back_and_only_to_pack_art(client: TestClient, issuer: TestIssuer) -> None:
    for art in (
        {**PACK, "fallback": PACK},
        {"kind": "painted", "key": "art/ada/x.jpg", "fallback": {"kind": "painted", "key": "art/ada/y.jpg"}},
        {"kind": "painted", "key": "art/ada/x.jpg", "fallback": {"kind": "pack", "key": "art/ada/y.jpg"}},
        {"kind": "painted", "key": "art/ada/x.jpg", "fallback": {**PACK, "url": "https://x"}},
    ):
        _, response = _put(client, issuer, "ada", _find(art=art))
        assert response.status_code == 422, art


# #62's rules hold with painted art.


def test_the_secret_spot_and_no_coordinate_rules_hold_with_painted_art(
    client: TestClient, issuer: TestIssuer, art_storage: FakeArtStorage, table: Any
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find(threatened=True, place="Pasadena"))
    job = _painting(client, issuer, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(threatened=True, place="Pasadena", art=_painted(job)), sighting)
    item = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})["Item"]
    assert (item["place"], item["art_key"]) == ("a secret spot", job["art_key"])
    _, response = _put(client, issuer, "ada", _find(place="34.1478, -118.1445", art=_painted(job)), sighting)
    assert response.status_code == 422
    _, response = _put(client, issuer, "ada", {**_find(art=_painted(job)), "latitude": 34.14}, sighting)
    assert response.status_code == 422
    assert table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})["Item"]["place"] == "a secret spot"
