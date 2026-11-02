"""Devices and mutes (issue #63): where an account's pushes go, and whose finds it would rather not hear about.

Items, beside the account's (tables.py):

- `ACCOUNT#<sub>` / `DEVICE#<token>`: one per phone the account signed in on, with its APNs `environment` (`sandbox`
  for development-signed builds, `production` for TestFlight and the App Store) and when it registered (devices by
  account).
- `DEVICE#<token>` / `DEVICE`: which account holds the token now. A phone signed out of one account and into another
  registers the same token again; the previous account's item goes, so a phone never gets a second account's pushes.
- `ACCOUNT#<sub>` / `MUTE#CIRCLE#<id>` and `MUTE#FRIEND#<sub>`: a muted circle or friend (mutes by account).
"""

import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Any

from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

# APNs device tokens are hex; 32 bytes today, and Apple says to allow for longer ones.
_TOKEN = re.compile(r"^[0-9a-f]{64,200}$")


class Environment(StrEnum):
    SANDBOX = "sandbox"
    PRODUCTION = "production"


@dataclass(frozen=True)
class Device:
    token: str
    environment: Environment


@dataclass(frozen=True)
class Mutes:
    circles: frozenset[str] = field(default_factory=frozenset)
    friends: frozenset[str] = field(default_factory=frozenset)


def clean_token(raw: str) -> str:
    """The token as stored: lower-case hex. Raises ValueError otherwise."""
    token = raw.strip().lower()
    if not _TOKEN.match(token):
        raise ValueError("bad_device_token")
    return token


class DeviceStore:
    def __init__(self, table: Any, clock: Callable[[], datetime]) -> None:
        self._table = table
        self._clock = clock

    def register(self, subject: str, token: str, environment: Environment) -> None:
        """The phone's token goes to this account, and leaves any account that held it before."""
        previous = self._table.get_item(Key=_pointer_key(token), ConsistentRead=True).get("Item")
        if previous is not None and previous["owner"] != subject:
            self._table.delete_item(Key=_device_key(previous["owner"], token))
        now = self._clock().isoformat()
        self._table.put_item(Item={**_pointer_key(token), "owner": subject})
        self._table.put_item(
            Item={**_device_key(subject, token), "token": token, "environment": environment.value, "registered_at": now}
        )

    def unregister(self, subject: str, token: str) -> None:
        """Signing out: the phone gets no more of this account's pushes. Another account's token is left alone."""
        self._table.delete_item(Key=_device_key(subject, token))
        try:
            self._table.delete_item(
                Key=_pointer_key(token), ConditionExpression="#owner = :owner",
                ExpressionAttributeNames={"#owner": "owner"}, ExpressionAttributeValues={":owner": subject},
            )
        except ClientError as error:
            if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise

    def forget(self, token: str) -> None:
        """APNs says the token is gone (the app was removed, or the token isn't this app's)."""
        pointer = self._table.get_item(Key=_pointer_key(token), ConsistentRead=True).get("Item")
        if pointer is not None:
            self._table.delete_item(Key=_device_key(pointer["owner"], token))
            self._table.delete_item(Key=_pointer_key(token))

    def devices_of(self, subject: str) -> list[Device]:
        items = _query(self._table, Key("pk").eq(f"ACCOUNT#{subject}") & Key("sk").begins_with("DEVICE#"))
        return [Device(token=item["token"], environment=Environment(item["environment"])) for item in items]


class MuteStore:
    def __init__(self, table: Any, clock: Callable[[], datetime]) -> None:
        self._table = table
        self._clock = clock

    def mutes_of(self, subject: str) -> Mutes:
        items = _query(self._table, Key("pk").eq(f"ACCOUNT#{subject}") & Key("sk").begins_with("MUTE#"))
        circles = {str(item["sk"]).removeprefix("MUTE#CIRCLE#") for item in items if item["sk"].startswith("MUTE#CIRCLE#")}
        friends = {str(item["sk"]).removeprefix("MUTE#FRIEND#") for item in items if item["sk"].startswith("MUTE#FRIEND#")}
        return Mutes(circles=frozenset(circles), friends=frozenset(friends))

    def mute_circle(self, subject: str, circle_id: str) -> None:
        self._put(subject, f"MUTE#CIRCLE#{circle_id}")

    def unmute_circle(self, subject: str, circle_id: str) -> None:
        self._table.delete_item(Key={"pk": f"ACCOUNT#{subject}", "sk": f"MUTE#CIRCLE#{circle_id}"})

    def mute_friend(self, subject: str, friend: str) -> None:
        self._put(subject, f"MUTE#FRIEND#{friend}")

    def unmute_friend(self, subject: str, friend: str) -> None:
        self._table.delete_item(Key={"pk": f"ACCOUNT#{subject}", "sk": f"MUTE#FRIEND#{friend}"})

    def _put(self, subject: str, sort_key: str) -> None:
        self._table.put_item(Item={"pk": f"ACCOUNT#{subject}", "sk": sort_key, "muted_at": self._clock().isoformat()})


def _device_key(subject: str, token: str) -> dict[str, str]:
    return {"pk": f"ACCOUNT#{subject}", "sk": f"DEVICE#{token}"}


def _pointer_key(token: str) -> dict[str, str]:
    return {"pk": f"DEVICE#{token}", "sk": "DEVICE"}


def _query(table: Any, condition: Any) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {"KeyConditionExpression": condition, "ConsistentRead": True}
    while True:
        response = table.query(**kwargs)
        items.extend(response["Items"])
        if "LastEvaluatedKey" not in response:
            return items
        kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
