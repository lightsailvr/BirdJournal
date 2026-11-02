"""Pushes (issue #63) through the API with a fake APNs: devices, the notable-versus-digest decision, digest timing and
text, mutes, owner exclusion, and the scheduled flush."""

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.finds import FindContent, Method
from birdjournal_api.handler import make_handler
from birdjournal_api.pushes import PushKind, digest_words
from birdjournal_api.settings import Settings
from tests.conftest import Clock, FakeApns
from tests.test_circles import _create, _join
from tests.test_finds import GNATCATCHER, PHOEBE, WREN, _find, _put, _put_ok
from tests.tokens import TestIssuer

ADA_PHONE = "a" * 64
BO_PHONE = "b" * 64
BO_IPAD = "b0" * 32
CY_PHONE = "c" * 64

SPECIES = [
    {"species_id": f"Genus{n} species_Bird {n}", "scientific_name": f"Genus{n} species", "common_name": f"Bird {n}"}
    for n in range(10)
]


def _name(client: TestClient, issuer: TestIssuer, sub: str, name: str) -> None:
    assert client.patch("/v1/account", headers=issuer.headers(sub=sub), json={"display_name": name}).status_code == 200


def _register(client: TestClient, issuer: TestIssuer, sub: str, token: str, environment: str = "sandbox") -> Any:
    return client.put(f"/v1/account/devices/{token}", headers=issuer.headers(sub=sub), json={"environment": environment})


def _flush(client: TestClient) -> Any:
    return client.app.state.pushes.flush_digests()  # type: ignore[attr-defined]


@pytest.fixture
def circle(client: TestClient, issuer: TestIssuer, apns: FakeApns) -> str:
    """Ada's Sunday group with Bo and Cy, every one named and with a phone; the circle's first Black Phoebe, Wren and
    Gnatcatcher are already found, by Cy, so later ones are ordinary."""
    circle_id = str(_create(client, issuer, sub="ada")["id"])
    _join(client, issuer, circle_id, "bo")
    _join(client, issuer, circle_id, "cy")
    # Before any phone registers, so these firsts push to nobody and start no one's two hours.
    for species in (PHOEBE, WREN, GNATCATCHER, *SPECIES):
        _put_ok(client, issuer, "cy", _find(species, found_at="2026-10-01T08:00:00Z"))
    for sub, name, phone in (("ada", "Ada Lovelace", ADA_PHONE), ("bo", "Bo", BO_PHONE), ("cy", "Cy", CY_PHONE)):
        _name(client, issuer, sub, name)
        assert _register(client, issuer, sub, phone).status_code == 204
    apns.clear()
    return circle_id


def _alerts(apns: FakeApns, token: str) -> list[Any]:
    return [push for push in apns.to(token) if not push.is_silent]


# Devices.


def test_a_device_registers_with_its_environment(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    assert _register(client, issuer, "ada", ADA_PHONE.upper(), "production").status_code == 204
    item = table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"DEVICE#{ADA_PHONE}"})["Item"]
    assert item["environment"] == "production"
    assert item["token"] == ADA_PHONE


def test_a_phone_signed_into_another_account_leaves_the_first(client: TestClient, issuer: TestIssuer, table: Any) -> None:
    _register(client, issuer, "ada", ADA_PHONE)
    _register(client, issuer, "bo", ADA_PHONE)
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#ada", "sk": f"DEVICE#{ADA_PHONE}"})
    assert "Item" in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"DEVICE#{ADA_PHONE}"})


def test_unregistering_stops_the_account_s_pushes_and_leaves_another_s(
    client: TestClient, issuer: TestIssuer, table: Any
) -> None:
    _register(client, issuer, "ada", ADA_PHONE)
    _register(client, issuer, "bo", ADA_PHONE)
    # Ada's stale sign-out arrives after Bo took the phone: Bo keeps it.
    assert client.delete(f"/v1/account/devices/{ADA_PHONE}", headers=issuer.headers(sub="ada")).status_code == 204
    assert "Item" in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"DEVICE#{ADA_PHONE}"})
    assert client.delete(f"/v1/account/devices/{ADA_PHONE}", headers=issuer.headers(sub="bo")).status_code == 204
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"DEVICE#{ADA_PHONE}"})
    assert "Item" not in table.get_item(Key={"pk": f"DEVICE#{ADA_PHONE}", "sk": "DEVICE"})


@pytest.mark.parametrize("token", ["xyz", "a" * 63, "g" * 64, "a" * 201])
def test_a_bad_token_is_refused(client: TestClient, issuer: TestIssuer, token: str) -> None:
    assert _register(client, issuer, "ada", token).status_code == 422


def test_a_bad_environment_or_no_access_token_is_refused(client: TestClient, issuer: TestIssuer) -> None:
    assert _register(client, issuer, "ada", ADA_PHONE, "staging").status_code == 422
    assert client.put(f"/v1/account/devices/{ADA_PHONE}", json={"environment": "sandbox"}).status_code == 401


# The notable-versus-digest decision.


def test_a_legendary_pushes_at_once_to_every_friend_with_the_find(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    _register(client, issuer, "bo", BO_IPAD, "production")
    sighting = _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    for token in (BO_PHONE, BO_IPAD, CY_PHONE):
        (push,) = apns.to(token)
        assert push.kind is PushKind.NOTABLE
    push = apns.to(BO_PHONE)[0]
    payload = push.payload()
    assert payload["aps"]["alert"] == {"title": "Ada Lovelace found a Black Phoebe", "body": "Legendary · Pasadena"}
    assert payload["aps"]["content-available"] == 1
    assert payload["aps"]["thread-id"] == "friend-ada"
    assert payload["find"] == {
        "owner": "ada",
        "owner_name": "Ada Lovelace",
        "sighting_id": sighting,
        "species_id": PHOEBE["species_id"],
        "scientific_name": "Sayornis nigricans",
        "common_name": "Black Phoebe",
        "method": "heard",
        "place": "Pasadena",
        "found_at": "2026-11-01T08:15:00Z",
        "legendary": True,
        "rarity": "common",
        "circle_first": False,
        "circle_ids": [circle],
    }
    environments = {device.token: device.environment.value for device, _ in apns.sent}
    assert environments[BO_IPAD] == "production" and environments[BO_PHONE] == "sandbox"


def test_the_owner_is_never_pushed_about_their_own_find(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    _put_ok(client, issuer, "ada", _find(PHOEBE))
    assert apns.to(ADA_PHONE) == []
    _flush(client)
    assert apns.to(ADA_PHONE) == []


@pytest.mark.parametrize(("rarity", "notable"), [("rare", True), ("exceptional", True), ("uncommon", False), ("common", False), (None, False)])
def test_rare_and_exceptional_are_notable(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, rarity: str | None, notable: bool
) -> None:
    _put_ok(client, issuer, "ada", _find(PHOEBE, rarity=rarity))
    (push,) = apns.to(BO_PHONE)
    assert push.kind is (PushKind.NOTABLE if notable else PushKind.REFRESH)
    if notable:
        assert push.payload()["aps"]["alert"]["body"] == f"{rarity.capitalize()} · Pasadena"  # type: ignore[union-attr]


def test_a_circle_first_is_notable_and_the_next_of_its_species_is_not(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    robin = {"species_id": "Turdus migratorius_American Robin", "scientific_name": "Turdus migratorius", "common_name": "American Robin"}
    _put_ok(client, issuer, "ada", _find(robin, place=None))
    (push,) = apns.to(BO_PHONE)
    assert push.kind is PushKind.NOTABLE
    assert push.payload()["aps"]["alert"] == {"title": "Ada Lovelace found an American Robin", "body": "First for Sunday group"}
    assert push.payload()["find"]["circle_first"] is True
    apns.clear()
    _put_ok(client, issuer, "bo", _find(robin, found_at="2026-11-01T09:00:00Z"))
    (push,) = apns.to(CY_PHONE)
    assert push.kind is PushKind.REFRESH


def test_a_find_published_late_from_earlier_still_takes_the_first(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    robin = {"species_id": "Turdus migratorius_American Robin", "scientific_name": "Turdus migratorius", "common_name": "American Robin"}
    _put_ok(client, issuer, "bo", _find(robin, found_at="2026-11-01T09:00:00Z"))
    apns.clear()
    # Ada's offline find from earlier in the morning reaches the server later: it is now the circle's first.
    _put_ok(client, issuer, "ada", _find(robin, found_at="2026-11-01T07:00:00Z"))
    assert apns.to(CY_PHONE)[0].kind is PushKind.NOTABLE


def test_a_repeated_put_sends_nothing(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> None:
    sighting = _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    apns.clear()
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True, method="seen"), sighting)
    assert apns.sent == []


def test_a_friend_in_two_circles_hears_once(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> None:
    second = str(_create(client, issuer, sub="ada", name="Weekday walkers")["id"])
    _join(client, issuer, second, "bo")
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    assert len(apns.to(BO_PHONE)) == 1
    assert set(apns.to(BO_PHONE)[0].payload()["find"]["circle_ids"]) == {circle, second}


def test_a_friend_without_a_phone_gets_nothing_and_nothing_waits(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, table: Any
) -> None:
    client.delete(f"/v1/account/devices/{BO_PHONE}", headers=issuer.headers(sub="bo"))
    _put_ok(client, issuer, "ada", _find(PHOEBE))
    assert "Item" not in table.get_item(Key={"pk": "DIGEST", "sk": "bo#ada"})


def test_a_member_who_left_hears_nothing(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> None:
    assert client.delete(f"/v1/circles/{circle}/members/me", headers=issuer.headers(sub="bo")).status_code == 204
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    assert apns.to(BO_PHONE) == []
    assert len(apns.to(CY_PHONE)) == 1


def test_a_token_apns_calls_gone_is_forgotten(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, table: Any
) -> None:
    apns.gone.add(BO_PHONE)
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    assert "Item" not in table.get_item(Key={"pk": "ACCOUNT#bo", "sk": f"DEVICE#{BO_PHONE}"})
    assert "Item" not in table.get_item(Key={"pk": f"DEVICE#{BO_PHONE}", "sk": "DEVICE"})


def test_a_failing_apns_never_fails_the_put(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> None:
    def broken(*_: Any) -> Any:
        raise RuntimeError("APNs is down")

    apns.send = broken  # type: ignore[method-assign]
    _, response = _put(client, issuer, "ada", _find(PHOEBE, legendary=True))
    assert response.status_code == 201


# The digest.


def test_an_ordinary_find_refreshes_silently_and_waits_for_the_digest(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    _put_ok(client, issuer, "ada", _find(PHOEBE))
    (push,) = apns.to(BO_PHONE)
    assert push.kind is PushKind.REFRESH
    assert push.payload() == {"aps": {"content-available": 1}, "kind": "refresh", "circle_ids": [circle]}
    apns.clear()
    report = _flush(client)
    assert report.sent == 2
    (digest,) = apns.to(BO_PHONE)
    assert digest.kind is PushKind.DIGEST
    assert digest.payload()["aps"]["alert"] == {"body": "Ada Lovelace found a Black Phoebe in Pasadena"}
    assert digest.payload()["aps"]["content-available"] == 1
    assert digest.collapse_id == "digest-ada"


def test_a_burst_of_ordinary_finds_arrives_as_one_digest(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    places = ["Pasadena", "Pasadena", "Altadena", "Pasadena", "Altadena", "Altadena", "Pasadena"]
    for n, place in enumerate(places[:6]):
        _put_ok(client, issuer, "ada", _find(SPECIES[n], place=place, found_at=f"2026-11-01T08:{10 + n}:00Z"))
    # The same species again: six birds, seven finds.
    _put_ok(client, issuer, "ada", _find(SPECIES[0], place=places[6], found_at="2026-11-01T08:30:00Z"))
    assert _alerts(apns, BO_PHONE) == []
    _flush(client)
    (digest,) = _alerts(apns, BO_PHONE)
    assert digest.body == "Ada Lovelace found 6 birds in Pasadena"
    assert digest.data == {"friend": "ada", "count": 6}
    apns.clear()
    _flush(client)
    assert apns.sent == []


def test_digests_wait_two_hours_after_the_last_push_about_that_friend(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, circle: str
) -> None:
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    clock.now += timedelta(minutes=10)
    _put_ok(client, issuer, "ada", _find(SPECIES[0]))
    _put_ok(client, issuer, "cy", _find(SPECIES[1]))
    apns.clear()
    clock.now += timedelta(minutes=15)
    _flush(client)
    # Bo heard about Ada 25 minutes ago, so Ada's digest waits; nothing about Cy yet, so Cy's goes.
    assert [push.body for push in _alerts(apns, BO_PHONE)] == ["Cy found a Bird 1 in Pasadena"]
    apns.clear()
    clock.now += timedelta(hours=1, minutes=34)
    _flush(client)
    assert _alerts(apns, BO_PHONE) == []
    clock.now += timedelta(minutes=1)
    _flush(client)
    assert [push.body for push in _alerts(apns, BO_PHONE)] == ["Ada Lovelace found a Bird 0 in Pasadena"]
    # And the next of Ada's waits two hours from this digest.
    apns.clear()
    _put_ok(client, issuer, "ada", _find(SPECIES[2]))
    clock.now += timedelta(hours=1, minutes=59)
    _flush(client)
    assert _alerts(apns, BO_PHONE) == []
    clock.now += timedelta(minutes=1)
    _flush(client)
    assert len(_alerts(apns, BO_PHONE)) == 1


def test_a_secret_spot_is_never_named_and_no_place_ends_at_the_birds(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    for n in range(3):
        _put_ok(client, issuer, "ada", _find(SPECIES[n], threatened=True, place="Pasadena"))
    _put_ok(client, issuer, "ada", _find(SPECIES[3], place=None))
    _flush(client)
    (digest,) = _alerts(apns, BO_PHONE)
    assert digest.body == "Ada Lovelace found 4 birds"


def test_a_find_deleted_before_the_flush_is_left_out(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, table: Any
) -> None:
    kept = _put_ok(client, issuer, "ada", _find(SPECIES[0], place="Altadena"))
    gone = _put_ok(client, issuer, "ada", _find(SPECIES[1], place="Pasadena"))
    assert client.delete(f"/v1/finds/{gone}", headers=issuer.headers(sub="ada")).status_code == 204
    _flush(client)
    assert [push.body for push in _alerts(apns, BO_PHONE)] == ["Ada Lovelace found a Bird 0 in Altadena"]
    assert kept


def test_a_buffer_whose_finds_are_all_gone_sends_nothing(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, table: Any
) -> None:
    gone = _put_ok(client, issuer, "ada", _find(SPECIES[0]))
    client.delete(f"/v1/finds/{gone}", headers=issuer.headers(sub="ada"))
    apns.clear()
    report = _flush(client)
    assert apns.sent == []
    assert report.dropped == 2
    assert "Item" not in table.get_item(Key={"pk": "DIGEST", "sk": "bo#ada"})


def test_an_unnamed_friend_is_a_friend(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> None:
    _join(client, issuer, circle, "di")
    _put_ok(client, issuer, "di", _find(SPECIES[0]))
    _flush(client)
    assert [push.body for push in _alerts(apns, BO_PHONE)] == ["A friend found a Bird 0 in Pasadena"]


def test_a_notable_push_names_only_the_recipient_s_circles(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    second = str(_create(client, issuer, sub="ada", name="Weekday walkers")["id"])
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    # Bo isn't in the weekday circle: his push doesn't name it.
    assert apns.to(BO_PHONE)[0].payload()["find"]["circle_ids"] == [circle]
    assert second


# Mutes.


def test_muting_the_circle_a_buffered_find_came_through_drops_it_though_another_is_shared(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, table: Any
) -> None:
    _put_ok(client, issuer, "ada", _find(SPECIES[0]))
    second = str(_create(client, issuer, sub="ada", name="Weekday walkers")["id"])
    _join(client, issuer, second, "bo")
    client.put(f"/v1/circles/{circle}/mute", headers=issuer.headers(sub="bo"))
    apns.clear()
    _flush(client)
    assert apns.to(BO_PHONE) == []
    assert "Item" not in table.get_item(Key={"pk": "DIGEST", "sk": "bo#ada"})


def test_a_muted_friend_sends_nothing(client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str) -> None:
    assert client.put("/v1/friends/ada/mute", headers=issuer.headers(sub="bo")).status_code == 204
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    _put_ok(client, issuer, "ada", _find(SPECIES[0]))
    _flush(client)
    assert apns.to(BO_PHONE) == []
    assert apns.to(CY_PHONE) != []
    assert client.delete("/v1/friends/ada/mute", headers=issuer.headers(sub="bo")).status_code == 204
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True, found_at="2026-11-01T09:00:00Z"))
    assert len(apns.to(BO_PHONE)) == 1


def test_a_muted_circle_sends_nothing_unless_another_circle_carries_the_find(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    assert client.put(f"/v1/circles/{circle}/mute", headers=issuer.headers(sub="bo")).status_code == 204
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True))
    assert apns.to(BO_PHONE) == []
    second = str(_create(client, issuer, sub="ada", name="Weekday walkers")["id"])
    _join(client, issuer, second, "bo")
    _put_ok(client, issuer, "ada", _find(PHOEBE, legendary=True, found_at="2026-11-01T09:00:00Z"))
    (push,) = apns.to(BO_PHONE)
    assert push.kind is PushKind.NOTABLE


def test_a_circle_first_only_in_a_muted_circle_is_not_notable(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str
) -> None:
    second = str(_create(client, issuer, sub="ada", name="Weekday walkers")["id"])
    _join(client, issuer, second, "bo")
    _put_ok(client, issuer, "cy", _find(SPECIES[5], found_at="2026-10-01T08:00:00Z"))
    client.put(f"/v1/circles/{second}/mute", headers=issuer.headers(sub="bo"))
    apns.clear()
    # The Bird 5 is a first in the weekday circle only (Cy found one in Sunday's), which Bo muted.
    _put_ok(client, issuer, "ada", _find(SPECIES[5]))
    (push,) = apns.to(BO_PHONE)
    assert push.kind is PushKind.REFRESH


def test_a_mute_after_the_find_drops_its_digest(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, circle: str, table: Any
) -> None:
    _put_ok(client, issuer, "ada", _find(SPECIES[0]))
    client.put("/v1/friends/ada/mute", headers=issuer.headers(sub="bo"))
    apns.clear()
    _flush(client)
    assert apns.to(BO_PHONE) == []
    assert "Item" not in table.get_item(Key={"pk": "DIGEST", "sk": "bo#ada"})


def test_mutes_are_listed_and_kept_to_the_birder_s_circles_and_friends(
    client: TestClient, issuer: TestIssuer, circle: str
) -> None:
    bo = issuer.headers(sub="bo")
    client.put(f"/v1/circles/{circle}/mute", headers=bo)
    client.put("/v1/friends/cy/mute", headers=bo)
    assert client.get("/v1/mutes", headers=bo).json() == {"circles": [circle], "friends": ["cy"]}
    # Someone else's circle, a stranger, oneself.
    other = str(_create(client, issuer, sub="zed", name="Elsewhere")["id"])
    assert client.put(f"/v1/circles/{other}/mute", headers=bo).status_code == 404
    assert client.put("/v1/friends/zed/mute", headers=bo).status_code == 404
    assert client.put("/v1/friends/bo/mute", headers=bo).status_code == 422
    client.delete(f"/v1/circles/{circle}/mute", headers=bo)
    client.delete("/v1/friends/cy/mute", headers=bo)
    assert client.get("/v1/mutes", headers=bo).json() == {"circles": [], "friends": []}


# The scheduled job.


def test_the_schedule_s_event_flushes_the_digests(
    settings: Settings, issuer: TestIssuer, clock: Clock, apns: FakeApns
) -> None:
    app = create_app(settings, signing_key=issuer.signing_key, clock=clock, push_sender=apns)
    with TestClient(app) as client:
        circle_id = str(_create(client, issuer, sub="ada")["id"])
        _join(client, issuer, circle_id, "bo")
        _register(client, issuer, "bo", BO_PHONE)
        _put_ok(client, issuer, "ada", _find(SPECIES[0], found_at="2026-10-01T08:00:00Z"))
        _put_ok(client, issuer, "ada", _find(SPECIES[0]))
    handler = make_handler(app)
    apns.clear()
    # The first was the circle's first Bird 0, a notable push: the digest waits two hours from it.
    clock.now += timedelta(hours=2)
    assert handler({"birdjournal_job": "flush_digests"}, None) == {"sent": 1, "waiting": 0, "dropped": 0}
    assert [push.kind for push in apns.to(BO_PHONE)] == [PushKind.DIGEST]
    with pytest.raises(ValueError):
        handler({"birdjournal_job": "rollover_goals"}, None)


# The words.


def _content(common: str, scientific: str, place: str | None, minute: int) -> FindContent:
    return FindContent(
        species_id=f"{scientific}_{common}", scientific_name=scientific, common_name=common, method=Method.HEARD,
        place=place, found_at=datetime(2026, 11, 1, 8, minute, tzinfo=UTC), legendary=False, rarity=None,
        threatened=False, art=None,
    )


def test_a_tie_between_places_goes_to_where_the_friend_was_last() -> None:
    finds = [_content("A", "a a", "Pasadena", 1), _content("B", "b b", "Altadena", 2)]
    assert digest_words("Maya", finds) == "Maya found 2 birds in Altadena"
    assert digest_words("Maya", list(reversed(finds))) == "Maya found 2 birds in Altadena"


def test_one_species_is_named_with_its_article() -> None:
    assert digest_words("Maya", [_content("Oak Titmouse", "b i", "Ojai", 1)]) == "Maya found an Oak Titmouse in Ojai"
    assert digest_words(None, [_content("Wren", "t a", None, 1)] * 3) == "A friend found a Wren"
