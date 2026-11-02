"""Cards shared by hand (issue #66): a find with the extras the birder chose (the note, the caption, the original
photo, the city or no place), stored and shown only in the circles chosen; the only way a private birder's sighting
reaches a circle; and the original photo's upload, its keep and its deletion."""

from collections.abc import Iterator
from dataclasses import replace
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.settings import Settings
from tests.conftest import Clock
from tests.photos import MemoryPhotoStore
from tests.test_circles import _create, _join
from tests.test_finds import _feed, _find, _put_ok
from tests.tokens import TestIssuer

CDN = "https://d111.cloudfront.net"


@pytest.fixture
def photos() -> MemoryPhotoStore:
    return MemoryPhotoStore()


@pytest.fixture
def cards(settings: Settings, issuer: TestIssuer, clock: Clock, photos: MemoryPhotoStore) -> Iterator[TestClient]:
    app = create_app(replace(settings, art_cdn_base_url=CDN), signing_key=issuer.signing_key, clock=clock, photos=photos)
    with TestClient(app) as client:
        yield client


def _circles(client: TestClient, issuer: TestIssuer) -> tuple[str, str]:
    """Ada in two circles: Sunday (with Ben) and Family (with Cal)."""
    for sub, name in (("ada", "Ada"), ("ben", "Ben"), ("cal", "Cal")):
        client.patch("/v1/account", headers=issuer.headers(sub=sub), json={"display_name": name})
    sunday = _create(client, issuer, sub="ada", name="Sunday")["id"]
    _join(client, issuer, sunday, "ben")
    family = _create(client, issuer, sub="ada", name="Family")["id"]
    _join(client, issuer, family, "cal")
    return sunday, family


def _share(
    client: TestClient, issuer: TestIssuer, circle_ids: list[str], sighting_id: str | None = None, sub: str = "ada",
    find: dict[str, Any] | None = None, **extras: Any,
) -> tuple[str, Any]:
    sighting_id = sighting_id or str(uuid4())
    body = {"find": find or _find(), "circle_ids": circle_ids, **extras}
    return sighting_id, client.put(f"/v1/finds/{sighting_id}/card", headers=issuer.headers(sub=sub), json=body)


def _share_ok(client: TestClient, issuer: TestIssuer, circle_ids: list[str], **kwargs: Any) -> str:
    sighting_id, response = _share(client, issuer, circle_ids, **kwargs)
    assert response.status_code in (200, 201), response.text
    return sighting_id


def _item(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str, sighting_id: str) -> dict[str, Any] | None:
    items = _feed(client, issuer, circle_id, sub)["items"]
    return next((item for item in items if item["sighting_id"] == sighting_id), None)


def _upload(client: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore, sub: str = "ada") -> str:
    response = client.post(f"/v1/finds/{uuid4()}/photo", headers=issuer.headers(sub=sub))
    assert response.status_code == 201, response.text
    key: str = response.json()["key"]
    photos.arrive(key)
    return key


def test_extras_show_only_in_the_circles_chosen(cards: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore) -> None:
    sunday, family = _circles(cards, issuer)
    sighting = _put_ok(cards, issuer, "ada", _find())
    photo = _upload(cards, issuer, photos)
    _share_ok(
        cards, issuer, [sunday], sighting_id=sighting, note="On the fence by the creek",
        caption="A small black flame at the water's edge", photo={"key": photo},
    )

    shared = _item(cards, issuer, sunday, "ben", sighting)
    assert shared is not None
    assert shared["card"] == {
        "note": "On the fence by the creek",
        "caption": "A small black flame at the water's edge",
        "photo": {"key": photo, "url": f"{CDN}/{photo}"},
    }
    automatic = _item(cards, issuer, family, "cal", sighting)
    assert automatic is not None
    assert automatic["card"] is None


def test_extras_appear_only_when_chosen(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday])
    item = _item(cards, issuer, sunday, "ben", sighting)
    assert item is not None
    assert item["card"] == {"note": None, "caption": None, "photo": None}
    assert item["place"] == "Pasadena"


def test_a_private_birders_card_reaches_only_the_circles_chosen(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, family = _circles(cards, issuer)
    sighting, response = _share(cards, issuer, [family], note="First one this year")
    assert response.status_code == 201
    assert response.json()["circle_ids"] == [family]
    assert _item(cards, issuer, family, "cal", sighting) is not None
    assert _item(cards, issuer, sunday, "ben", sighting) is None


def test_the_city_off_sends_no_place_in_the_circles_chosen(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, family = _circles(cards, issuer)
    sighting = _put_ok(cards, issuer, "ada", _find())
    _share_ok(cards, issuer, [sunday], sighting_id=sighting, include_place=False)
    assert _item(cards, issuer, sunday, "ben", sighting)["place"] is None  # type: ignore[index]
    # The automatic find in the other circle keeps its city.
    assert _item(cards, issuer, family, "cal", sighting)["place"] == "Pasadena"  # type: ignore[index]


def test_the_city_off_ignores_a_place_that_came_anyway(cards: TestClient, issuer: TestIssuer, table: Any) -> None:
    sunday, _ = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday], include_place=False, find=_find(place="Pasadena"))
    assert _item(cards, issuer, sunday, "ben", sighting)["place"] is None  # type: ignore[index]
    stored = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"FIND#{sighting}"})["Item"]
    assert "place" not in stored


def test_a_later_put_keeps_the_extras_and_the_hidden_place(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday], include_place=False, note="Quiet morning", find=_find(place=None))
    # The outbox corrects Heard to Seen with the policy's automatic payload, city and all.
    _put_ok(cards, issuer, "ada", _find(method="seen"), sighting_id=sighting)
    item = _item(cards, issuer, sunday, "ben", sighting)
    assert item is not None
    assert item["method"] == "seen"
    assert item["place"] is None
    assert item["card"]["note"] == "Quiet morning"


def test_sharing_again_replaces_what_the_circle_shows(cards: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore) -> None:
    sunday, _ = _circles(cards, issuer)
    first = _upload(cards, issuer, photos)
    sighting = _share_ok(cards, issuer, [sunday], note="First note", photo={"key": first})
    _, response = _share(cards, issuer, [sunday], sighting_id=sighting, note="Second note")
    assert response.status_code == 200
    item = _item(cards, issuer, sunday, "ben", sighting)
    assert item is not None
    assert item["card"] == {"note": "Second note", "caption": None, "photo": None}
    assert len(_feed(cards, issuer, sunday, "ben")["items"]) == 1
    # Nothing shows the first photo any more, so it is gone.
    assert first in photos.deleted


def test_a_photo_still_shown_in_another_circle_stays(cards: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore) -> None:
    sunday, family = _circles(cards, issuer)
    photo = _upload(cards, issuer, photos)
    sighting = _share_ok(cards, issuer, [sunday, family], photo={"key": photo})
    _share_ok(cards, issuer, [sunday], sighting_id=sighting)
    assert photo not in photos.deleted
    assert _item(cards, issuer, family, "cal", sighting)["card"]["photo"]["key"] == photo  # type: ignore[index]


def test_sharing_to_a_new_circle_adds_it_to_the_find(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, family = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday])
    _, response = _share(cards, issuer, [family], sighting_id=sighting)
    assert sorted(response.json()["circle_ids"]) == sorted([sunday, family])
    # A delete then takes it out of both.
    cards.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada"))
    assert _item(cards, issuer, sunday, "ben", sighting) is None
    assert _item(cards, issuer, family, "cal", sighting) is None


def test_a_circle_the_birder_isnt_in_is_refused_and_nothing_is_written(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    elsewhere = _create(cards, issuer, sub="ben", name="Ben's own")["id"]
    sighting, response = _share(cards, issuer, [sunday, elsewhere])
    assert response.status_code == 404
    assert _item(cards, issuer, sunday, "ben", sighting) is None
    _, response = _share(cards, issuer, ["no-such-circle"])
    assert response.status_code == 404


def test_at_least_one_circle(cards: TestClient, issuer: TestIssuer) -> None:
    _circles(cards, issuer)
    _, response = _share(cards, issuer, [])
    assert response.status_code == 422


def test_the_photo_is_kept_once_shared_and_deleted_with_the_find(
    cards: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore, table: Any
) -> None:
    sunday, _ = _circles(cards, issuer)
    photo = _upload(cards, issuer, photos)
    assert photo in photos.pending
    sighting = _share_ok(cards, issuer, [sunday], photo={"key": photo})
    assert photo not in photos.pending
    cards.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada"))
    assert photo in photos.deleted
    shares = table.query(
        KeyConditionExpression="pk = :pk", ExpressionAttributeValues={":pk": f"FIND#ada#{sighting}"}
    )["Items"]
    assert shares == []


def test_an_upload_url_names_the_birders_own_prefix(cards: TestClient, issuer: TestIssuer) -> None:
    response = cards.post(f"/v1/finds/{uuid4()}/photo", headers=issuer.headers(sub="ada"))
    body = response.json()
    assert body["key"].startswith("photos/ada/")
    assert body["key"].endswith(".jpg")
    assert body["headers"] == {"Content-Type": "image/jpeg", "x-amz-tagging": "pending=true"}
    assert body["expires_at"] == "2026-11-01T09:45:00Z"


@pytest.mark.parametrize(
    "key",
    [
        "photos/ben/abcdefghijklmnopqrstuvwx.jpg",
        "art/ada/abcdefghijklmnopqrstuvwx.jpg",
        "photos/ada/../ben/abcdefghijklmnopqrstuvwx.jpg",
        "photos/ada/short.jpg",
        "photos/ada/abcdefghijklmnopqrstuvwx.png",
    ],
)
def test_a_photo_key_must_be_the_birders_own_upload(
    cards: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore, key: str
) -> None:
    sunday, _ = _circles(cards, issuer)
    photos.arrive(key)
    _, response = _share(cards, issuer, [sunday], photo={"key": key})
    assert response.status_code == 422


def test_a_photo_that_never_arrived_is_refused(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    response = cards.post(f"/v1/finds/{uuid4()}/photo", headers=issuer.headers(sub="ada"))
    _, shared = _share(cards, issuer, [sunday], photo={"key": response.json()["key"]})
    assert shared.status_code == 422
    assert shared.json()["detail"] == "photo_missing"


def test_a_photo_too_large_is_refused_and_deleted(cards: TestClient, issuer: TestIssuer, photos: MemoryPhotoStore) -> None:
    sunday, _ = _circles(cards, issuer)
    response = cards.post(f"/v1/finds/{uuid4()}/photo", headers=issuer.headers(sub="ada"))
    key = response.json()["key"]
    photos.arrive(key, size=6 * 1024 * 1024)
    _, shared = _share(cards, issuer, [sunday], photo={"key": key})
    assert shared.status_code == 422
    assert key in photos.deleted


def test_without_an_art_bucket_photos_are_unavailable(client: TestClient, issuer: TestIssuer) -> None:
    response = client.post(f"/v1/finds/{uuid4()}/photo", headers=issuer.headers(sub="ada"))
    assert response.status_code == 503
    # A card without a photo still shares.
    sunday, _ = _circles(client, issuer)
    _, shared = _share(client, issuer, [sunday], note="No photo")
    assert shared.status_code == 201
    _, with_photo = _share(client, issuer, [sunday], photo={"key": "photos/ada/abcdefghijklmnopqrstuvwx.jpg"})
    assert with_photo.status_code == 503


@pytest.mark.parametrize(
    "extras",
    [
        {"note": "x" * 2001},
        {"caption": "x" * 301},
        {"note": "bell\u0007"},
        {"latitude": 34.1},
        {"location": "34.1478, -118.1445"},
    ],
)
def test_malformed_extras_are_refused(cards: TestClient, issuer: TestIssuer, extras: dict[str, Any]) -> None:
    sunday, _ = _circles(cards, issuer)
    _, response = _share(cards, issuer, [sunday], **extras)
    assert response.status_code == 422


def test_a_coordinate_in_the_card_is_refused(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    _, response = _share(cards, issuer, [sunday], find=_find(place="34.1478, -118.1445"))
    assert response.status_code == 422
    _, response = _share(cards, issuer, [sunday], find={**_find(), "latitude": 34.1})
    assert response.status_code == 422


def test_a_note_keeps_its_line_breaks(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday], note="  Two calls.\nThen a third.  ")
    assert _item(cards, issuer, sunday, "ben", sighting)["card"]["note"] == "Two calls.\nThen a third."  # type: ignore[index]


def test_a_threatened_species_card_stays_at_a_secret_spot(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday], find=_find(place="Pasadena", threatened=True))
    assert _item(cards, issuer, sunday, "ben", sighting)["place"] == "a secret spot"  # type: ignore[index]


def test_only_the_owner_shares_their_sighting(cards: TestClient, issuer: TestIssuer) -> None:
    sunday, _ = _circles(cards, issuer)
    sighting = _share_ok(cards, issuer, [sunday], note="Ada's")
    # Ben sharing the same id writes his own card, never Ada's.
    _share_ok(cards, issuer, [sunday], sighting_id=sighting, sub="ben", note="Ben's")
    items = [item for item in _feed(cards, issuer, sunday, "ada")["items"] if item["sighting_id"] == sighting]
    assert sorted(item["card"]["note"] for item in items) == ["Ada's", "Ben's"]


def test_cards_need_a_token(cards: TestClient) -> None:
    assert cards.put(f"/v1/finds/{uuid4()}/card", json={}).status_code == 401
    assert cards.post(f"/v1/finds/{uuid4()}/photo").status_code == 401
