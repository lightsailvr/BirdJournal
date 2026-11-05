"""What is left of painted art (issue #137, `painted.py`): nothing is painted any more and the API that did it is gone, but
finds stored before then still show paintings, and a phone from before #137 may still name one. Every path through the
API, with the paintings seeded in the table as #70 left them."""

from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from tests.conftest import ART_CDN, Clock, FakeApns, FakeArtStorage
from tests.test_circles import _create, _join
from tests.test_finds import _feed, _find, _put, _put_ok
from tests.test_pushes import _register
from tests.tokens import TestIssuer

PACK = {"kind": "pack", "key": "packs/us-ca-la/patch/sayornis-nigricans.png"}
BEN_PHONE = "b" * 64


def _circle(client: TestClient, issuer: TestIssuer) -> str:
    """Ada's circle with Ben in it, both named."""
    for sub, name in (("ada", "Ada"), ("ben", "Ben")):
        client.patch("/v1/account", headers=issuer.headers(sub=sub), json={"display_name": name})
    circle = str(_create(client, issuer, sub="ada")["id"])
    _join(client, issuer, circle, "ben")
    return circle


def store_painting(table: Any, storage: FakeArtStorage, sighting: str, sub: str = "ada", *, painted_for: str | None = None) -> str:
    """Turns the stored find and its feed items into what #70 left: a find showing a painting on the art CDN. Its key."""
    key = f"art/{painted_for or sub}/{uuid4().hex}.jpg"
    storage.art[key] = b"painting"
    items = table.scan()["Items"]
    mine = [item for item in items if str(item["sk"]).endswith(sighting)]
    assert mine, "the find has to be there first"
    for item in mine:
        table.put_item(Item={**item, "art_kind": "painted", "art_key": key})
    return key


def store_job(table: Any, storage: FakeArtStorage, sub: str = "ada", *, deleted: bool = False) -> str:
    """An `ARTJOB#` item as #68 wrote it, and the painting it names unless that already went. The painting's key."""
    job_id = str(uuid4())
    key = f"art/{sub}/{uuid4().hex}.jpg"
    item = {
        "pk": f"ACCOUNT#{sub}", "sk": f"ARTJOB#{job_id}", "sighting_id": str(uuid4()), "kind": "scene", "state": "ready",
        "input_key": f"uploads/{sub}/{job_id}.jpg", "output_key": key, "attempts": 1,
    }
    if deleted:
        item["art_deleted_at"] = "2026-11-02T00:00:00+00:00"
    else:
        storage.art[key] = b"painting"
    table.put_item(Item=item)
    return key


def _painted(key: str, fallback: dict[str, str] | None = PACK) -> dict[str, Any]:
    art: dict[str, Any] = {"kind": "painted", "key": key}
    if fallback is not None:
        art["fallback"] = fallback
    return art


def _art_in_feed(client: TestClient, issuer: TestIssuer, circle: str, sighting: str, sub: str = "ben") -> Any:
    items = _feed(client, issuer, circle, sub)["items"]
    return next(item for item in items if item["sighting_id"] == sighting)["art"]


def _stored_art(table: Any, sighting: str, sub: str = "ada") -> Any:
    item = table.get_item(Key={"pk": f"ACCOUNT#{sub}", "sk": f"FIND#{sighting}"})["Item"]
    return item.get("art_kind"), item.get("art_key")


# The API that painted is gone.


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


# A stored painting stays while its find shows it.


def test_a_stored_painting_still_shows_in_the_feed(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    circle = _circle(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    key = store_painting(table, art_storage, sighting)
    assert _art_in_feed(client, issuer, circle, sighting) == {"kind": "painted", "key": key, "url": f"{ART_CDN}/{key}"}
    assert key in art_storage.art


def test_an_old_phones_repeated_put_of_the_painting_keeps_it_and_pushes_nothing(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage, apns: FakeApns, clock: Clock
) -> None:
    circle = _circle(client, issuer)
    _register(client, issuer, "ben", BEN_PHONE)
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    key = store_painting(table, art_storage, sighting)
    apns.sent.clear()
    _, response = _put(client, issuer, "ada", _find(art=_painted(key), method="seen"), sighting)
    assert response.status_code == 200, response.text
    assert _art_in_feed(client, issuer, circle, sighting)["key"] == key
    assert key in art_storage.art
    assert apns.sent == []


# A phone from before #137 is never refused: its outbox would drop the find.


def test_an_old_phones_new_painting_is_taken_and_the_find_shows_its_fallback(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    circle = _circle(client, issuer)
    sighting = str(uuid4())
    _, response = _put(client, issuer, "ada", _find(art=_painted("art/ada/never-held.jpg")), sighting)
    assert response.status_code == 201, response.text
    assert _art_in_feed(client, issuer, circle, sighting)["key"] == PACK["key"]
    assert _stored_art(table, sighting) == ("pack", PACK["key"])


def test_an_old_phones_new_painting_with_no_fallback_keeps_what_the_find_showed(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    _, response = _put(client, issuer, "ada", _find(art=_painted("art/ada/never-held.jpg", fallback=None)), sighting)
    assert response.status_code == 200, response.text
    assert _stored_art(table, sighting) == ("pack", PACK["key"])


def test_an_old_phones_new_painting_with_no_fallback_on_a_new_find_shows_none(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    sighting = str(uuid4())
    _, response = _put(client, issuer, "ada", _find(art=_painted("art/ada/never-held.jpg", fallback=None)), sighting)
    assert response.status_code == 201, response.text
    assert _stored_art(table, sighting) == (None, None)


def test_an_old_phones_shared_card_naming_a_painting_is_taken(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    circle = _circle(client, issuer)
    sighting = str(uuid4())
    body = {"find": _find(art=_painted("art/ada/never-held.jpg")), "circle_ids": [circle]}
    response = client.put(f"/v1/finds/{sighting}/card", headers=issuer.headers(sub="ada"), json=body)
    assert response.status_code == 201, response.text
    assert _stored_art(table, sighting) == ("pack", PACK["key"])


def test_a_find_cannot_take_another_accounts_painting(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    bens_sighting = _put_ok(client, issuer, "ben", _find(art=PACK))
    bens = store_painting(table, art_storage, bens_sighting, sub="ben")
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    _put_ok(client, issuer, "ada", _find(art=_painted(bens)), sighting)
    assert _stored_art(table, sighting) == ("pack", PACK["key"])
    assert bens in art_storage.art


def test_only_painted_art_falls_back_and_only_to_pack_art(client: TestClient, issuer: TestIssuer) -> None:
    _, on_pack = _put(client, issuer, "ada", _find(art={**PACK, "fallback": PACK}))
    assert on_pack.status_code == 422
    painted_fallback = _painted("art/ada/x.jpg", fallback={"kind": "painted", "key": "art/ada/y.jpg"})
    _, on_painted = _put(client, issuer, "ada", _find(art=painted_fallback))
    assert on_painted.status_code == 422


def test_the_secret_spot_and_no_coordinate_rules_hold_with_a_painting(client: TestClient, issuer: TestIssuer) -> None:
    secret = _find(art=_painted("art/ada/never-held.jpg"), threatened=True, place="Griffith Park")
    _, threatened = _put(client, issuer, "ada", secret)
    assert threatened.status_code == 201, threatened.text
    assert threatened.json()["place"] == "a secret spot"
    _, coordinate = _put(client, issuer, "ada", {**_find(art=_painted("art/ada/x.jpg")), "latitude": 34.1})
    assert coordinate.status_code == 422


# A painting no find shows any more is deleted.


def test_new_art_on_the_find_deletes_the_painting(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    circle = _circle(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    key = store_painting(table, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=PACK), sighting)
    assert key not in art_storage.art
    assert _art_in_feed(client, issuer, circle, sighting)["key"] == PACK["key"]


def test_a_put_with_no_art_deletes_the_painting(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    """A new phone's find of a bird with no patch yet: it sends no art."""
    circle = _circle(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    key = store_painting(table, art_storage, sighting)
    _put_ok(client, issuer, "ada", _find(art=None), sighting)
    assert key not in art_storage.art
    assert _art_in_feed(client, issuer, circle, sighting) is None


def test_deleting_the_find_deletes_its_painting(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    key = store_painting(table, art_storage, sighting)
    assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada")).status_code == 204
    assert key not in art_storage.art


def test_a_find_stored_with_another_accounts_painting_never_deletes_it(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    """Before #70 a find could name any `art/` key, so a stored one may name someone else's."""
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    bens = store_painting(table, art_storage, sighting, painted_for="ben")
    _put_ok(client, issuer, "ada", _find(art=PACK), sighting)
    assert bens in art_storage.art
    second = _put_ok(client, issuer, "ada", _find(art=PACK))
    store = store_painting(table, art_storage, second, painted_for="ben")
    assert client.delete(f"/v1/finds/{second}", headers=issuer.headers(sub="ada")).status_code == 204
    assert store in art_storage.art


def test_a_shared_card_with_new_art_deletes_the_painting(
    client: TestClient, issuer: TestIssuer, table: Any, art_storage: FakeArtStorage
) -> None:
    circle = _circle(client, issuer)
    sighting = _put_ok(client, issuer, "ada", _find(art=PACK))
    key = store_painting(table, art_storage, sighting)
    body = {"find": _find(art=PACK), "circle_ids": [circle]}
    response = client.put(f"/v1/finds/{sighting}/card", headers=issuer.headers(sub="ada"), json=body)
    assert response.status_code == 200, response.text
    assert key not in art_storage.art
