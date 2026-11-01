"""Accounts: one per Cognito subject, created on its first authenticated call."""

import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from botocore.exceptions import ClientError

DISPLAY_NAME_MAX = 40


@dataclass(frozen=True)
class Account:
    id: str
    display_name: str | None
    created_at: datetime


def clean_display_name(raw: str) -> str:
    """The name as stored: trimmed, 1 to 40 characters, no control characters. Raises ValueError otherwise."""
    name = raw.strip()
    if not name:
        raise ValueError("The display name is empty")
    if len(name) > DISPLAY_NAME_MAX:
        raise ValueError(f"The display name is longer than {DISPLAY_NAME_MAX} characters")
    if any(unicodedata.category(character).startswith("C") for character in name):
        raise ValueError("The display name has a control character")
    return name


class AccountStore:
    def __init__(self, table: Any, clock: Callable[[], datetime]) -> None:
        self._table = table
        self._clock = clock

    def get_or_create(self, subject: str) -> Account:
        item = self._table.get_item(Key=_key(subject), ConsistentRead=True).get("Item")
        if item is None:
            item = {**_key(subject), "created_at": _timestamp(self._clock())}
            try:
                self._table.put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
            except ClientError as error:
                if error.response["Error"]["Code"] != "ConditionalCheckFailedException":
                    raise
                # Another request for the same subject created it first.
                item = self._table.get_item(Key=_key(subject), ConsistentRead=True)["Item"]
        return _account(subject, item)

    def update_display_name(self, subject: str, display_name: str) -> Account:
        """Sets the name, creating the account if this is the subject's first call."""
        item = self._table.update_item(
            Key=_key(subject),
            UpdateExpression="SET display_name = :name, created_at = if_not_exists(created_at, :now)",
            ExpressionAttributeValues={":name": display_name, ":now": _timestamp(self._clock())},
            ReturnValues="ALL_NEW",
        )["Attributes"]
        return _account(subject, item)


def _key(subject: str) -> dict[str, str]:
    return {"pk": f"ACCOUNT#{subject}", "sk": "PROFILE"}


def _timestamp(moment: datetime) -> str:
    return moment.isoformat()


def _account(subject: str, item: dict[str, Any]) -> Account:
    return Account(
        id=subject,
        display_name=item.get("display_name"),
        created_at=datetime.fromisoformat(item["created_at"]),
    )
