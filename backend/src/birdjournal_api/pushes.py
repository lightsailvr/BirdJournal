"""Pushes (issue #63, spec v2 "Push"): members hear about the finds that matter at once and the rest in a digest.

When a find is first written (a repeated put sends nothing), every current member of the circles it went to hears of
it, except its owner, anyone who muted the owner, and anyone who muted every one of those circles they are in:

- A **notable** find (a new patch, the circle's first of the species, Rare or Exceptional rarity, or the find that brings
  one of the circle's goals to its target, issue #65, once per goal) pushes at once to
  each of the member's phones: an alert plus content-available, carrying the find's summary (`find`), which the lens's
  friend banner (#67) reads.
- **Any other** find goes into the member's digest buffer for that friend, and a silent push (content-available only)
  tells the phone to refresh its feed. A scheduled job (`flush_digests`, every 15 minutes) sends each buffer as one
  alert, "Maya found 6 birds in Pasadena", once two hours have passed since the member's last push about that friend.

Items, beside the devices and mutes (devices.py):

- `ACCOUNT#<recipient>` / `PUSHED#<friend>`: when the recipient last got an alert about the friend's finds.
- `DIGEST` / `<recipient>#<friend>`: the digest buffer, the friend's buffered sighting ids and the circles they came
  through (string sets), and when the first went in. One partition, so the flush reads every buffer with one query and no scan or index; the friends phase
  holds a few hundred pairs at most. A find deleted before the flush is left out of the digest (the flush reads the
  finds back), and a buffer whose finds are all gone sends nothing.
"""

import logging
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from typing import Any, Protocol

from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from birdjournal_api.circles import CircleStore
from birdjournal_api.devices import Device, DeviceStore, Mutes, MuteStore
from birdjournal_api.finds import SECRET_SPOT, Find, FindContent, FindStore, Rarity
from birdjournal_api.goals import CompletedGoal, GoalKind, GoalStore

log = logging.getLogger(__name__)

DIGEST_INTERVAL = timedelta(hours=2)
DIGEST_PK = "DIGEST"
NOTABLE_RARITIES = (Rarity.RARE, Rarity.EXCEPTIONAL)
FRIEND_FALLBACK = "A friend"


class PushKind(StrEnum):
    NOTABLE = "notable"
    DIGEST = "digest"
    # Someone reacted to the recipient's find (issue #64), collapsed per find within 10 minutes.
    REACTION = "reaction"
    # Silent: the phone refreshes its circle feeds.
    REFRESH = "refresh"


@dataclass(frozen=True)
class Push:
    kind: PushKind
    # The alert's words; none for a silent push.
    title: str | None = None
    body: str | None = None
    # Custom keys beside `aps`: `kind`, and for a notable find `find`, its summary for the lens banner.
    data: dict[str, Any] = field(default_factory=dict)
    # Groups a friend's alerts in Notification Center.
    thread_id: str | None = None
    # A newer push with the same id replaces the older on the phone.
    collapse_id: str | None = None

    @property
    def is_silent(self) -> bool:
        return self.kind is PushKind.REFRESH

    def payload(self) -> dict[str, Any]:
        """The APNs JSON payload."""
        aps: dict[str, Any] = {"content-available": 1}
        if not self.is_silent:
            alert: dict[str, str] = {}
            if self.title:
                alert["title"] = self.title
            if self.body:
                alert["body"] = self.body
            aps["alert"] = alert
            aps["sound"] = "default"
            if self.thread_id:
                aps["thread-id"] = self.thread_id
        return {"aps": aps, "kind": self.kind.value, **self.data}


class SendResult(StrEnum):
    SENT = "sent"
    # The token is no longer valid for this app: forget the device.
    GONE = "gone"
    FAILED = "failed"
    # No APNs key configured (before the push wizard has run).
    SKIPPED = "skipped"


class PushSender(Protocol):
    """Delivers one push to one device: APNs over HTTP/2 in the stack (apns.py), a recording fake in the tests."""

    def send(self, device: Device, push: Push) -> SendResult: ...


@dataclass(frozen=True)
class FlushReport:
    sent: int = 0
    waiting: int = 0
    dropped: int = 0


def find_summary(find: Find, owner_name: str | None, circle_first_in: list[str], circle_ids: list[str]) -> dict[str, Any]:
    """What a notable push carries for the lens's friend banner (#67): the find as the feed shows it, with only the
    recipient's circles it reached (another member's circles stay theirs)."""
    content = find.content
    return {
        "owner": find.owner,
        "owner_name": owner_name,
        "sighting_id": find.sighting_id,
        "species_id": content.species_id,
        "scientific_name": content.scientific_name,
        "common_name": content.common_name,
        "method": content.method.value,
        "place": content.place,
        "found_at": content.found_at.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "new_patch": content.new_patch,
        "edition": content.edition,
        # Compatibility: a beta phone from before #136 can't decode a push without it. Remove once no such phone is left.
        "legendary": content.new_patch,
        "rarity": content.rarity.value if content.rarity else None,
        "circle_first": bool(circle_first_in),
        "circle_ids": circle_ids,
    }


def notable_words(owner_name: str | None, content: FindContent, first_for: str | None) -> tuple[str, str]:
    """The alert's title and body: "Maya found a Black Phoebe" / "New patch, First for Sunday Group, Pasadena"."""
    name = owner_name or FRIEND_FALLBACK
    reasons: list[str] = []
    if content.new_patch:
        reasons.append("New patch")
    if first_for is not None:
        reasons.append(f"First for {first_for}")
    if content.rarity is not None and content.rarity in NOTABLE_RARITIES:
        reasons.append(content.rarity.value.capitalize())
    if content.place == SECRET_SPOT:
        reasons.append("At a secret spot")
    elif content.place:
        reasons.append(content.place)
    return f"{name} found {_with_article(content.common_name)}", ", ".join(reasons)


def goal_words(
    owner_name: str | None, content: FindContent, circle_name: str | None, completed: CompletedGoal,
    first_for: str | None,
) -> tuple[str, str]:
    """A goal reached (issue #65): "Sunday Group reached the November goal" / "Ada found a Black Phoebe, species 15
    of 15, New patch, Pasadena". The find's own reasons follow, so one alert says both."""
    goal = completed.goal
    circle = circle_name or "Your Guild"
    name = owner_name or FRIEND_FALLBACK
    title = f"{circle} reached the {goal.title}" if goal.kind is GoalKind.MONTHLY else f"{circle} reached “{goal.title}”"
    _, reasons = notable_words(owner_name, content, first_for)
    lead = f"{name} found {_with_article(content.common_name)}, species {completed.progress} of {goal.target}"
    return title, ", ".join(part for part in (lead, reasons) if part)


def goal_summary(completed: CompletedGoal) -> dict[str, Any]:
    """The goal a notable push reports, beside the find."""
    goal = completed.goal
    return {
        "circle_id": goal.circle_id,
        "goal_id": goal.id,
        "kind": goal.kind.value,
        "title": goal.title,
        "target": goal.target,
        "progress": completed.progress,
    }


def digest_words(owner_name: str | None, finds: list[FindContent]) -> str:
    """"Maya found 6 birds in Pasadena": the distinct species, and the most common place label among the finds (the
    latest find's on a tie). A secret spot is never named, and with no place the sentence ends at the birds."""
    name = owner_name or FRIEND_FALLBACK
    ordered = sorted(finds, key=lambda content: content.found_at)
    species = list(dict.fromkeys(content.scientific_name for content in ordered))
    if len(species) == 1:
        birds = _with_article(ordered[-1].common_name)
    else:
        birds = f"{len(species)} birds"
    places = [content.place for content in ordered if content.place and content.place != SECRET_SPOT]
    if not places:
        return f"{name} found {birds}"
    counts = Counter(places)
    top = max(counts.values())
    place = next(place for place in reversed(places) if counts[place] == top)
    return f"{name} found {birds} in {place}"


def _with_article(name: str) -> str:
    return f"{'an' if name[:1].lower() in 'aeiou' else 'a'} {name}"


class PushService:
    def __init__(
        self, table: Any, circles: CircleStore, finds: FindStore, devices: DeviceStore, mutes: MuteStore,
        goals: GoalStore, sender: PushSender, clock: Callable[[], datetime],
    ) -> None:
        self._table = table
        self._goals = goals
        self._circles = circles
        self._finds = finds
        self._devices = devices
        self._mutes = mutes
        self._sender = sender
        self._clock = clock

    def find_added(self, find: Find) -> None:
        """A new find: a notable push now, or the digest buffer and a silent refresh, to every member who hears it.
        A find that brings a circle's goal to its target (issue #65) is notable for that circle's members."""
        if not find.circle_ids:
            return
        owner = find.owner
        content = find.content
        # First, whoever hears it: a goal is noted as completed once, even in a circle of one.
        completed = self._goals.completed_by(find)
        recipients: dict[str, list[str]] = {}
        for circle_id in find.circle_ids:
            for member in self._circles.current_member_ids(circle_id):
                if member != owner:
                    recipients.setdefault(member, []).append(circle_id)
        if not recipients:
            return
        firsts = [
            circle_id for circle_id in find.circle_ids
            if self._finds.is_circle_first(circle_id, owner, find.sighting_id, content.scientific_name)
        ]
        owner_name = self._circles.display_names([owner]).get(owner)
        named = set(firsts) | {goal.goal.circle_id for goal in completed}
        circle_names = self._circles.circle_names(sorted(named)) if named else {}
        for recipient, circle_ids in recipients.items():
            open_circles = _open_circles(self._mutes.mutes_of(recipient), owner, circle_ids)
            if not open_circles:
                continue
            devices = self._devices.devices_of(recipient)
            if not devices:
                continue
            first_in = [circle_id for circle_id in firsts if circle_id in open_circles]
            goals = [goal for goal in completed if goal.goal.circle_id in open_circles]
            notable = content.new_patch or bool(first_in) or content.rarity in NOTABLE_RARITIES or bool(goals)
            if notable:
                first_for = circle_names.get(first_in[0]) if first_in else None
                if goals:
                    goal = goals[0]
                    title, body = goal_words(
                        owner_name, content, circle_names.get(goal.goal.circle_id), goal, first_for
                    )
                else:
                    title, body = notable_words(owner_name, content, first_for)
                data: dict[str, Any] = {"find": find_summary(find, owner_name, first_in, open_circles)}
                if goals:
                    data["goals"] = [goal_summary(goal) for goal in goals]
                push = Push(kind=PushKind.NOTABLE, title=title, body=body, data=data, thread_id=f"friend-{owner}")
                if self.deliver(devices, push):
                    self._record_push(recipient, owner)
            else:
                self._buffer(recipient, owner, find.sighting_id, open_circles)
                self.deliver(devices, Push(kind=PushKind.REFRESH, data={"circle_ids": open_circles}))

    def flush_digests(self) -> FlushReport:
        """Sends every buffer whose recipient's last push about that friend is two hours old or more (or never was)."""
        now = self._clock()
        sent = waiting = dropped = 0
        for item in self._buffers():
            recipient, friend = item["recipient"], item["friend"]
            sighting_ids = sorted(item.get("sighting_ids", set()))
            last = self._last_push(recipient, friend)
            if last is not None and now - last < DIGEST_INTERVAL:
                waiting += 1
                continue
            mutes = self._mutes.mutes_of(recipient)
            # The circles the buffered finds came through that the recipient is still in.
            through = sorted(set(item.get("circle_ids", set())) & set(self._circles.circle_ids_of(recipient)))
            live = self._finds.existing([(friend, sighting_id) for sighting_id in sighting_ids])
            devices = self._devices.devices_of(recipient)
            if not live or not devices or not _open_circles(mutes, friend, through):
                # Deleted finds, a phone signed out, a mute, or out of those circles now: nothing to say.
                self._clear_buffer(recipient, friend, sighting_ids)
                dropped += 1
                continue
            owner_name = self._circles.display_names([friend]).get(friend)
            finds = list(live.values())
            push = Push(
                kind=PushKind.DIGEST, body=digest_words(owner_name, finds),
                # The birds the words count: distinct species.
                data={"friend": friend, "count": len({content.scientific_name for content in finds})},
                thread_id=f"friend-{friend}", collapse_id=f"digest-{friend}"[:64],
            )
            if self.deliver(devices, push):
                self._record_push(recipient, friend)
                self._clear_buffer(recipient, friend, sighting_ids)
                sent += 1
            else:
                waiting += 1
        return FlushReport(sent=sent, waiting=waiting, dropped=dropped)

    def deliver(self, devices: list[Device], push: Push) -> bool:
        """True when at least one of the phones took it."""
        delivered = False
        for device in devices:
            try:
                result = self._sender.send(device, push)
            except Exception:
                log.exception("push to a device failed")
                continue
            if result is SendResult.SENT:
                delivered = True
            elif result is SendResult.GONE:
                self._devices.forget(device.token)
        return delivered

    def _buffer(self, recipient: str, friend: str, sighting_id: str, circle_ids: list[str]) -> None:
        """Remembers the find and the circles it came through, whose mutes the flush checks again."""
        self._table.update_item(
            Key=_buffer_key(recipient, friend),
            UpdateExpression=(
                "ADD sighting_ids :ids, circle_ids :circles SET recipient = :recipient, friend = :friend, "
                "first_at = if_not_exists(first_at, :now)"
            ),
            ExpressionAttributeValues={
                ":ids": {sighting_id}, ":circles": set(circle_ids), ":recipient": recipient, ":friend": friend,
                ":now": self._clock().isoformat(),
            },
        )

    def _clear_buffer(self, recipient: str, friend: str, sighting_ids: list[str]) -> None:
        """Takes out what was read; the buffer goes only if nothing came in meanwhile."""
        if sighting_ids:
            self._table.update_item(
                Key=_buffer_key(recipient, friend), UpdateExpression="DELETE sighting_ids :ids",
                ExpressionAttributeValues={":ids": set(sighting_ids)},
            )
        try:
            self._table.delete_item(Key=_buffer_key(recipient, friend), ConditionExpression="attribute_not_exists(sighting_ids)")
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def _buffers(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {"KeyConditionExpression": Key("pk").eq(DIGEST_PK), "ConsistentRead": True}
        while True:
            response = self._table.query(**kwargs)
            items.extend(response["Items"])
            if "LastEvaluatedKey" not in response:
                return items
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    def _last_push(self, recipient: str, friend: str) -> datetime | None:
        item = self._table.get_item(Key=_pushed_key(recipient, friend), ConsistentRead=True).get("Item")
        return datetime.fromisoformat(item["at"]) if item else None

    def _record_push(self, recipient: str, friend: str) -> None:
        self._table.put_item(Item={**_pushed_key(recipient, friend), "at": self._clock().isoformat()})


def _open_circles(mutes: Mutes, friend: str, circle_ids: list[str]) -> list[str]:
    """The circles through which the recipient still hears of the friend: none when the friend is muted."""
    if mutes.silences(friend):
        return []
    return [circle_id for circle_id in circle_ids if circle_id not in mutes.circles]


def _buffer_key(recipient: str, friend: str) -> dict[str, str]:
    return {"pk": DIGEST_PK, "sk": f"{recipient}#{friend}"}


def _pushed_key(recipient: str, friend: str) -> dict[str, str]:
    return {"pk": f"ACCOUNT#{recipient}", "sk": f"PUSHED#{friend}"}
