"""Goals (issue #65) through the API: the monthly rollover and its target (time zones at month boundaries included),
custom goals and who may delete them, distinct counting, a delete reducing progress, and completion pushed once."""

from datetime import UTC, datetime
from typing import Any

import pytest
from fastapi.testclient import TestClient

from birdjournal_api.app import create_app
from birdjournal_api.goals import monthly_target
from birdjournal_api.handler import make_handler
from birdjournal_api.pushes import PushKind
from birdjournal_api.settings import Settings
from tests.conftest import Clock, FakeApns
from tests.test_circles import _join
from tests.test_finds import _find, _put_ok
from tests.test_pushes import _name, _register
from tests.tokens import TestIssuer

ADA_PHONE = "a" * 64
BO_PHONE = "b" * 64
CY_PHONE = "c" * 64

SPECIES = [
    {"species_id": f"Genus{n} species_Bird {n}", "scientific_name": f"Genus{n} species", "common_name": f"Bird {n}"}
    for n in range(40)
]


def _circle(client: TestClient, issuer: TestIssuer, sub: str = "ada", time_zone: str = "America/Los_Angeles") -> str:
    response = client.post(
        "/v1/circles", headers=issuer.headers(sub=sub), json={"name": "Sunday Group", "time_zone": time_zone}
    )
    assert response.status_code == 201, response.text
    return str(response.json()["id"])


def _goals(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str = "ada") -> list[dict[str, Any]]:
    response = client.get(f"/v1/circles/{circle_id}/goals", headers=issuer.headers(sub=sub))
    assert response.status_code == 200, response.text
    goals: list[dict[str, Any]] = response.json()["goals"]
    return goals


def _monthly(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str = "ada") -> dict[str, Any]:
    (goal,) = [goal for goal in _goals(client, issuer, circle_id, sub) if goal["kind"] == "monthly"]
    return goal


def _create_goal(
    client: TestClient, issuer: TestIssuer, circle_id: str, sub: str = "ada", **overrides: Any
) -> Any:
    body = {"title": "Big Day", "target": 3, "start_date": "2026-11-01", "end_date": "2026-11-07", **overrides}
    return client.post(f"/v1/circles/{circle_id}/goals", headers=issuer.headers(sub=sub), json=body)


def _goal_ok(client: TestClient, issuer: TestIssuer, circle_id: str, sub: str = "ada", **overrides: Any) -> dict[str, Any]:
    response = _create_goal(client, issuer, circle_id, sub, **overrides)
    assert response.status_code == 201, response.text
    goal: dict[str, Any] = response.json()
    return goal


def _delete_goal(client: TestClient, issuer: TestIssuer, circle_id: str, goal_id: str, sub: str) -> int:
    response = client.delete(f"/v1/circles/{circle_id}/goals/{goal_id}", headers=issuer.headers(sub=sub))
    return response.status_code


def _custom(client: TestClient, issuer: TestIssuer, circle_id: str, goal_id: str, sub: str = "ada") -> dict[str, Any]:
    (goal,) = [goal for goal in _goals(client, issuer, circle_id, sub) if goal["id"] == goal_id]
    return goal


def _roll_over(client: TestClient) -> Any:
    return client.app.state.goals.roll_over()  # type: ignore[attr-defined]


def _species_finds(client: TestClient, issuer: TestIssuer, sub: str, count: int, found_at: str, start: int = 0) -> list[str]:
    return [
        _put_ok(client, issuer, sub, _find(SPECIES[n], found_at=found_at)) for n in range(start, start + count)
    ]


# The target's arithmetic.


@pytest.mark.parametrize(
    ("last_month", "target"),
    [(None, 10), (0, 5), (2, 5), (4, 5), (5, 6), (10, 12), (12, 14), (20, 23), (30, 35), (100, 115)],
)
def test_the_target_is_the_larger_of_5_and_115_percent_rounded_or_10_in_the_first_month(
    last_month: int | None, target: int
) -> None:
    # 10 × 1.15 = 11.5 rounds up to 12; 20 × 1.15 is exactly 23 (in floating point it is 22.999…).
    assert monthly_target(last_month) == target


# The automatic monthly goal.


def test_a_new_circle_chases_10_species_in_its_first_month(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    goal = _monthly(client, issuer, circle_id)
    assert goal["title"] == "October goal"
    assert goal["target"] == 10
    assert (goal["start_date"], goal["end_date"]) == ("2026-10-01", "2026-10-31")
    # Midnight in Los Angeles (PDT) both ends.
    assert (goal["starts_at"], goal["ends_at"]) == ("2026-10-01T07:00:00Z", "2026-11-01T07:00:00Z")
    assert goal["progress"] == 0 and goal["status"] == "active"
    assert goal["created_by"] is None and goal["can_delete"] is False


def test_the_rollover_sizes_next_month_from_last_month_s_distinct_species_in_the_circle_s_zone(
    client: TestClient, issuer: TestIssuer, clock: Clock
) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    _join(client, issuer, circle_id, "bo")
    # Twelve species in October, Los Angeles time: the last at 23:59 on the 31st (06:59 UTC on 1 November).
    _species_finds(client, issuer, "ada", 11, "2026-10-10T16:00:00Z")
    _species_finds(client, issuer, "bo", 1, "2026-11-01T06:59:00Z", start=11)
    # Repeats and the same birds by Bo add nothing.
    _species_finds(client, issuer, "bo", 5, "2026-10-20T16:00:00Z")
    _species_finds(client, issuer, "ada", 3, "2026-10-21T16:00:00Z")
    # Midnight on 1 November in Los Angeles is November's: not last month's.
    _species_finds(client, issuer, "bo", 3, "2026-11-01T07:00:00Z", start=20)
    # Before October in Los Angeles (late on 30 September there): not October's.
    _species_finds(client, issuer, "ada", 2, "2026-10-01T06:30:00Z", start=30)

    # 06:50 UTC is still 31 October in Los Angeles: no new goal yet.
    clock.now = datetime(2026, 11, 1, 6, 50, tzinfo=UTC)
    report = _roll_over(client)
    assert (report.created, report.current) == (0, 1)
    assert _monthly(client, issuer, circle_id)["title"] == "October goal"

    clock.now = datetime(2026, 11, 1, 7, 5, tzinfo=UTC)
    assert _roll_over(client).created == 1
    assert _roll_over(client).created == 0
    goal = _monthly(client, issuer, circle_id)
    assert goal["title"] == "November goal"
    # 12 × 1.15 = 13.8.
    assert goal["target"] == 14
    assert (goal["start_date"], goal["end_date"]) == ("2026-11-01", "2026-11-30")
    # Daylight saving ends on 1 November: the month starts at PDT midnight and ends at PST midnight.
    assert (goal["starts_at"], goal["ends_at"]) == ("2026-11-01T07:00:00Z", "2026-12-01T08:00:00Z")
    assert goal["progress"] == 3


def test_each_circle_rolls_over_at_midnight_in_its_own_zone(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    los_angeles = _circle(client, issuer, time_zone="America/Los_Angeles")
    tokyo = _circle(client, issuer, time_zone="Asia/Tokyo")
    kathmandu = _circle(client, issuer, time_zone="Asia/Kathmandu")
    # 15:00 UTC on 31 October: midnight on 1 November in Tokyo (UTC+9); 20:45 in Kathmandu (UTC+5:45).
    clock.now = datetime(2026, 10, 31, 15, 0, tzinfo=UTC)
    assert _roll_over(client).created == 1
    assert _monthly(client, issuer, tokyo)["title"] == "November goal"
    assert _roll_over(client).created == 0
    # 18:15 UTC: 00:00 on 1 November in Kathmandu.
    clock.now = datetime(2026, 10, 31, 18, 15, tzinfo=UTC)
    assert _roll_over(client).created == 1
    goal = _monthly(client, issuer, kathmandu)
    assert goal["title"] == "November goal"
    assert goal["starts_at"] == "2026-10-31T18:15:00Z"
    clock.now = datetime(2026, 11, 1, 7, 0, tzinfo=UTC)
    assert _roll_over(client).created == 1
    assert _monthly(client, issuer, los_angeles)["title"] == "November goal"
    # Second months: no history, so the 5 minimum.
    assert {_monthly(client, issuer, circle)["target"] for circle in (los_angeles, tokyo, kathmandu)} == {5}


def test_the_rollover_crosses_the_year_and_a_quiet_month_gives_5(
    client: TestClient, issuer: TestIssuer, clock: Clock
) -> None:
    clock.now = datetime(2026, 11, 20, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer, time_zone="Europe/London")
    _species_finds(client, issuer, "ada", 30, "2026-12-15T12:00:00Z")
    clock.now = datetime(2027, 1, 1, 0, 0, tzinfo=UTC)
    assert _roll_over(client).created == 1
    goal = _monthly(client, issuer, circle_id)
    assert (goal["title"], goal["target"]) == ("January goal", 35)
    clock.now = datetime(2027, 2, 1, 0, 0, tzinfo=UTC)
    _roll_over(client)
    assert (_monthly(client, issuer, circle_id)["title"], _monthly(client, issuer, circle_id)["target"]) == (
        "February goal",
        5,
    )


def test_reading_the_goals_makes_the_month_s_goal_when_the_job_hasn_t(
    client: TestClient, issuer: TestIssuer, clock: Clock
) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    _species_finds(client, issuer, "ada", 8, "2026-10-10T16:00:00Z")
    clock.now = datetime(2026, 11, 2, 18, 0, tzinfo=UTC)
    goal = _monthly(client, issuer, circle_id)
    assert (goal["title"], goal["target"]) == ("November goal", 9)
    # And the job then finds it made.
    assert _roll_over(client).created == 0


def test_the_target_is_fixed_when_the_goal_is_made(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    sightings = _species_finds(client, issuer, "ada", 10, "2026-10-10T16:00:00Z")
    clock.now = datetime(2026, 11, 2, 18, 0, tzinfo=UTC)
    assert _monthly(client, issuer, circle_id)["target"] == 12
    for sighting in sightings:
        client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada"))
    assert _monthly(client, issuer, circle_id)["target"] == 12


def test_an_empty_circle_is_passed_over(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    assert client.delete(f"/v1/circles/{circle_id}/members/me", headers=issuer.headers(sub="ada")).status_code == 204
    clock.now = datetime(2026, 11, 1, 8, 0, tzinfo=UTC)
    report = _roll_over(client)
    assert (report.created, report.skipped) == (0, 1)
    assert _roll_over(client).current == 1


def test_the_schedule_s_event_rolls_the_goals_over(
    settings: Settings, issuer: TestIssuer, clock: Clock, apns: FakeApns
) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    app = create_app(settings, signing_key=issuer.signing_key, clock=clock, push_sender=apns)
    with TestClient(app) as client:
        circle_id = _circle(client, issuer)
        clock.now = datetime(2026, 11, 1, 7, 0, tzinfo=UTC)
        assert make_handler(app)({"birdjournal_job": "roll_over_goals"}, None) == {
            "created": 1, "current": 0, "skipped": 0,
        }
        assert _monthly(client, issuer, circle_id)["title"] == "November goal"


def test_goals_are_for_members_only(client: TestClient, issuer: TestIssuer) -> None:
    circle_id = _circle(client, issuer)
    assert client.get(f"/v1/circles/{circle_id}/goals", headers=issuer.headers(sub="eve")).status_code == 404
    assert client.get(f"/v1/circles/{circle_id}/goals").status_code == 401
    assert _create_goal(client, issuer, circle_id, sub="eve").status_code == 404
    assert client.get("/v1/circles/nope/goals", headers=issuer.headers(sub="ada")).status_code == 404


# Custom goals.


def test_any_member_makes_a_custom_goal(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    circle_id = _circle(client, issuer)
    _join(client, issuer, circle_id, "bo")
    _name(client, issuer, "bo", "Bo")
    goal = _goal_ok(client, issuer, circle_id, sub="bo", title="  Big Day in Ojai ", target=40,
                    start_date="2026-11-07", end_date="2026-11-07")
    assert goal["kind"] == "custom"
    assert (goal["title"], goal["target"]) == ("Big Day in Ojai", 40)
    assert (goal["start_date"], goal["end_date"]) == ("2026-11-07", "2026-11-07")
    # One day, midnight to midnight in Los Angeles (PST after 1 November).
    assert (goal["starts_at"], goal["ends_at"]) == ("2026-11-07T08:00:00Z", "2026-11-08T08:00:00Z")
    assert goal["status"] == "upcoming" and goal["progress"] == 0 and goal["completed_at"] is None
    assert goal["created_by"] == {"id": "bo", "display_name": "Bo"}
    assert goal["can_delete"] is True
    # Ada sees it, and as the circle's creator may delete it too.
    listed = _custom(client, issuer, circle_id, goal["id"], sub="ada")
    assert listed["can_delete"] is True
    _join(client, issuer, circle_id, "cy")
    assert _custom(client, issuer, circle_id, goal["id"], sub="cy")["can_delete"] is False


@pytest.mark.parametrize(
    ("overrides", "detail"),
    [
        ({"title": "  "}, None),
        ({"title": "x" * 41}, None),
        ({"title": "Big\nDay"}, None),
        ({"target": 0}, None),
        ({"target": 1000}, None),
        ({"start_date": "2026-11-08", "end_date": "2026-11-07"}, "ends_before_it_starts"),
        ({"start_date": "2026-10-01", "end_date": "2026-10-31"}, "ends_in_the_past"),
        ({"start_date": "2026-11-01", "end_date": "2027-11-02"}, "longer_than_a_year"),
        ({"start_date": "11/01/2026"}, None),
        ({"latitude": 34.1}, None),
    ],
)
def test_a_bad_custom_goal_is_refused(
    client: TestClient, issuer: TestIssuer, overrides: dict[str, Any], detail: str | None
) -> None:
    circle_id = _circle(client, issuer)
    response = _create_goal(client, issuer, circle_id, **overrides)
    assert response.status_code == 422, response.text
    if detail is not None:
        assert response.json()["detail"] == detail
    assert [goal["kind"] for goal in _goals(client, issuer, circle_id)] == ["monthly"]


def test_a_goal_may_start_in_the_past_and_end_today(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    clock.now = datetime(2026, 11, 10, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    goal = _goal_ok(client, issuer, circle_id, start_date="2026-10-01", end_date="2026-11-10")
    assert goal["status"] == "active"


def test_the_goal_s_creator_or_the_circle_s_creator_deletes_it(client: TestClient, issuer: TestIssuer) -> None:
    circle_id = _circle(client, issuer)
    for sub in ("bo", "cy"):
        _join(client, issuer, circle_id, sub)
    bo_s = _goal_ok(client, issuer, circle_id, sub="bo")["id"]
    other = _goal_ok(client, issuer, circle_id, sub="bo", title="Shorebirds")["id"]
    assert _delete_goal(client, issuer, circle_id, bo_s, "cy") == 403
    assert _delete_goal(client, issuer, circle_id, bo_s, "eve") == 404
    assert _delete_goal(client, issuer, circle_id, bo_s, "bo") == 204
    assert _delete_goal(client, issuer, circle_id, other, "ada") == 204
    assert _delete_goal(client, issuer, circle_id, other, "ada") == 404
    assert [goal["kind"] for goal in _goals(client, issuer, circle_id)] == ["monthly"]


def test_the_monthly_goal_can_t_be_deleted(client: TestClient, issuer: TestIssuer) -> None:
    circle_id = _circle(client, issuer)
    monthly = _monthly(client, issuer, circle_id)["id"]
    response = client.delete(f"/v1/circles/{circle_id}/goals/{monthly}", headers=issuer.headers(sub="ada"))
    assert (response.status_code, response.json()["detail"]) == (403, "automatic_goal")


def test_a_handed_on_circle_s_new_creator_deletes_goals(client: TestClient, issuer: TestIssuer) -> None:
    circle_id = _circle(client, issuer)
    for sub in ("bo", "cy"):
        _join(client, issuer, circle_id, sub)
    goal_id = _goal_ok(client, issuer, circle_id, sub="cy")["id"]
    # Ada leaves: Bo, the longest-standing member, is the creator now (#61).
    client.delete(f"/v1/circles/{circle_id}/members/me", headers=issuer.headers(sub="ada"))
    assert _custom(client, issuer, circle_id, goal_id, sub="bo")["can_delete"] is True
    assert _delete_goal(client, issuer, circle_id, goal_id, "bo") == 204


def test_ended_goals_stay_a_week(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    circle_id = _circle(client, issuer)
    running = _goal_ok(client, issuer, circle_id, title="Running", start_date="2026-11-01", end_date="2026-11-30")["id"]
    coming = _goal_ok(client, issuer, circle_id, title="Coming", start_date="2026-11-20", end_date="2026-11-21")["id"]
    short = _goal_ok(client, issuer, circle_id, title="Short", start_date="2026-11-01", end_date="2026-11-03")["id"]
    assert [goal["id"] for goal in _goals(client, issuer, circle_id)][1:] == [short, running, coming]
    # 4 November in Los Angeles: Short has ended and comes last.
    clock.now = datetime(2026, 11, 4, 18, 0, tzinfo=UTC)
    goals = _goals(client, issuer, circle_id)
    assert [goal["id"] for goal in goals][1:] == [running, coming, short]
    assert goals[-1]["status"] == "ended"
    # A week after it ended (midnight starting 4 November), it's gone from the list.
    clock.now = datetime(2026, 11, 11, 8, 0, tzinfo=UTC)
    assert short not in [goal["id"] for goal in _goals(client, issuer, circle_id)]


# Progress.


def test_progress_counts_distinct_species_in_the_period(client: TestClient, issuer: TestIssuer, clock: Clock) -> None:
    circle_id = _circle(client, issuer)
    _join(client, issuer, circle_id, "bo")
    goal_id = _goal_ok(client, issuer, circle_id, target=10, start_date="2026-11-01", end_date="2026-11-07")["id"]
    _species_finds(client, issuer, "ada", 3, "2026-11-02T16:00:00Z")
    # Ada's repeat cards and Bo finding the same birds count once.
    _species_finds(client, issuer, "ada", 3, "2026-11-03T16:00:00Z")
    _species_finds(client, issuer, "bo", 2, "2026-11-04T16:00:00Z")
    # Bo's one new bird does count.
    _species_finds(client, issuer, "bo", 1, "2026-11-04T17:00:00Z", start=3)
    # Outside the period: 8 November in Los Angeles (from 08:00 UTC), and before 1 November there.
    _species_finds(client, issuer, "ada", 1, "2026-11-08T08:00:00Z", start=10)
    _species_finds(client, issuer, "ada", 1, "2026-11-01T06:59:00Z", start=11)
    # The last minute of 7 November counts.
    _species_finds(client, issuer, "ada", 1, "2026-11-08T07:59:00Z", start=12)
    assert _custom(client, issuer, circle_id, goal_id)["progress"] == 5


def test_only_the_circle_s_own_finds_count(client: TestClient, issuer: TestIssuer) -> None:
    sunday = _circle(client, issuer)
    other = _circle(client, issuer, sub="bo")
    goal_id = _goal_ok(client, issuer, sunday, target=10)["id"]
    # Bo's finds go to Bo's circle; Ada isn't in it.
    _species_finds(client, issuer, "bo", 4, "2026-11-02T16:00:00Z")
    assert _custom(client, issuer, sunday, goal_id)["progress"] == 0
    assert _monthly(client, issuer, other, sub="bo")["progress"] == 4


def test_a_delete_reduces_progress(client: TestClient, issuer: TestIssuer) -> None:
    circle_id = _circle(client, issuer)
    _join(client, issuer, circle_id, "bo")
    goal_id = _goal_ok(client, issuer, circle_id, target=10)["id"]
    sightings = _species_finds(client, issuer, "ada", 3, "2026-11-02T16:00:00Z")
    bo_s = _put_ok(client, issuer, "bo", _find(SPECIES[0], found_at="2026-11-03T16:00:00Z"))
    assert _custom(client, issuer, circle_id, goal_id)["progress"] == 3
    # Bo's Bird 0 is still there, so Ada's going changes nothing for it; her Bird 1 going does.
    for sighting in sightings[:2]:
        assert client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="ada")).status_code == 204
    assert _custom(client, issuer, circle_id, goal_id)["progress"] == 2
    assert _monthly(client, issuer, circle_id)["progress"] == 2
    client.delete(f"/v1/finds/{bo_s}", headers=issuer.headers(sub="bo"))
    assert _custom(client, issuer, circle_id, goal_id)["progress"] == 1


def test_a_member_who_left_still_counts(client: TestClient, issuer: TestIssuer) -> None:
    circle_id = _circle(client, issuer)
    _join(client, issuer, circle_id, "bo")
    _species_finds(client, issuer, "bo", 2, "2026-11-01T16:00:00Z")
    client.delete(f"/v1/circles/{circle_id}/members/me", headers=issuer.headers(sub="bo"))
    assert _monthly(client, issuer, circle_id)["progress"] == 2


# Completion.


@pytest.fixture
def group(client: TestClient, issuer: TestIssuer, apns: FakeApns) -> str:
    """Ada's Sunday Group with Bo and Cy, named and with phones. Earlier finds by Cy (in October, outside November's
    goals) take every species' circle first, so the finds here are ordinary unless a goal makes them notable."""
    circle_id = _circle(client, issuer)
    for sub in ("bo", "cy"):
        _join(client, issuer, circle_id, sub)
    _species_finds(client, issuer, "cy", len(SPECIES), "2026-10-15T16:00:00Z")
    for sub, name, phone in (("ada", "Ada", ADA_PHONE), ("bo", "Bo", BO_PHONE), ("cy", "Cy", CY_PHONE)):
        _name(client, issuer, sub, name)
        assert _register(client, issuer, sub, phone).status_code == 204
    apns.clear()
    return circle_id


def _alerts(apns: FakeApns, token: str) -> list[Any]:
    return [push for push in apns.to(token) if not push.is_silent]


def test_the_find_that_reaches_the_target_pushes_once(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, group: str
) -> None:
    goal_id = _goal_ok(client, issuer, group, sub="cy", title="Big Day", target=3)["id"]
    _species_finds(client, issuer, "bo", 2, "2026-11-01T16:00:00Z")
    assert _alerts(apns, ADA_PHONE) == []
    _put_ok(client, issuer, "bo", _find(SPECIES[2], found_at="2026-11-01T17:00:00Z", place="Ojai"))
    (push,) = _alerts(apns, ADA_PHONE)
    assert push.kind is PushKind.NOTABLE
    payload = push.payload()
    assert payload["aps"]["alert"] == {
        "title": "Sunday Group reached “Big Day”",
        "body": "Bo found a Bird 2, species 3 of 3 · Ojai",
    }
    assert payload["goals"] == [
        {"circle_id": group, "goal_id": goal_id, "kind": "custom", "title": "Big Day", "target": 3, "progress": 3}
    ]
    assert payload["find"]["common_name"] == "Bird 2"
    assert len(_alerts(apns, CY_PHONE)) == 1
    # Bo found it: never pushed about their own find.
    assert apns.to(BO_PHONE) == []
    goal = _custom(client, issuer, group, goal_id)
    assert goal["completed_at"] == "2026-11-01T09:30:00Z" and goal["progress"] == 3

    # A fourth bird: progress grows, no second goal push (an ordinary find, buffered for the digest).
    apns.clear()
    _put_ok(client, issuer, "bo", _find(SPECIES[3], found_at="2026-11-01T18:00:00Z"))
    assert _alerts(apns, ADA_PHONE) == []
    # Falling below the target after deletes and reaching it again pushes nothing either.
    sightings = [item["sighting_id"] for item in client.get(
        f"/v1/circles/{group}/feed", headers=issuer.headers(sub="bo")
    ).json()["items"] if item["owner"]["id"] == "bo"]
    for sighting in sightings[:3]:
        client.delete(f"/v1/finds/{sighting}", headers=issuer.headers(sub="bo"))
    assert _custom(client, issuer, group, goal_id)["progress"] == 1
    _species_finds(client, issuer, "ada", 3, "2026-11-01T19:00:00Z", start=10)
    assert _custom(client, issuer, group, goal_id)["progress"] == 4
    assert _alerts(apns, BO_PHONE) == [] and _alerts(apns, CY_PHONE) == []
    assert _custom(client, issuer, group, goal_id)["completed_at"] == "2026-11-01T09:30:00Z"


def test_the_monthly_goal_s_completion_pushes_with_the_month(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, group: str
) -> None:
    # The group was made on 1 November: its first month's 10 species.
    _species_finds(client, issuer, "ada", 9, "2026-11-01T16:00:00Z")
    assert _alerts(apns, BO_PHONE) == []
    apns.clear()
    _put_ok(client, issuer, "ada", _find(SPECIES[9], found_at="2026-11-01T17:00:00Z", legendary=True))
    (push,) = apns.to(BO_PHONE)
    assert push.payload()["aps"]["alert"] == {
        "title": "Sunday Group reached the November goal",
        "body": "Ada found a Bird 9, species 10 of 10 · Legendary · Pasadena",
    }
    # One alert for the Legendary and the goal together.
    assert push.kind is PushKind.NOTABLE


def test_a_goal_made_already_reached_is_never_pushed(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, group: str
) -> None:
    _species_finds(client, issuer, "bo", 2, "2026-11-01T16:00:00Z")
    goal = _goal_ok(client, issuer, group, target=2)
    assert goal["completed_at"] is not None and goal["progress"] == 2
    apns.clear()
    _species_finds(client, issuer, "bo", 1, "2026-11-01T17:00:00Z", start=5)
    assert _alerts(apns, ADA_PHONE) == []


def test_a_find_outside_the_period_completes_nothing(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, group: str
) -> None:
    goal_id = _goal_ok(client, issuer, group, target=2, start_date="2026-11-03", end_date="2026-11-04")["id"]
    _species_finds(client, issuer, "bo", 1, "2026-11-03T16:00:00Z")
    # On 2 November: the goal hasn't started.
    _species_finds(client, issuer, "bo", 1, "2026-11-02T16:00:00Z", start=1)
    assert _alerts(apns, ADA_PHONE) == []
    assert _custom(client, issuer, group, goal_id)["completed_at"] is None


def test_a_muted_circle_hears_no_goal(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, group: str
) -> None:
    assert client.put(f"/v1/circles/{group}/mute", headers=issuer.headers(sub="cy")).status_code == 204
    _goal_ok(client, issuer, group, target=1)
    _species_finds(client, issuer, "bo", 1, "2026-11-01T16:00:00Z")
    assert len(_alerts(apns, ADA_PHONE)) == 1
    assert _alerts(apns, CY_PHONE) == []


def test_a_goal_reached_alone_is_noted_and_never_pushed_later(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock
) -> None:
    circle_id = _circle(client, issuer)
    goal_id = _goal_ok(client, issuer, circle_id, target=1)["id"]
    _species_finds(client, issuer, "ada", 1, "2026-11-01T16:00:00Z")
    assert _custom(client, issuer, circle_id, goal_id)["completed_at"] is not None
    _join(client, issuer, circle_id, "bo")
    _register(client, issuer, "bo", BO_PHONE)
    # Another Bird 0: not the circle's first, so only a goal could make it notable, and the goal was reached.
    _species_finds(client, issuer, "ada", 1, "2026-11-01T17:00:00Z")
    assert _alerts(apns, BO_PHONE) == []


def test_two_circles_reaching_goals_with_one_find_both_say_so(
    client: TestClient, issuer: TestIssuer, apns: FakeApns
) -> None:
    first = _circle(client, issuer)
    second = _circle(client, issuer)
    for circle_id in (first, second):
        _join(client, issuer, circle_id, "bo")
        _goal_ok(client, issuer, circle_id, target=1)
    _register(client, issuer, "bo", BO_PHONE)
    _put_ok(client, issuer, "ada", _find(SPECIES[0], found_at="2026-11-01T16:00:00Z"))
    (push,) = _alerts(apns, BO_PHONE)
    assert {goal["circle_id"] for goal in push.payload()["goals"]} == {first, second}


def test_a_repeat_bird_takes_no_credit_for_a_goal_reached_by_a_moved_find(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, group: str
) -> None:
    goal_id = _goal_ok(client, issuer, group, target=2, start_date="2026-11-01", end_date="2026-11-07")["id"]
    _species_finds(client, issuer, "bo", 1, "2026-11-02T16:00:00Z")
    # Bird 1 found on 31 October, then corrected to 2 November: a repeated put, which pushes nothing.
    moved = _put_ok(client, issuer, "bo", _find(SPECIES[1], found_at="2026-10-31T16:00:00Z"))
    _put_ok(client, issuer, "bo", _find(SPECIES[1], found_at="2026-11-02T17:00:00Z"), sighting_id=moved)
    assert _custom(client, issuer, group, goal_id)["progress"] == 2
    # Another Bird 0 didn't bring the count to 2: no "species 2 of 2" for it.
    _species_finds(client, issuer, "bo", 1, "2026-11-03T16:00:00Z")
    assert _alerts(apns, ADA_PHONE) == []
    assert _custom(client, issuer, group, goal_id)["completed_at"] is None


def test_a_late_find_doesn_t_announce_a_goal_that_has_ended(
    client: TestClient, issuer: TestIssuer, apns: FakeApns, clock: Clock, group: str
) -> None:
    goal_id = _goal_ok(client, issuer, group, target=1, start_date="2026-11-01", end_date="2026-11-03")["id"]
    clock.now = datetime(2026, 11, 5, 18, 0, tzinfo=UTC)
    # Shared by hand two days after the goal ended, from its second day.
    _species_finds(client, issuer, "bo", 1, "2026-11-02T16:00:00Z")
    assert _alerts(apns, ADA_PHONE) == []
    goal = _custom(client, issuer, group, goal_id)
    assert goal["progress"] == 1 and goal["completed_at"] is None and goal["status"] == "ended"


def test_a_deleted_circle_leaves_the_rollover(client: TestClient, issuer: TestIssuer, clock: Clock, table: Any) -> None:
    clock.now = datetime(2026, 10, 5, 18, 0, tzinfo=UTC)
    circle_id = _circle(client, issuer)
    table.delete_item(Key={"pk": f"CIRCLE#{circle_id}", "sk": "META"})
    clock.now = datetime(2026, 11, 1, 8, 0, tzinfo=UTC)
    assert _roll_over(client).skipped == 1
    report = _roll_over(client)
    assert (report.created, report.current, report.skipped) == (0, 0, 0)
