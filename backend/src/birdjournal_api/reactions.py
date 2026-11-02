"""Reactions and Compare birds (issue #64, spec v2 "Reactions" and "Compare").

**Reactions** are a fixed set on a find ("Lovely find", "Jealous!", "Let's go together") with no comments. A member
gives each kind at most once per find, and takes it back with a delete. Only someone who shares, now, a circle the
find went to may react (anyone else gets 404, so a find's existence never leaks); never its owner. The feed shows
each kind's count and whether the reader gave it.

The owner hears of reactions in a push **collapsed per find within 10 minutes**: the first reaction pushes at once;
any that follow within 10 minutes of that push wait in a buffer, and the next flush after the 10 minutes (the digest
schedule's, every 15 minutes) sends them as one alert, "Bo and Cy reacted to your Black Phoebe", which replaces the
first on the phone (`apns-collapse-id` per find) and so names the first's reactions too. A reaction after the window with nothing waiting pushes at once
again. Mutes hold: a muted friend's reactions never push, nor do those that reach the owner only through muted
circles.

**Compare birds**: a friend's species with their best method (Seen beats Heard), from their finds that went to the
circles the two share now. The phone merges in its own collection.

Items, beside the finds' (finds.py):

- `FIND#<owner>#<sighting id>` / `REACTION#<reactor>#<kind>`: a reaction, by find (the counts read this partition;
  a find's delete removes it, #62).
- `ACCOUNT#<reactor>` / `REACTION#<owner>#<sighting id>#<kind>`: the same reaction by reactor, so account deletion
  (#71) finds an account's reactions on other people's finds without a scan.
- `ACCOUNT#<owner>` / `REACTIONPUSH#<sighting id>`: when the owner last got a reaction alert about the find, and the
  reactions it named (`shown`), which the collapsed alert that replaces it names again.
- `REACTIONS` / `<owner>#<sighting id>`: the reactions waiting for the window to close (a string set of
  `<reactor>#<kind>`). One partition, like the digests', so the flush is one query.
"""

import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from typing import Any

from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

from birdjournal_api.circles import CircleStore, NotFound
from birdjournal_api.devices import DeviceStore, MuteStore
from birdjournal_api.finds import (
    REACTIONS_PK,
    Find,
    FindStore,
    Method,
    reaction_buffer_key,
    reaction_push_key,
    reactor_copy_key,
)
from birdjournal_api.pushes import FRIEND_FALLBACK, Push, PushKind, PushService

log = logging.getLogger(__name__)

REACTION_WINDOW = timedelta(minutes=10)


class ReactionKind(StrEnum):
    LOVELY = "lovely"
    JEALOUS = "jealous"
    TOGETHER = "together"

    @property
    def words(self) -> str:
        return _WORDS[self]


_WORDS = {
    ReactionKind.LOVELY: "Lovely find",
    ReactionKind.JEALOUS: "Jealous!",
    ReactionKind.TOGETHER: "Let's go together",
}
# The order the phone shows them in.
KINDS = list(ReactionKind)


class OwnFind(Exception):
    """The owner can't react to their own find."""


@dataclass(frozen=True)
class ReactionCount:
    kind: ReactionKind
    count: int
    mine: bool


@dataclass(frozen=True)
class ComparedSpecies:
    species_id: str
    scientific_name: str
    common_name: str
    method: Method


@dataclass(frozen=True)
class ReactionFlushReport:
    sent: int = 0
    waiting: int = 0
    dropped: int = 0


def reaction_words(reactor_names: list[str], common_name: str, kinds: list[ReactionKind]) -> tuple[str, str]:
    """"Bo reacted to your Black Phoebe" / "Lovely find"; "Bo and Cy …", "Bo and 2 others …"; the kinds in their
    fixed order, joined by " · "."""
    names = list(dict.fromkeys(reactor_names)) or [FRIEND_FALLBACK]
    if len(names) == 1:
        who = names[0]
    elif len(names) == 2:
        who = f"{names[0]} and {names[1]}"
    else:
        who = f"{names[0]} and {len(names) - 1} others"
    ordered = [kind for kind in KINDS if kind in set(kinds)]
    return f"{who} reacted to your {common_name}", " · ".join(kind.words for kind in ordered)


def counts_of(reactions: list[tuple[str, ReactionKind]], reader: str) -> list[ReactionCount]:
    """Every kind, in order, with its count and whether the reader gave it."""
    return [
        ReactionCount(
            kind=kind,
            count=sum(1 for _, given in reactions if given is kind),
            mine=(reader, kind) in reactions,
        )
        for kind in KINDS
    ]


class ReactionStore:
    def __init__(
        self, dynamodb: Any, table_name: str, circles: CircleStore, finds: FindStore, devices: DeviceStore,
        mutes: MuteStore, pushes: PushService, clock: Callable[[], datetime],
    ) -> None:
        self._dynamodb = dynamodb
        self._table = dynamodb.Table(table_name)
        self._circles = circles
        self._finds = finds
        self._devices = devices
        self._mutes = mutes
        self._pushes = pushes
        self._clock = clock

    # Reactions.

    def put(self, reactor: str, owner: str, sighting_id: str, kind: ReactionKind) -> list[ReactionCount]:
        """Gives the reaction (again is no change) and pushes the owner about a new one; the find's counts."""
        find = self._reachable_find(reactor, owner, sighting_id)
        now = self._clock().isoformat()
        try:
            self._table.put_item(
                Item={**_reaction_key(owner, sighting_id, reactor, kind), "reactor": reactor, "kind": kind.value,
                      "created_at": now},
                ConditionExpression="attribute_not_exists(pk)",
            )
            created = True
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            created = False
        # Every time, not only when new: a retry after a put cut short between the two writes still writes the copy
        # account deletion (#71) reads.
        self._table.put_item(Item={**reactor_copy_key(reactor, owner, sighting_id, kind.value), "created_at": now})
        if created:
            try:
                self._reacted(find, reactor, kind)
            except Exception:
                # A push failure never fails the reaction.
                log.exception("the reaction push failed")
        return self.counts(reactor, owner, sighting_id)

    def delete(self, reactor: str, owner: str, sighting_id: str, kind: ReactionKind) -> list[ReactionCount]:
        """Takes the reaction back; one that isn't there is no error. A waiting push leaves it out (the flush reads
        the reactions back). Works after leaving the circle too, like unmuting: it only ever removes the reactor's
        own. NotFound only when the find is gone."""
        if reactor == owner:
            raise OwnFind()
        if self._finds.find(owner, sighting_id) is None:
            raise NotFound()
        self._table.delete_item(Key=_reaction_key(owner, sighting_id, reactor, kind))
        self._table.delete_item(Key=reactor_copy_key(reactor, owner, sighting_id, kind.value))
        return self.counts(reactor, owner, sighting_id)

    def counts(
        self, reader: str, owner: str, sighting_id: str, *, blocked: set[str] | None = None
    ) -> list[ReactionCount]:
        """The find's counts as the reader sees them: without the reactions of accounts the reader blocked (#71)."""
        hidden = self._mutes.blocked_by(reader) if blocked is None else blocked
        return counts_of([pair for pair in self._reactions(owner, sighting_id) if pair[0] not in hidden], reader)

    def counts_for(self, reader: str, finds: list[tuple[str, str]]) -> dict[tuple[str, str], list[ReactionCount]]:
        """The counts of a feed page's finds: one query of each find's (small) reaction partition."""
        blocked = self._mutes.blocked_by(reader)
        return {key: self.counts(reader, *key, blocked=blocked) for key in dict.fromkeys(finds)}

    # Compare birds.

    def compare(self, subject: str, friend: str) -> list[ComparedSpecies]:
        """The friend's species, best method first (Seen beats Heard), from their finds in the circles the two share
        now. NotFound when they share none."""
        shared = set(self._circles.circle_ids_of(subject)) & set(self._circles.circle_ids_of(friend))
        if not shared or friend in self._mutes.blocked_by(subject):
            # A blocked friend's birds are hidden like their finds (#71).
            raise NotFound()
        best: dict[str, ComparedSpecies] = {}
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": Key("pk").eq(f"ACCOUNT#{friend}") & Key("sk").begins_with("FIND#"),
            "ProjectionExpression": "species_id, scientific_name, common_name, #method, circle_ids",
            "ExpressionAttributeNames": {"#method": "method"},
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**kwargs)
            for item in response["Items"]:
                if not shared & set(item.get("circle_ids", [])):
                    continue
                species = ComparedSpecies(
                    species_id=item["species_id"], scientific_name=item["scientific_name"],
                    common_name=item["common_name"], method=Method(item["method"]),
                )
                current = best.get(species.scientific_name)
                if current is None or (current.method is Method.HEARD and species.method is Method.SEEN):
                    best[species.scientific_name] = species
            if "LastEvaluatedKey" not in response:
                break
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
        return sorted(best.values(), key=lambda species: species.common_name)

    # The owner's push.

    def flush(self) -> ReactionFlushReport:
        """Sends each waiting buffer whose find's window has closed, as one alert of the reactions still there."""
        now = self._clock()
        sent = waiting = dropped = 0
        for item in self._buffers():
            owner, sighting_id = str(item["sk"]).split("#", 1)
            given = set(item.get("reactions", set()))
            last, shown = self._last_push(owner, sighting_id)
            if last is not None and now - last < REACTION_WINDOW:
                waiting += 1
                continue
            # It replaces the window's first alert on the phone, so it names those reactions too.
            if self._send_collapsed(owner, sighting_id, given, carried=shown):
                sent += 1
            else:
                dropped += 1
            self._clear(owner, sighting_id, given)
        return ReactionFlushReport(sent=sent, waiting=waiting, dropped=dropped)

    def _reacted(self, find: Find, reactor: str, kind: ReactionKind) -> None:
        if not self._hears(find, reactor):
            return
        last, shown = self._last_push(find.owner, find.sighting_id)
        if last is not None and self._clock() - last < REACTION_WINDOW:
            self._table.update_item(
                Key=reaction_buffer_key(find.owner, find.sighting_id),
                UpdateExpression="ADD reactions :given",
                ExpressionAttributeValues={":given": {f"{reactor}#{kind.value}"}},
            )
            return
        # The window is closed: this one and anything still waiting go now, as one.
        # Anything waiting belongs to the last window, whose alert this one replaces: it names those too.
        waiting = self._buffered(find.owner, find.sighting_id)
        carried = waiting | shown if waiting else set()
        self._send_collapsed(find.owner, find.sighting_id, {f"{reactor}#{kind.value}"}, carried=carried)
        if waiting:
            self._clear(find.owner, find.sighting_id, waiting)

    def _send_collapsed(self, owner: str, sighting_id: str, given: set[str], *, carried: set[str]) -> bool:
        """One alert of the given reactions, with the carried ones it replaces, of those that still stand and that
        the owner hears; nothing unless one of the given is among them. True when one went."""
        find = self._finds.find(owner, sighting_id)
        if find is None:
            return False
        standing = set(self._reactions(owner, sighting_id))

        def heard(values: set[str]) -> set[tuple[str, ReactionKind]]:
            pairs = {pair for pair in (_split(value) for value in values) if pair is not None and pair in standing}
            return {pair for pair in pairs if self._hears(find, pair[0])}

        new = heard(given)
        devices = self._devices.devices_of(owner)
        if not new or not devices:
            return False
        pairs = sorted(new | heard(carried), key=lambda pair: (KINDS.index(pair[1]), pair[0]))
        reactors = list(dict.fromkeys(reactor for reactor, _ in pairs))
        names = self._circles.display_names(reactors)
        title, body = reaction_words(
            [names.get(reactor, FRIEND_FALLBACK) for reactor in reactors], find.content.common_name,
            [kind for _, kind in pairs],
        )
        mine = set(self._circles.circle_ids_of(owner))
        push = Push(
            kind=PushKind.REACTION, title=title, body=body,
            data={"sighting_id": sighting_id, "circle_ids": [c for c in find.circle_ids if c in mine]},
            thread_id=f"find-{sighting_id}", collapse_id=f"reaction-{sighting_id}"[:64],
        )
        if self._pushes.deliver(devices, push):
            self._table.put_item(
                Item={
                    **reaction_push_key(owner, sighting_id), "at": self._clock().isoformat(),
                    "shown": {f"{reactor}#{kind.value}" for reactor, kind in pairs},
                }
            )
            return True
        return False

    def _hears(self, find: Find, reactor: str) -> bool:
        """Whether the owner hears of this reactor's reactions: not muted, and through a circle not muted."""
        mutes = self._mutes.mutes_of(find.owner)
        if mutes.silences(reactor):
            return False
        through = set(find.circle_ids) & set(self._circles.circle_ids_of(reactor))
        return bool(through - mutes.circles)

    def _reachable_find(self, reactor: str, owner: str, sighting_id: str) -> Find:
        if reactor == owner:
            raise OwnFind()
        find = self._finds.find(owner, sighting_id)
        if find is None or not set(find.circle_ids) & set(self._circles.circle_ids_of(reactor)):
            raise NotFound()
        return find

    def _reactions(self, owner: str, sighting_id: str) -> list[tuple[str, ReactionKind]]:
        found: list[tuple[str, ReactionKind]] = []
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": Key("pk").eq(_reactions_pk(owner, sighting_id)) & Key("sk").begins_with("REACTION#"),
            "ProjectionExpression": "sk",
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**kwargs)
            for item in response["Items"]:
                pair = _split(str(item["sk"]).removeprefix("REACTION#"))
                if pair is not None:
                    found.append(pair)
            if "LastEvaluatedKey" not in response:
                return found
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    def _buffered(self, owner: str, sighting_id: str) -> set[str]:
        item = self._table.get_item(Key=reaction_buffer_key(owner, sighting_id), ConsistentRead=True).get("Item")
        return set(item.get("reactions", set())) if item else set()

    def _clear(self, owner: str, sighting_id: str, given: set[str]) -> None:
        """Takes out what was read; the buffer goes only if nothing came in meanwhile."""
        if given:
            self._table.update_item(
                Key=reaction_buffer_key(owner, sighting_id), UpdateExpression="DELETE reactions :given",
                ExpressionAttributeValues={":given": given},
            )
        try:
            self._table.delete_item(
                Key=reaction_buffer_key(owner, sighting_id), ConditionExpression="attribute_not_exists(reactions)"
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def _buffers(self) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {"KeyConditionExpression": Key("pk").eq(REACTIONS_PK), "ConsistentRead": True}
        while True:
            response = self._table.query(**kwargs)
            items.extend(response["Items"])
            if "LastEvaluatedKey" not in response:
                return items
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    def _last_push(self, owner: str, sighting_id: str) -> tuple[datetime | None, set[str]]:
        """When the owner last got a reaction alert about the find, and the reactions it named."""
        item = self._table.get_item(Key=reaction_push_key(owner, sighting_id), ConsistentRead=True).get("Item")
        if not item:
            return None, set()
        return datetime.fromisoformat(item["at"]), set(item.get("shown", set()))


def _split(value: str) -> tuple[str, ReactionKind] | None:
    reactor, _, kind = value.rpartition("#")
    try:
        return reactor, ReactionKind(kind)
    except ValueError:
        return None


def _reactions_pk(owner: str, sighting_id: str) -> str:
    return f"FIND#{owner}#{sighting_id}"


def _reaction_key(owner: str, sighting_id: str, reactor: str, kind: ReactionKind) -> dict[str, str]:
    return {"pk": _reactions_pk(owner, sighting_id), "sk": f"REACTION#{reactor}#{kind.value}"}

