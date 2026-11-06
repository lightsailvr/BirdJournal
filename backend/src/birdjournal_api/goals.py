"""Goals (issue #65, spec v2 "Goals"): every circle has something to chase.

- **The automatic monthly goal**: one per circle per calendar month in the circle's time zone (the creator's device's
  at creation, #61). A scheduled job (`roll_over`, every 15 minutes so every zone's midnight is caught within a
  quarter hour) makes it at the start of the month; reading the goals or a new find makes it too if the job hasn't yet,
  so it is never missing. Its target is the larger of 5 and 115 % of the distinct species the circle found last
  month, rounded half up, or 10 in the circle's first month. The target is fixed when the goal is made.
- **Custom goals**: any member makes one with a title, a target, a first and a last day (calendar dates in the circle's
  time zone, both included, so a Big Day is one date). The goal's creator or the circle's creator deletes it.
- **Progress** is the number of distinct species among the circle's feed items found inside the period, read when
  asked: repeat cards and several members finding the same bird count once, a deleted find stops counting at once, and
  the finds of a member who left still count (they stay in the feed, #62). The same read names what it counted (#150):
  each species, earliest first, with the edition of its earliest find that has one.
- **Completion** is noted once (`completed_at`, written on the condition that it isn't there): the new find that
  brings progress to the target (its species new to the period, and the count reaching the target with it) makes a
  notable push (pushes.py), and no later find, nor progress falling and rising again after a delete, pushes it again.
  A goal that has ended completes no more (a late find shared by hand doesn't announce last March's goal). A custom
  goal made already reached is noted without a push.

Items, beside the finds' partitions (finds.py):

- `CIRCLE#<id>#GOALS` / `GOAL#<goal id>`: the goal: `kind` (monthly or custom), `title`, `target`, `start_date` and
  `end_date` (ISO dates, both included), `goal_id`, `created_by` (custom only), `created_at`, and `completed_at` with
  `completed_by` (`<owner>#<sighting id>`, the find that reached it) once reached.
  The monthly goal's id is `monthly-<yyyy>-<mm>`, so two makers racing write it once.
- `GOAL_ROLLOVER` / `<circle id>`: every circle the job rolls over, with its time zone and `month`, the last month it
  made a goal for. One partition, like the digest buffers (#63): one query a run, and a circle is read only when its
  month has turned. Written at a circle's creation, or at the first goal made for a circle from before this ticket.
"""

import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from enum import StrEnum
from typing import Any
from uuid import uuid4
from zoneinfo import ZoneInfo

from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from birdjournal_api.circles import Circle, CircleStore, NotFound
from birdjournal_api.finds import CountedSpecies, Find, FindStore

ROLLOVER_PK = "GOAL_ROLLOVER"
FIRST_MONTH_TARGET = 10
MINIMUM_TARGET = 5
# 115 %, in hundredths so the arithmetic is exact (1.15 * 20 is 22.999… in floating point).
GROWTH_PERCENT = 115
TITLE_MAX = 40
TARGET_MAX = 999
LONGEST_GOAL = timedelta(days=366)
# Ended custom goals stay on the circle page this long, so the circle sees how it went.
ENDED_SHOWN_FOR = timedelta(days=7)


class GoalKind(StrEnum):
    MONTHLY = "monthly"
    CUSTOM = "custom"


class GoalStatus(StrEnum):
    UPCOMING = "upcoming"
    ACTIVE = "active"
    ENDED = "ended"


class NotAllowed(Exception):
    """Only the goal's creator or the circle's creator deletes a custom goal."""


class AutomaticGoal(Exception):
    """The monthly goal isn't deletable."""


@dataclass(frozen=True)
class Goal:
    circle_id: str
    id: str
    kind: GoalKind
    title: str
    target: int
    start_date: date
    end_date: date
    created_by: str | None
    created_at: datetime
    completed_at: datetime | None


@dataclass(frozen=True)
class GoalView:
    goal: Goal
    starts_at: datetime
    ends_at: datetime
    progress: int
    # What the progress counted, earliest first: `progress` of them, from the same read.
    species: list[CountedSpecies]
    status: GoalStatus
    created_by_name: str | None
    can_delete: bool


@dataclass(frozen=True)
class CompletedGoal:
    goal: Goal
    progress: int


@dataclass(frozen=True)
class RolloverReport:
    created: int = 0
    current: int = 0
    skipped: int = 0


def monthly_target(last_month_species: int | None) -> int:
    """The larger of 5 and 115 % of last month's distinct species, rounded half up; 10 in the circle's first month
    (None: there was no last month)."""
    if last_month_species is None:
        return FIRST_MONTH_TARGET
    return max(MINIMUM_TARGET, (last_month_species * GROWTH_PERCENT + 50) // 100)


def month_title(year: int, month: int) -> str:
    return f"{date(year, month, 1):%B} goal"


def clean_title(raw: str) -> str:
    title = raw.strip()
    if not title or len(title) > TITLE_MAX:
        raise ValueError(f"The title must be 1 to {TITLE_MAX} characters")
    if any(unicodedata.category(character).startswith("C") for character in title):
        raise ValueError("The title has a control character")
    return title


def period(time_zone: str, start: date, end: date) -> tuple[datetime, datetime]:
    """The goal's period as UTC instants: midnight starting the first day to midnight ending the last, in the zone."""
    zone = ZoneInfo(time_zone)
    starts = datetime.combine(start, time(), zone).astimezone(UTC)
    ends = datetime.combine(end + timedelta(days=1), time(), zone).astimezone(UTC)
    return starts, ends


def _month_of(moment: datetime, time_zone: str) -> tuple[int, int]:
    local = moment.astimezone(ZoneInfo(time_zone))
    return local.year, local.month


def _month_days(year: int, month: int) -> tuple[date, date]:
    first = date(year, month, 1)
    following = date(year + month // 12, month % 12 + 1, 1)
    return first, following - timedelta(days=1)


def _previous(year: int, month: int) -> tuple[int, int]:
    return (year - 1, 12) if month == 1 else (year, month - 1)


class GoalStore:
    def __init__(self, table: Any, circles: CircleStore, finds: FindStore, clock: Callable[[], datetime]) -> None:
        self._table = table
        self._circles = circles
        self._finds = finds
        self._clock = clock

    # Reads.

    def goals(self, subject: str, circle_id: str) -> list[GoalView]:
        """The circle's goals for a member: this month's goal, then custom goals running, coming and recently ended.
        NotFound for anyone else."""
        circle = self._member_circle(subject, circle_id)
        now = self._clock()
        self._ensure_monthly(circle, now)
        this_month = _month_of(now, circle.time_zone)

        def shown(goal: Goal) -> bool:
            if goal.kind is GoalKind.MONTHLY:
                return (goal.start_date.year, goal.start_date.month) == this_month
            return now - period(circle.time_zone, goal.start_date, goal.end_date)[1] < ENDED_SHOWN_FOR

        # Only the shown goals' progress is read: past months and long-ended goals stay in the table.
        views = [self._view(circle, goal, subject, now) for goal in self._goal_items(circle_id) if shown(goal)]
        monthly = [view for view in views if view.goal.kind is GoalKind.MONTHLY]
        custom = [view for view in views if view.goal.kind is GoalKind.CUSTOM]
        order = {GoalStatus.ACTIVE: 0, GoalStatus.UPCOMING: 1, GoalStatus.ENDED: 2}
        custom.sort(key=lambda view: (order[view.status], view.goal.end_date, view.goal.created_at))
        return monthly + custom

    # Writes.

    def circle_created(self, circle: Circle) -> None:
        """A new circle: its first monthly goal (10 species) and its place in the rollover."""
        self._ensure_monthly(circle, self._clock())

    def create(self, subject: str, circle_id: str, title: str, target: int, start: date, end: date) -> GoalView:
        circle = self._member_circle(subject, circle_id)
        if end < start:
            raise ValueError("ends_before_it_starts")
        if end - start >= LONGEST_GOAL:
            raise ValueError("longer_than_a_year")
        now = self._clock()
        if end < now.astimezone(ZoneInfo(circle.time_zone)).date():
            raise ValueError("ends_in_the_past")
        goal_id = str(uuid4())
        item: dict[str, Any] = {
            **_goal_key(circle_id, goal_id),
            "goal_id": goal_id,
            "kind": GoalKind.CUSTOM.value,
            "title": title,
            "target": target,
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
            "created_by": subject,
            "created_at": now.isoformat(),
        }
        starts_at, ends_at = period(circle.time_zone, start, end)
        if self._progress(circle_id, starts_at, ends_at) >= target:
            # Made already reached: noted, so no later find pushes it as completed.
            item["completed_at"] = now.isoformat()
        self._table.put_item(Item=item)
        return self._view(circle, _goal(item), subject, now)

    def delete(self, subject: str, circle_id: str, goal_id: str) -> None:
        circle = self._member_circle(subject, circle_id)
        item = self._table.get_item(Key=_goal_key(circle_id, goal_id), ConsistentRead=True).get("Item")
        if item is None:
            raise NotFound()
        goal = _goal(item)
        if goal.kind is GoalKind.MONTHLY:
            raise AutomaticGoal()
        if subject not in (goal.created_by, circle.created_by):
            raise NotAllowed()
        self._table.delete_item(Key=_goal_key(circle_id, goal_id))

    def completed_by(self, find: Find) -> list[CompletedGoal]:
        """The goals a new find brought to their targets, each noted as completed so it is reported only this once."""
        now = self._clock()
        completed: list[CompletedGoal] = []
        for circle_id in find.circle_ids:
            circle = self._circles.circle(circle_id)
            if circle is None:
                continue
            self._ensure_monthly(circle, now)
            for goal in self._goal_items(circle_id):
                if goal.completed_at is not None:
                    continue
                starts_at, ends_at = period(circle.time_zone, goal.start_date, goal.end_date)
                if not starts_at <= find.content.found_at < ends_at or now >= ends_at:
                    continue
                species = self._finds.species_between(circle_id, starts_at, ends_at)
                # This find is the one that crossed: its species is new to the period, and with it the count reaches
                # the target. A repeat bird after a goal reached otherwise (a moved find) takes no credit.
                counted = species.get(find.content.scientific_name)
                crossed = counted is not None and counted.find_count == 1 and len(species) == goal.target
                if crossed and self._note_completed(goal, find, now):
                    completed.append(CompletedGoal(goal=goal, progress=len(species)))
        return completed

    def roll_over(self) -> RolloverReport:
        """Makes each circle's monthly goal once its month has begun in its time zone. Reads only the circles whose
        month has turned since the last run."""
        now = self._clock()
        created = current = skipped = 0
        for item in self._rollover_items():
            circle_id = str(item["sk"])
            year, month = _month_of(now, item["time_zone"])
            if item.get("month") == _month_key(year, month):
                current += 1
                continue
            circle = self._circles.circle(circle_id)
            if circle is None:
                self._table.delete_item(Key={"pk": ROLLOVER_PK, "sk": circle_id})
                skipped += 1
                continue
            if circle.member_count == 0:
                # Nobody left to chase it: the circle is passed over until someone is back (reading the goals or a
                # find makes the goal then).
                self._register(circle_id, item["time_zone"], year, month)
                skipped += 1
                continue
            if self._ensure_monthly(circle, now):
                created += 1
            else:
                current += 1
        return RolloverReport(created=created, current=current, skipped=skipped)

    # Helpers.

    def _member_circle(self, subject: str, circle_id: str) -> Circle:
        circle = self._circles.circle(circle_id) if self._circles.is_member(subject, circle_id) else None
        if circle is None:
            raise NotFound()
        return circle

    def _ensure_monthly(self, circle: Circle, now: datetime) -> bool:
        """This month's goal, made if it isn't there, and the circle's place in the rollover. True when made here."""
        year, month = _month_of(now, circle.time_zone)
        goal_id = f"monthly-{_month_key(year, month)}"
        if "Item" in self._table.get_item(Key=_goal_key(circle.id, goal_id), ConsistentRead=True):
            return False
        first, last = _month_days(year, month)
        created_year, created_month = _month_of(circle.created_at, circle.time_zone)
        if (year, month) <= (created_year, created_month):
            last_month: int | None = None
        else:
            previous_first, previous_last = _month_days(*_previous(year, month))
            last_month = self._progress(circle.id, *period(circle.time_zone, previous_first, previous_last))
        try:
            self._table.put_item(
                Item={
                    **_goal_key(circle.id, goal_id),
                    "goal_id": goal_id,
                    "kind": GoalKind.MONTHLY.value,
                    "title": month_title(year, month),
                    "target": monthly_target(last_month),
                    "start_date": first.isoformat(),
                    "end_date": last.isoformat(),
                    "created_at": now.isoformat(),
                },
                ConditionExpression="attribute_not_exists(pk)",
            )
            made = True
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            made = False
        self._register(circle.id, circle.time_zone, year, month)
        return made

    def _register(self, circle_id: str, time_zone: str, year: int, month: int) -> None:
        self._table.put_item(
            Item={"pk": ROLLOVER_PK, "sk": circle_id, "time_zone": time_zone, "month": _month_key(year, month)}
        )

    def _note_completed(self, goal: Goal, find: Find, now: datetime) -> bool:
        try:
            self._table.update_item(
                Key=_goal_key(goal.circle_id, goal.id),
                UpdateExpression="SET completed_at = :now, completed_by = :find",
                ConditionExpression="attribute_exists(pk) AND attribute_not_exists(completed_at)",
                ExpressionAttributeValues={":now": now.isoformat(), ":find": f"{find.owner}#{find.sighting_id}"},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise
        return True

    def _progress(self, circle_id: str, starts_at: datetime, ends_at: datetime) -> int:
        return len(self._finds.species_between(circle_id, starts_at, ends_at))

    def _view(self, circle: Circle, goal: Goal, subject: str, now: datetime) -> GoalView:
        starts_at, ends_at = period(circle.time_zone, goal.start_date, goal.end_date)
        status = GoalStatus.UPCOMING if now < starts_at else GoalStatus.ACTIVE if now < ends_at else GoalStatus.ENDED
        names = self._circles.display_names([goal.created_by]) if goal.created_by else {}
        species = list(self._finds.species_between(circle.id, starts_at, ends_at).values())
        return GoalView(
            goal=goal,
            starts_at=starts_at,
            ends_at=ends_at,
            progress=len(species),
            species=species,
            status=status,
            created_by_name=names.get(goal.created_by) if goal.created_by else None,
            can_delete=goal.kind is GoalKind.CUSTOM and subject in (goal.created_by, circle.created_by),
        )

    def _goal_items(self, circle_id: str) -> list[Goal]:
        return [_goal(item) for item in self._query(Key("pk").eq(_goals_pk(circle_id)) & Key("sk").begins_with("GOAL#"))]

    def _rollover_items(self) -> list[dict[str, Any]]:
        return self._query(Key("pk").eq(ROLLOVER_PK))

    def _query(self, condition: Any) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {"KeyConditionExpression": condition, "ConsistentRead": True}
        while True:
            response = self._table.query(**kwargs)
            items.extend(response["Items"])
            if "LastEvaluatedKey" not in response:
                return items
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def _goal(item: dict[str, Any]) -> Goal:
    return Goal(
        circle_id=str(item["pk"]).removeprefix("CIRCLE#").removesuffix("#GOALS"),
        id=item["goal_id"],
        kind=GoalKind(item["kind"]),
        title=item["title"],
        target=int(item["target"]),
        start_date=date.fromisoformat(item["start_date"]),
        end_date=date.fromisoformat(item["end_date"]),
        created_by=item.get("created_by"),
        created_at=datetime.fromisoformat(item["created_at"]),
        completed_at=datetime.fromisoformat(item["completed_at"]) if "completed_at" in item else None,
    )


def _goals_pk(circle_id: str) -> str:
    return f"CIRCLE#{circle_id}#GOALS"


def _goal_key(circle_id: str, goal_id: str) -> dict[str, str]:
    return {"pk": _goals_pk(circle_id), "sk": f"GOAL#{goal_id}"}


def _month_key(year: int, month: int) -> str:
    return f"{year:04d}-{month:02d}"
