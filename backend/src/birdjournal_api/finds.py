"""Finds (issue #62, spec v2 "Finds"): a member's sightings reaching their circles. The phone's find policy decides
what a find carries (species, Heard or Seen, a city or "a secret spot", the time to the minute, the Legendary and
rarity flags, the art reference); the server never receives a coordinate and refuses a place label that holds one.

A find fans out to every circle the owner is in when it is first written. Joining a circle later doesn't backfill it,
and leaving keeps the items already there. A repeated put (Heard changed to Seen, art ready) updates the find and its
feed items without adding circles or duplicating anything. A delete removes the find, its feed items, its species
entries and its reactions.

Items, beside the account's and the circles' (tables.py, circles.py):

- `ACCOUNT#<sub>` / `FIND#<sighting id>`: the find as the phone sent it, `created_at`, `updated_at`, and
  `circle_ids`, the circles it went to (finds by owner). Keyed by owner, so two accounts' sighting ids never collide.
- `CIRCLE#<id>#FEED` / `<found at>#<sub>#<sighting id>`: one feed item per circle the find went to, a copy of the find
  with its owner; the feed reads this partition newest first. A partition of its own, so the circle's meta and member
  queries (circles.py) never page through finds.
- `CIRCLE#<id>#SPECIES` / `<scientific name>#<found at>#<sub>#<sighting id>`: the same items ordered by species and
  then time, so "First for the circle" is one query per species: the earliest surviving item. Computed when the feed
  is read, so a deleted first passes the mark on with nothing to recompute.
- `FIND#<sub>#<sighting id>` / `REACTION#...`: reactions by find, written by the reactions ticket (#63); a delete
  removes the whole partition.

Not transactional: a find can go to more circles than one transaction holds. A put writes the find (with the circles it
goes to) before its feed items, and a delete removes the items before the find, so the find always lists every circle
that may hold an item of it, and a put or delete that fails half way is finished by the phone's retry (the outbox).
"""

import base64
import binascii
import re
import unicodedata
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from boto3.dynamodb.conditions import Key

from birdjournal_api.accounts import AccountStore
from birdjournal_api.circles import CircleStore, NotFound

SECRET_SPOT = "a secret spot"
PLACE_MAX = 80
NAME_MAX = 120
FEED_PAGE_DEFAULT = 20
FEED_PAGE_MAX = 50
# A decimal number with two or more decimals (34.13), a degree sign, or degrees-minutes notation: what a coordinate
# looks like in text, or minutes and seconds after a number (34 8' N). A city name has none of these.
_COORDINATE = re.compile(r"\d+[.,]\d{2,}|°|\d\s*['′″\"]")
_ART_KEY = re.compile(r"^(packs|art)/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.(jpg|jpeg|png|webp)$")


class Method(StrEnum):
    HEARD = "heard"
    SEEN = "seen"


class Rarity(StrEnum):
    COMMON = "common"
    UNCOMMON = "uncommon"
    RARE = "rare"
    EXCEPTIONAL = "exceptional"


class ArtKind(StrEnum):
    # A pack-art thumbnail the pack publish step uploaded to the art CDN, under packs/.
    PACK = "pack"
    # Painted scene art (#68, shown on finds from #70), under art/.
    PAINTED = "painted"


@dataclass(frozen=True)
class ArtReference:
    kind: ArtKind
    key: str


@dataclass(frozen=True)
class FindContent:
    """What the phone sends: the find policy's payload."""

    species_id: str
    scientific_name: str
    common_name: str
    method: Method
    place: str | None
    found_at: datetime
    legendary: bool
    rarity: Rarity | None
    threatened: bool
    art: ArtReference | None


@dataclass(frozen=True)
class Find:
    owner: str
    sighting_id: str
    content: FindContent
    circle_ids: list[str]
    created_at: datetime
    updated_at: datetime


@dataclass(frozen=True)
class FeedItem:
    owner: str
    owner_name: str | None
    sighting_id: str
    content: FindContent
    posted_at: datetime
    circle_first: bool


@dataclass(frozen=True)
class FeedPage:
    items: list[FeedItem]
    next_cursor: str | None


class BadCursor(ValueError):
    pass


def clean_place(raw: str | None, *, threatened: bool) -> str | None:
    """The place label as stored: a threatened species always gets "a secret spot", whatever the phone sent (the
    rule holds on the server too); otherwise a city of 1 to 80 characters with no control characters and nothing that
    looks like a coordinate. Raises ValueError otherwise."""
    if threatened:
        return SECRET_SPOT
    if raw is None:
        return None
    place = raw.strip()
    if not place:
        return None
    if len(place) > PLACE_MAX:
        raise ValueError(f"The place is longer than {PLACE_MAX} characters")
    if _has_control_character(place):
        raise ValueError("The place has a control character")
    if _COORDINATE.search(place):
        raise ValueError("place_has_coordinate")
    return place


def clean_name(raw: str, *, field: str) -> str:
    name = raw.strip()
    if not name or len(name) > NAME_MAX:
        raise ValueError(f"The {field} must be 1 to {NAME_MAX} characters")
    if _has_control_character(name) or "#" in name:
        raise ValueError(f"The {field} has a character it can't")
    return name


def clean_found_at(value: datetime) -> datetime:
    """The time to the minute, in UTC: the seconds never leave the phone, and are dropped here if they do."""
    if value.tzinfo is None:
        raise ValueError("found_at needs a time zone")
    return value.astimezone(UTC).replace(second=0, microsecond=0)


def clean_art(kind: ArtKind, key: str) -> ArtReference:
    if ".." in key or not _ART_KEY.match(key):
        raise ValueError("The art key isn't an art CDN key")
    expected = "packs/" if kind is ArtKind.PACK else "art/"
    if not key.startswith(expected):
        raise ValueError(f"{kind.value} art lives under {expected}")
    return ArtReference(kind=kind, key=key)


class FindStore:
    def __init__(
        self, dynamodb: Any, table_name: str, accounts: AccountStore, circles: CircleStore,
        clock: Callable[[], datetime],
    ) -> None:
        self._dynamodb = dynamodb
        self._table = dynamodb.Table(table_name)
        self._accounts = accounts
        self._circles = circles
        self._clock = clock

    def put(self, owner: str, sighting_id: str, content: FindContent) -> tuple[Find, bool]:
        """Writes the find; True when it is new. A new find goes to the owner's current circles; a repeated put
        updates the circles it went to the first time and no others."""
        self._accounts.get_or_create(owner)
        now = self._clock()
        existing = self._get(_find_key(owner, sighting_id))
        if existing is None:
            circle_ids = self._circles.circle_ids_of(owner)
            created_at = now
        else:
            circle_ids = list(existing.get("circle_ids", []))
            created_at = _parse(existing["created_at"])
            previous = _content(existing)
            if (previous.found_at, previous.scientific_name) != (content.found_at, content.scientific_name):
                # The items' keys hold the time and the species, so moved items go before the new ones are written.
                self._delete_items(_item_keys(owner, sighting_id, previous, circle_ids))
        find = Find(
            owner=owner, sighting_id=sighting_id, content=content, circle_ids=circle_ids,
            created_at=created_at, updated_at=now,
        )
        posted_at = _timestamp(created_at)
        # The find first: a retry after a failure part way reads the circles from it, not from today's memberships.
        self._table.put_item(
            Item={
                **_find_key(owner, sighting_id),
                **_content_attributes(content),
                "circle_ids": circle_ids,
                "created_at": posted_at,
                "updated_at": _timestamp(now),
            }
        )
        with self._table.batch_writer() as batch:
            for circle_id in circle_ids:
                batch.put_item(
                    Item={
                        **_feed_key(circle_id, owner, sighting_id, content),
                        **_content_attributes(content),
                        "owner": owner,
                        "sighting_id": sighting_id,
                        "posted_at": posted_at,
                    }
                )
                batch.put_item(
                    Item={**_species_key(circle_id, owner, sighting_id, content), "owner": owner, "sighting_id": sighting_id}
                )
        return find, existing is None

    def delete(self, owner: str, sighting_id: str) -> None:
        """Removes the find with its feed items, species entries and reactions. Deleting one that isn't there (a
        retried delete) changes nothing."""
        existing = self._get(_find_key(owner, sighting_id))
        if existing is not None:
            content = _content(existing)
            self._delete_items(_item_keys(owner, sighting_id, content, list(existing.get("circle_ids", []))))
        reactions = self._query_keys(Key("pk").eq(_reactions_pk(owner, sighting_id)))
        self._delete_items(reactions)
        if existing is not None:
            self._table.delete_item(Key=_find_key(owner, sighting_id))

    def find(self, owner: str, sighting_id: str) -> Find | None:
        item = self._get(_find_key(owner, sighting_id))
        if item is None:
            return None
        return Find(
            owner=owner, sighting_id=sighting_id, content=_content(item), circle_ids=list(item.get("circle_ids", [])),
            created_at=_parse(item["created_at"]), updated_at=_parse(item["updated_at"]),
        )

    def feed(self, subject: str, circle_id: str, *, limit: int, cursor: str | None) -> FeedPage:
        """A page of the circle's feed, newest find first, for a current member; NotFound for anyone else."""
        if not self._circles.is_member(subject, circle_id):
            raise NotFound()
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": Key("pk").eq(_feed_pk(circle_id)),
            "ScanIndexForward": False,
            "Limit": limit,
            "ConsistentRead": True,
        }
        if cursor is not None:
            kwargs["ExclusiveStartKey"] = {"pk": _feed_pk(circle_id), "sk": _decode_cursor(cursor)}
        response = self._table.query(**kwargs)
        items = response["Items"]
        last = response.get("LastEvaluatedKey")
        names = self._circles.display_names([item["owner"] for item in items])
        firsts = {
            name: self._first_of(circle_id, name) for name in {str(item["scientific_name"]) for item in items}
        }
        page = [
            FeedItem(
                owner=item["owner"],
                owner_name=names.get(item["owner"]),
                sighting_id=item["sighting_id"],
                content=_content(item),
                posted_at=_parse(item["posted_at"]),
                circle_first=firsts.get(str(item["scientific_name"])) == (item["owner"], item["sighting_id"]),
            )
            for item in items
        ]
        return FeedPage(items=page, next_cursor=_encode_cursor(last["sk"]) if last else None)

    def is_circle_first(self, circle_id: str, owner: str, sighting_id: str, scientific_name: str) -> bool:
        """Whether the find is the circle's earliest surviving item of its species: the push decision at write time
        (issue #63), the same query the feed's mark reads."""
        return self._first_of(circle_id, scientific_name) == (owner, sighting_id)

    def existing(self, keys: list[tuple[str, str]]) -> dict[tuple[str, str], FindContent]:
        """The finds of these (owner, sighting id) pairs that are still there, for a digest (issue #63)."""
        found: dict[tuple[str, str], FindContent] = {}
        unique = list(dict.fromkeys(keys))
        for start in range(0, len(unique), 100):
            request: dict[str, Any] = {
                self._table.name: {
                    "Keys": [_find_key(owner, sighting_id) for owner, sighting_id in unique[start : start + 100]],
                    "ConsistentRead": True,
                }
            }
            while request:
                response = self._dynamodb.batch_get_item(RequestItems=request)
                for item in response.get("Responses", {}).get(self._table.name, []):
                    owner = str(item["pk"]).removeprefix("ACCOUNT#")
                    found[(owner, str(item["sk"]).removeprefix("FIND#"))] = _content(item)
                request = response.get("UnprocessedKeys") or {}
        return found

    def _first_of(self, circle_id: str, scientific_name: str) -> tuple[str, str] | None:
        """The earliest surviving item of the species in the circle: (owner, sighting id)."""
        response = self._table.query(
            KeyConditionExpression=Key("pk").eq(_species_pk(circle_id)) & Key("sk").begins_with(f"{scientific_name}#"),
            ScanIndexForward=True,
            Limit=1,
            ConsistentRead=True,
        )
        items = response["Items"]
        return (items[0]["owner"], items[0]["sighting_id"]) if items else None

    def _get(self, key: dict[str, str]) -> dict[str, Any] | None:
        item: dict[str, Any] | None = self._table.get_item(Key=key, ConsistentRead=True).get("Item")
        return item

    def _query_keys(self, condition: Any) -> list[dict[str, str]]:
        keys: list[dict[str, str]] = []
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": condition,
            "ProjectionExpression": "pk, sk",
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**kwargs)
            keys.extend({"pk": item["pk"], "sk": item["sk"]} for item in response["Items"])
            if "LastEvaluatedKey" not in response:
                return keys
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

    def _delete_items(self, keys: list[dict[str, str]]) -> None:
        if not keys:
            return
        with self._table.batch_writer(overwrite_by_pkeys=["pk", "sk"]) as batch:
            for key in keys:
                batch.delete_item(Key=key)


def _has_control_character(text: str) -> bool:
    return any(unicodedata.category(character).startswith("C") for character in text)


def _content_attributes(content: FindContent) -> dict[str, Any]:
    attributes: dict[str, Any] = {
        "species_id": content.species_id,
        "scientific_name": content.scientific_name,
        "common_name": content.common_name,
        "method": content.method.value,
        "found_at": _minute(content.found_at),
        "legendary": content.legendary,
        "threatened": content.threatened,
    }
    if content.place is not None:
        attributes["place"] = content.place
    if content.rarity is not None:
        attributes["rarity"] = content.rarity.value
    if content.art is not None:
        attributes["art_kind"] = content.art.kind.value
        attributes["art_key"] = content.art.key
    return attributes


def _content(item: dict[str, Any]) -> FindContent:
    art = (
        ArtReference(kind=ArtKind(item["art_kind"]), key=item["art_key"])
        if "art_kind" in item and "art_key" in item
        else None
    )
    return FindContent(
        species_id=item["species_id"],
        scientific_name=item["scientific_name"],
        common_name=item["common_name"],
        method=Method(item["method"]),
        place=item.get("place"),
        found_at=_parse(item["found_at"]),
        legendary=bool(item["legendary"]),
        rarity=Rarity(item["rarity"]) if "rarity" in item else None,
        threatened=bool(item.get("threatened", False)),
        art=art,
    )


def _item_keys(owner: str, sighting_id: str, content: FindContent, circle_ids: list[str]) -> list[dict[str, str]]:
    keys: list[dict[str, str]] = []
    for circle_id in circle_ids:
        keys.append(_feed_key(circle_id, owner, sighting_id, content))
        keys.append(_species_key(circle_id, owner, sighting_id, content))
    return keys


def _find_key(owner: str, sighting_id: str) -> dict[str, str]:
    return {"pk": f"ACCOUNT#{owner}", "sk": f"FIND#{sighting_id}"}


def _feed_pk(circle_id: str) -> str:
    return f"CIRCLE#{circle_id}#FEED"


def _species_pk(circle_id: str) -> str:
    return f"CIRCLE#{circle_id}#SPECIES"


def _reactions_pk(owner: str, sighting_id: str) -> str:
    return f"FIND#{owner}#{sighting_id}"


def _feed_key(circle_id: str, owner: str, sighting_id: str, content: FindContent) -> dict[str, str]:
    return {"pk": _feed_pk(circle_id), "sk": f"{_minute(content.found_at)}#{owner}#{sighting_id}"}


def _species_key(circle_id: str, owner: str, sighting_id: str, content: FindContent) -> dict[str, str]:
    return {
        "pk": _species_pk(circle_id),
        "sk": f"{content.scientific_name}#{_minute(content.found_at)}#{owner}#{sighting_id}",
    }


def _minute(moment: datetime) -> str:
    """Sortable as text: always UTC, always the same width."""
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%MZ")


def _timestamp(moment: datetime) -> str:
    return moment.isoformat()


def _parse(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _encode_cursor(sort_key: str) -> str:
    return base64.urlsafe_b64encode(sort_key.encode()).decode().rstrip("=")


def _decode_cursor(cursor: str) -> str:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        sort_key = base64.urlsafe_b64decode(padded.encode()).decode()
    except (binascii.Error, UnicodeDecodeError, ValueError) as error:
        raise BadCursor("bad_cursor") from error
    if not sort_key or len(sort_key) > 400 or sort_key.count("#") != 2:
        raise BadCursor("bad_cursor")
    return sort_key
