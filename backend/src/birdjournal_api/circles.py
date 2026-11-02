"""Circles (issue #61, ADR-0005): the only social unit. A birder creates and names one, any member invites by a link
that expires after seven days, a friend joins by opening it, members leave, and the creator removes members. A circle
holds at most 20 accounts; an account can be in several circles.

Items, beside the account's (tables.py):

- `CIRCLE#<id>` / `META`: the name, the creator, the time zone, `created_at` and `member_count` (current members).
- `CIRCLE#<id>` / `MEMBER#<sub>`: one per account that ever joined: `joined_at`, and `left_at` once it left or was
  removed (`removed_at` too when the creator removed it). Members by circle, with joined and left times.
- `ACCOUNT#<sub>` / `CIRCLE#<id>`: the account's current circles (circles by member), written and deleted in the same
  transaction as the membership, so the two never disagree.
- `INVITE#<token>` / `INVITE`: the circle, who invited, `created_at`, `expires_at`, and `ttl` (epoch seconds, 30 days
  after expiry) for DynamoDB's time-to-live to clean up.
- `ACCOUNT#<sub>` / `INVITE#<token>` and `ACCOUNT#<sub>` / `LEFT#<id>` (issue #71): the invites an account made and
  the circles it left or was removed from, so deleting the account finds them without a scan. Same `ttl` as the invite.

The cap holds under concurrent joins: a join increments `member_count` on the condition that it is below 20, in one
transaction with the membership.
"""

import secrets
import time
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any
from uuid import uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from botocore.exceptions import ClientError

from birdjournal_api.accounts import AccountStore

MAX_MEMBERS = 20
CIRCLE_NAME_MAX = 40
INVITE_LIFETIME = timedelta(days=7)
# Expired invites stay readable this long, so an old link says "expired" rather than "not found".
INVITE_KEPT_AFTER_EXPIRY = timedelta(days=30)
TRANSACTION_ATTEMPTS = 4


class CircleError(Exception):
    """A refused circle operation; the API maps each subclass to a status."""


class NotFound(CircleError):
    """No such circle for this account (it isn't a member), or no such member or invite."""


class Forbidden(CircleError):
    """Only the creator removes members."""


class CircleFull(CircleError):
    """The circle already has 20 members."""


class InviteExpired(CircleError):
    pass


class InviteRevoked(CircleError):
    """The account was removed from the circle after this invite was made."""


@dataclass(frozen=True)
class Member:
    id: str
    display_name: str | None
    joined_at: datetime
    is_creator: bool


@dataclass(frozen=True)
class Circle:
    id: str
    name: str
    created_by: str
    created_at: datetime
    time_zone: str
    member_count: int


@dataclass(frozen=True)
class CircleDetail:
    circle: Circle
    members: list[Member]


@dataclass(frozen=True)
class Invite:
    token: str
    circle_id: str
    created_by: str
    created_at: datetime
    expires_at: datetime


@dataclass(frozen=True)
class InvitePreview:
    invite: Invite
    circle: Circle
    invited_by: str | None
    already_member: bool


def clean_circle_name(raw: str) -> str:
    """The name as stored: trimmed, 1 to 40 characters, no control characters. Raises ValueError otherwise."""
    name = raw.strip()
    if not name:
        raise ValueError("The circle name is empty")
    if len(name) > CIRCLE_NAME_MAX:
        raise ValueError(f"The circle name is longer than {CIRCLE_NAME_MAX} characters")
    if any(unicodedata.category(character).startswith("C") for character in name):
        raise ValueError("The circle name has a control character")
    return name


def clean_time_zone(raw: str) -> str:
    """An IANA zone the goals will run in (spec v2, "Goals"): the creator's device's at creation."""
    try:
        ZoneInfo(raw)
    except (ZoneInfoNotFoundError, ValueError) as error:
        raise ValueError(f"Unknown time zone {raw!r}") from error
    return raw


class CircleStore:
    def __init__(self, dynamodb: Any, table_name: str, accounts: AccountStore, clock: Callable[[], datetime]) -> None:
        self._dynamodb = dynamodb
        self._table = dynamodb.Table(table_name)
        self._accounts = accounts
        self._clock = clock

    # Reads.

    def circles_of(self, subject: str) -> list[Circle]:
        """The account's current circles, oldest first."""
        response = self._query(pk=_account_pk(subject), sk_prefix="CIRCLE#")
        ids = [item["sk"].removeprefix("CIRCLE#") for item in response]
        metas = self._batch_get([_meta_key(circle_id) for circle_id in ids])
        circles = [_circle(metas[_meta_pk(circle_id)]) for circle_id in ids if _meta_pk(circle_id) in metas]
        return sorted(circles, key=lambda circle: circle.created_at)

    def detail(self, subject: str, circle_id: str) -> CircleDetail:
        """The circle and its current members, for a member; NotFound for anyone else."""
        meta, members = self._circle_items(circle_id)
        if meta is None or not any(_is_current(item) and _member_id(item) == subject for item in members):
            raise NotFound()
        circle = _circle(meta)
        current = [item for item in members if _is_current(item)]
        names = self._display_names([_member_id(item) for item in current])
        return CircleDetail(
            circle=circle,
            members=sorted(
                (
                    Member(
                        id=_member_id(item),
                        display_name=names.get(_member_id(item)),
                        joined_at=datetime.fromisoformat(item["joined_at"]),
                        is_creator=_member_id(item) == circle.created_by,
                    )
                    for item in current
                ),
                key=lambda member: member.joined_at,
            ),
        )

    def circle(self, circle_id: str) -> Circle | None:
        """The circle's meta, whoever asks: for the goals (issue #65), which check membership themselves."""
        item = self._get(_meta_key(circle_id))
        return _circle(item) if item is not None else None

    def circle_ids_of(self, subject: str) -> list[str]:
        """The ids of the account's current circles, for a find's fan-out (issue #62)."""
        return [item["sk"].removeprefix("CIRCLE#") for item in self._query(pk=_account_pk(subject), sk_prefix="CIRCLE#")]

    def is_member(self, subject: str, circle_id: str) -> bool:
        """Whether the account is in the circle now."""
        return self._is_member(subject, circle_id)

    def display_names(self, subjects: list[str]) -> dict[str, str]:
        """The names of the accounts that set one."""
        return self._display_names(subjects)

    def current_member_ids(self, circle_id: str) -> list[str]:
        """Who is in the circle now, for a find's pushes (issue #63)."""
        return [_member_id(item) for item in self._query(pk=_meta_pk(circle_id), sk_prefix="MEMBER#") if _is_current(item)]

    def circle_names(self, circle_ids: list[str]) -> dict[str, str]:
        """The circles' names by id, for a push's words."""
        metas = self._batch_get([_meta_key(circle_id) for circle_id in circle_ids])
        return {pk.removeprefix("CIRCLE#"): item["name"] for pk, item in metas.items()}

    def share_a_circle(self, subject: str, other: str) -> bool:
        """Whether the two accounts are in a circle together now."""
        return bool(set(self.circle_ids_of(subject)) & set(self.circle_ids_of(other)))

    # Writes.

    def create(self, subject: str, name: str, time_zone: str) -> CircleDetail:
        """A new circle with its creator as the only member."""
        self._accounts.get_or_create(subject)
        circle_id = str(uuid4())
        now = _timestamp(self._clock())
        self._transact(
            [
                _put(
                    {
                        **_meta_key(circle_id),
                        "name": name,
                        "created_by": subject,
                        "created_at": now,
                        "time_zone": time_zone,
                        "member_count": 1,
                    },
                    "attribute_not_exists(pk)",
                ),
                _put({**_member_key(circle_id, subject), "joined_at": now}, "attribute_not_exists(pk)"),
                _put({**_membership_key(subject, circle_id), "joined_at": now}, "attribute_not_exists(pk)"),
            ]
        )
        return self.detail(subject, circle_id)

    def create_invite(self, subject: str, circle_id: str) -> Invite:
        """A link any member can make; it works for anyone until it expires."""
        if not self._is_member(subject, circle_id):
            raise NotFound()
        now = self._clock()
        invite = Invite(
            # 128 bits: the token is the only thing between a stranger and the circle.
            token=secrets.token_urlsafe(16),
            circle_id=circle_id,
            created_by=subject,
            created_at=now,
            expires_at=now + INVITE_LIFETIME,
        )
        ttl = int((invite.expires_at + INVITE_KEPT_AFTER_EXPIRY).timestamp())
        self._table.put_item(
            Item={
                **_invite_key(invite.token),
                "circle_id": circle_id,
                "created_by": subject,
                "created_at": _timestamp(invite.created_at),
                "expires_at": _timestamp(invite.expires_at),
                "ttl": ttl,
            },
            ConditionExpression="attribute_not_exists(pk)",
        )
        # The account's copy, for account deletion (#71).
        self._table.put_item(Item={"pk": _account_pk(subject), "sk": f"INVITE#{invite.token}", "ttl": ttl})
        return invite

    def preview(self, subject: str, token: str) -> InvitePreview:
        """What the join screen shows before the birder joins: the circle's name, its size and who invited."""
        invite = self._live_invite(token)
        meta = self._get(_meta_key(invite.circle_id))
        if meta is None:
            raise NotFound()
        inviter = self._display_names([invite.created_by]).get(invite.created_by)
        return InvitePreview(
            invite=invite,
            circle=_circle(meta),
            invited_by=inviter,
            already_member=self._is_member(subject, invite.circle_id),
        )

    def accept(self, subject: str, token: str) -> CircleDetail:
        """Joins the invite's circle. Joining a circle the account is already in changes nothing."""
        invite = self._live_invite(token)
        self._accounts.get_or_create(subject)
        circle_id = invite.circle_id
        previous = self._get(_member_key(circle_id, subject))
        if previous is not None and _is_current(previous):
            return self.detail(subject, circle_id)
        if previous is not None and "removed_at" in previous and invite.created_at <= _parse(previous["removed_at"]):
            # Removed by the creator: an invite from before the removal doesn't let them straight back in.
            raise InviteRevoked()
        now = _timestamp(self._clock())
        try:
            self._transact(
                [
                    {
                        "Update": {
                            "Key": _meta_key(circle_id),
                            "UpdateExpression": "SET member_count = member_count + :one",
                            "ConditionExpression": "attribute_exists(pk) AND member_count < :cap",
                            "ExpressionAttributeValues": {":one": 1, ":cap": MAX_MEMBERS},
                        }
                    },
                    _put(
                        {**_member_key(circle_id, subject), "joined_at": now},
                        # A first join, or a rejoin after leaving; never a second current membership.
                        "attribute_not_exists(pk) OR attribute_exists(left_at)",
                    ),
                    _put({**_membership_key(subject, circle_id), "joined_at": now}, None),
                ]
            )
        except _TransactionCancelled as cancelled:
            if cancelled.failed(1):
                # A concurrent accept by the same account got there first.
                return self.detail(subject, circle_id)
            if cancelled.failed(0):
                raise CircleFull() from None
            raise
        return self.detail(subject, circle_id)

    def leave(self, subject: str, circle_id: str) -> None:
        """The account leaves. A creator who leaves hands the circle to its longest-standing remaining member."""
        for attempt in range(TRANSACTION_ATTEMPTS):
            meta, members = self._circle_items(circle_id)
            if meta is None or not any(_is_current(item) and _member_id(item) == subject for item in members):
                raise NotFound()
            successor = None
            if meta["created_by"] == subject:
                others = sorted(
                    (item for item in members if _is_current(item) and _member_id(item) != subject),
                    key=lambda item: item["joined_at"],
                )
                successor = _member_id(others[0]) if others else None
            if self._end_membership(
                circle_id, subject, removed=False, creator=meta["created_by"], successor=successor,
                last_attempt=attempt + 1 == TRANSACTION_ATTEMPTS,
            ):
                return

    def remove(self, subject: str, circle_id: str, member_id: str) -> None:
        """The creator removes a member."""
        for attempt in range(TRANSACTION_ATTEMPTS):
            meta, members = self._circle_items(circle_id)
            current = {_member_id(item) for item in members if _is_current(item)}
            if meta is None or subject not in current:
                raise NotFound()
            if meta["created_by"] != subject:
                raise Forbidden()
            if member_id == subject:
                raise ValueError("The creator leaves rather than removing themselves")
            if member_id not in current:
                raise NotFound()
            if self._end_membership(
                circle_id, member_id, removed=True, creator=subject, successor=None,
                last_attempt=attempt + 1 == TRANSACTION_ATTEMPTS,
            ):
                return

    # Account deletion (#71).

    def items_of_circle(self, circle_id: str) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
        """The circle's meta and every membership item, current and past."""
        return self._circle_items(circle_id)

    def forget_member(self, circle_id: str, subject: str) -> None:
        """Deletes a past membership's item, once the account has left (deleting the account). Its `LEFT#` copy stays
        for the deletion's last sweep, so a deletion cut short still finds the circle when retried."""
        try:
            self._table.delete_item(
                Key=_member_key(circle_id, subject), ConditionExpression="attribute_exists(left_at)"
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def delete_circle(self, circle_id: str, subject: str) -> bool:
        """Deletes a circle with no other current member: its meta, memberships, feed, species entries, goals and
        rollover entry. False (nothing deleted) when someone else is in it now."""
        meta, members = self._circle_items(circle_id)
        if any(_is_current(item) and _member_id(item) != subject for item in members):
            return False
        keys: list[dict[str, str]] = []
        for pk in (_meta_pk(circle_id), f"{_meta_pk(circle_id)}#FEED", f"{_meta_pk(circle_id)}#SPECIES", f"{_meta_pk(circle_id)}#GOALS"):
            keys.extend({"pk": item["pk"], "sk": item["sk"]} for item in self._query(pk=pk))
        keys.append({"pk": "GOAL_ROLLOVER", "sk": circle_id})
        keys.extend(_membership_key(_member_id(item), circle_id) for item in members if _is_current(item))
        keys.extend(_left_key(_member_id(item), circle_id) for item in members)
        with self._table.batch_writer(overwrite_by_pkeys=["pk", "sk"]) as batch:
            for key in keys:
                batch.delete_item(Key=key)
        return True

    # Helpers.

    def _end_membership(
        self, circle_id: str, member_id: str, *, removed: bool, creator: str, successor: str | None, last_attempt: bool
    ) -> bool:
        """Ends one membership, on the conditions the caller read: the circle still has `creator` as its creator,
        the member is still in it, and a successor (when the creator leaves) still is too. False when a concurrent
        leave or handoff changed what was read, so the caller reads again and retries."""
        now = _timestamp(self._clock())
        meta_update = "SET member_count = member_count - :one"
        values: dict[str, Any] = {":one": 1, ":creator": creator}
        if successor is not None:
            meta_update += ", created_by = :successor"
            values[":successor"] = successor
        member_update = "SET left_at = :now" + (", removed_at = :now" if removed else "")
        items: list[dict[str, Any]] = [
            {
                "Update": {
                    "Key": _meta_key(circle_id),
                    "UpdateExpression": meta_update,
                    # The creator read is still the creator: two handoffs at once can't name someone who left.
                    "ConditionExpression": "created_by = :creator",
                    "ExpressionAttributeValues": values,
                }
            },
            {
                "Update": {
                    "Key": _member_key(circle_id, member_id),
                    "UpdateExpression": member_update,
                    # Two leaves at once must not count the member out twice.
                    "ConditionExpression": "attribute_exists(pk) AND attribute_not_exists(left_at)",
                    "ExpressionAttributeValues": {":now": now},
                }
            },
            {"Delete": {"Key": _membership_key(member_id, circle_id)}},
            # The circles an account left, for account deletion (#71): its membership item stays in the circle.
            _put({**_left_key(member_id, circle_id), "left_at": now}, None),
        ]
        if successor is not None:
            items.append(
                {
                    "ConditionCheck": {
                        "Key": _member_key(circle_id, successor),
                        "ConditionExpression": "attribute_exists(pk) AND attribute_not_exists(left_at)",
                    }
                }
            )
        try:
            self._transact(items)
        except _TransactionCancelled as cancelled:
            if cancelled.failed(1):
                # Already gone: a concurrent leave or removal got there first.
                raise NotFound() from None
            if last_attempt:
                raise
            return False
        return True

    def _live_invite(self, token: str) -> Invite:
        item = self._get(_invite_key(token)) if token else None
        if item is None:
            raise NotFound()
        invite = Invite(
            token=token,
            circle_id=item["circle_id"],
            created_by=item["created_by"],
            created_at=_parse(item["created_at"]),
            expires_at=_parse(item["expires_at"]),
        )
        if self._clock() >= invite.expires_at:
            raise InviteExpired()
        return invite

    def _is_member(self, subject: str, circle_id: str) -> bool:
        return self._get(_membership_key(subject, circle_id)) is not None

    def _circle_items(self, circle_id: str) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
        items = self._query(pk=_meta_pk(circle_id))
        meta = next((item for item in items if item["sk"] == "META"), None)
        members = [item for item in items if item["sk"].startswith("MEMBER#")]
        return meta, members

    def _display_names(self, subjects: list[str]) -> dict[str, str]:
        profiles = self._batch_get([{"pk": f"ACCOUNT#{subject}", "sk": "PROFILE"} for subject in subjects])
        return {
            pk.removeprefix("ACCOUNT#"): item["display_name"]
            for pk, item in profiles.items()
            if item.get("display_name")
        }

    def _get(self, key: dict[str, str]) -> dict[str, Any] | None:
        item: dict[str, Any] | None = self._table.get_item(Key=key, ConsistentRead=True).get("Item")
        return item

    def _query(self, *, pk: str, sk_prefix: str | None = None) -> list[dict[str, Any]]:
        expression = "pk = :pk" + (" AND begins_with(sk, :prefix)" if sk_prefix else "")
        values = {":pk": pk, **({":prefix": sk_prefix} if sk_prefix else {})}
        items: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": expression,
            "ExpressionAttributeValues": values,
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**kwargs)
            items.extend(response["Items"])
            if "LastEvaluatedKey" not in response:
                return items
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    def _batch_get(self, keys: list[dict[str, str]]) -> dict[str, dict[str, Any]]:
        """Items by pk (every key here has a distinct pk). BatchGetItem takes 100 keys a call."""
        found: dict[str, dict[str, Any]] = {}
        unique = list({key["pk"]: key for key in keys}.values())
        for start in range(0, len(unique), 100):
            request: dict[str, Any] = {self._table.name: {"Keys": unique[start : start + 100], "ConsistentRead": True}}
            while request:
                # The resource's batch_get_item returns plain Python values, like Table.get_item.
                response = self._dynamodb.batch_get_item(RequestItems=request)
                for item in response.get("Responses", {}).get(self._table.name, []):
                    found[item["pk"]] = item
                request = response.get("UnprocessedKeys") or {}
        return found

    def _transact(self, items: list[dict[str, Any]]) -> None:
        """TransactWriteItems is only on the client; the resource's client takes plain values like the table does.
        Racing joins on one circle can cancel each other with TransactionConflict, so those retry a few times."""
        for attempt in range(TRANSACTION_ATTEMPTS):
            try:
                self._dynamodb.meta.client.transact_write_items(
                    TransactItems=[_with_table(self._table.name, item) for item in items]
                )
                return
            except ClientError as error:
                if error.response["Error"]["Code"] != "TransactionCanceledException":
                    raise
                codes = [reason.get("Code") for reason in error.response.get("CancellationReasons", [])]
                if "TransactionConflict" in codes and attempt + 1 < TRANSACTION_ATTEMPTS:
                    time.sleep(0.05 * (attempt + 1))
                    continue
                raise _TransactionCancelled(codes) from error


class _TransactionCancelled(Exception):
    def __init__(self, codes: list[str | None]) -> None:
        super().__init__(codes)
        self.codes = codes

    def failed(self, index: int) -> bool:
        return index < len(self.codes) and self.codes[index] == "ConditionalCheckFailed"


def _with_table(table_name: str, operation: dict[str, Any]) -> dict[str, Any]:
    """One transaction item with the table filled in. The resource's client serializes the values itself, as
    Table.put_item does."""
    ((kind, body),) = operation.items()
    return {kind: {**body, "TableName": table_name}}


def _put(item: dict[str, Any], condition: str | None) -> dict[str, Any]:
    put: dict[str, Any] = {"Item": item}
    if condition:
        put["ConditionExpression"] = condition
    return {"Put": put}


def _meta_pk(circle_id: str) -> str:
    return f"CIRCLE#{circle_id}"


def _meta_key(circle_id: str) -> dict[str, str]:
    return {"pk": _meta_pk(circle_id), "sk": "META"}


def _member_key(circle_id: str, subject: str) -> dict[str, str]:
    return {"pk": _meta_pk(circle_id), "sk": f"MEMBER#{subject}"}


def _account_pk(subject: str) -> str:
    return f"ACCOUNT#{subject}"


def _membership_key(subject: str, circle_id: str) -> dict[str, str]:
    return {"pk": _account_pk(subject), "sk": f"CIRCLE#{circle_id}"}


def _left_key(subject: str, circle_id: str) -> dict[str, str]:
    return {"pk": _account_pk(subject), "sk": f"LEFT#{circle_id}"}


def _invite_key(token: str) -> dict[str, str]:
    return {"pk": f"INVITE#{token}", "sk": "INVITE"}


def _member_id(item: dict[str, Any]) -> str:
    return str(item["sk"]).removeprefix("MEMBER#")


def _is_current(item: dict[str, Any]) -> bool:
    return "left_at" not in item


def _timestamp(moment: datetime) -> str:
    return moment.isoformat()


def _parse(value: str) -> datetime:
    return datetime.fromisoformat(value)


def _circle(item: dict[str, Any]) -> Circle:
    return Circle(
        id=str(item["pk"]).removeprefix("CIRCLE#"),
        name=item["name"],
        created_by=item["created_by"],
        created_at=_parse(item["created_at"]),
        time_zone=item["time_zone"],
        member_count=int(item["member_count"]),
    )
