"""Finds (issue #62, spec v2 "Finds"): a member's sightings reaching their circles. The phone's find policy decides
what a find carries (species, Heard or Seen, a city or "a secret spot", the time to the minute, whether it sewed a new
patch and in which edition, the rarity, the art reference); the server never receives a coordinate and refuses a place
label that holds one.

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
- `FIND#<sub>#<sighting id>` / `REACTION#<reactor>#<kind>`: reactions by find (reactions.py, issue #64); a delete
  removes the whole partition, each reaction's copy under its reactor, and the find's reaction-push items.
- `FIND#<sub>#<sighting id>` / `SHARE#<circle id>`: a card shared by hand to that circle (issue #66): the note, the
  caption and the original photo the birder chose, and whether the place was left out. Every write of the find's feed
  items lays the circle's share over the find, so the extras show in the circles chosen and nowhere else, and a later
  put (Heard changed to Seen) keeps them. In the reactions' partition, so a delete takes them with it.

Not transactional: a find can go to more circles than one transaction holds. A put writes the find (with the circles it
goes to) before its feed items, and a delete removes the items before the find, so the find always lists every circle
that may hold an item of it, and a put or delete that fails half way is finished by the phone's retry (the outbox).
"""

import base64
import binascii
import re
import unicodedata
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from boto3.dynamodb.conditions import Key

from birdjournal_api.accounts import AccountStore
from birdjournal_api.circles import CircleStore, NotFound
from birdjournal_api.moderation import Moderation
from birdjournal_api.photos import PHOTO_MAX_BYTES, PhotoStore, is_photo_key_of

SECRET_SPOT = "a secret spot"
PLACE_MAX = 80
NAME_MAX = 120
FEED_PAGE_DEFAULT = 20
FEED_PAGE_MAX = 50
NOTE_MAX = 2000
CAPTION_MAX = 300
# More than any one birder's circles in the friends phase; a bound on what one share writes.
SHARE_CIRCLES_MAX = 50
# A decimal number with two or more decimals (34.13), a degree sign, or degrees-minutes notation: what a coordinate
# looks like in text, or minutes and seconds after a number (34 8' N). A city name has none of these.
_COORDINATE = re.compile(r"\d+[.,]\d{2,}|°|\d\s*['′″\"]")
_ART_KEY = re.compile(r"^packs/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.(jpg|jpeg|png|webp)$")
# An edition is named by its set's pack id, like us-ca-la.
_EDITION = re.compile(r"^[a-z0-9-]{1,64}$")


class Method(StrEnum):
    HEARD = "heard"
    SEEN = "seen"


class Rarity(StrEnum):
    COMMON = "common"
    UNCOMMON = "uncommon"
    RARE = "rare"
    EXCEPTIONAL = "exceptional"


class ArtKind(StrEnum):
    # A thumbnail of the pack's patch the pack publish step uploaded to the art CDN, under packs/. Finds from before
    # #137 may name the watercolour pack art's thumbnail instead.
    PACK = "pack"


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
    # The sighting sewed its patch: the birder's first of the species in this edition. Frozen at the add on the phone.
    new_patch: bool
    rarity: Rarity | None
    threatened: bool
    art: ArtReference | None
    # The set the sighting is in, by pack id; None outside every set (Uncharted).
    edition: str | None = None


@dataclass(frozen=True)
class Find:
    owner: str
    sighting_id: str
    content: FindContent
    circle_ids: list[str]
    created_at: datetime
    updated_at: datetime


@dataclass(frozen=True)
class CardExtras:
    """What a card shared by hand adds to the find, in the circles it was shared to (issue #66). The phone's find
    policy includes each only when the birder chose it."""

    note: str | None = None
    caption: str | None = None
    # The original photo, faces blurred and metadata stripped on the phone: a `photos/<sub>/...` key.
    photo_key: str | None = None


@dataclass(frozen=True)
class Share:
    extras: CardExtras
    # The birder turned the city off: the card shows no place in this circle, whatever the find says.
    place_hidden: bool


@dataclass(frozen=True)
class FeedItem:
    owner: str
    owner_name: str | None
    sighting_id: str
    content: FindContent
    posted_at: datetime
    circle_first: bool
    # The card's extras when it was shared by hand to this circle; None for an automatic find.
    card: CardExtras | None = None


@dataclass(frozen=True)
class FeedPage:
    items: list[FeedItem]
    next_cursor: str | None


class BadCursor(ValueError):
    pass


class PhotoUnavailable(Exception):
    """The stack has no art bucket, so no photo can be shared."""


def clean_text(raw: str | None, *, field: str, limit: int) -> str | None:
    """A note or caption: trimmed, none when empty, at most `limit` characters, line breaks and tabs the only control
    characters."""
    if raw is None:
        return None
    text = raw.strip()
    if not text:
        return None
    if len(text) > limit:
        raise ValueError(f"The {field} is longer than {limit} characters")
    if any(character not in "\n\t" and unicodedata.category(character).startswith("C") for character in text):
        raise ValueError(f"The {field} has a control character")
    return text


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


def clean_edition(raw: str | None) -> str | None:
    if raw is not None and not _EDITION.match(raw):
        raise ValueError("The edition isn't a pack id")
    return raw


def clean_art(kind: ArtKind, key: str) -> ArtReference:
    if ".." in key or not _ART_KEY.match(key):
        raise ValueError("The art key isn't a patch's key on the art CDN")
    return ArtReference(kind=kind, key=key)


class FindStore:
    def __init__(
        self, dynamodb: Any, table_name: str, accounts: AccountStore, circles: CircleStore,
        clock: Callable[[], datetime], photos: PhotoStore | None = None, moderation: Moderation | None = None,
    ) -> None:
        self._dynamodb = dynamodb
        self._table = dynamodb.Table(table_name)
        self._accounts = accounts
        self._circles = circles
        self._clock = clock
        self._photos = photos
        self._moderation = moderation

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
        self._write(find, self._shares(owner, sighting_id) if existing is not None else {})
        return find, existing is None

    def share(
        self, owner: str, sighting_id: str, content: FindContent, circle_ids: list[str], extras: CardExtras,
        *, include_place: bool,
    ) -> tuple[Find, bool]:
        """A card shared by hand (issue #66): the find with the extras chosen, in the circles chosen, which must be
        the owner's current circles (NotFound otherwise, so a circle's existence never leaks). It is the only way a
        private birder's sighting reaches a circle. A card already there (an automatic find, or an earlier share) goes
        to the chosen circles it wasn't in yet, keeps the circles it was in, and gets the extras only in the chosen
        ones; sharing again to a circle replaces what it showed there. True when the find is new."""
        self._accounts.get_or_create(owner)
        chosen = list(dict.fromkeys(circle_ids))
        if not chosen or len(chosen) > SHARE_CIRCLES_MAX:
            raise ValueError("circles")
        for circle_id in chosen:
            if not self._circles.is_member(owner, circle_id):
                raise NotFound()
        photos = self._photos
        if extras.photo_key is not None:
            if photos is None:
                raise PhotoUnavailable()
            if not is_photo_key_of(extras.photo_key, owner, sighting_id):
                raise ValueError("photo_key")
            size = photos.size(extras.photo_key)
            if size is None:
                raise ValueError("photo_missing")
            if size > PHOTO_MAX_BYTES:
                photos.delete(extras.photo_key)
                raise ValueError("photo_too_large")
            if self._moderation is not None and self._moderation.photo_flag(extras.photo_key):
                # Withheld from the circle (#71): nothing is written and the photo goes; the card can go without it.
                photos.delete(extras.photo_key)
                raise ValueError("photo_flagged")
        now = self._clock()
        existing = self._get(_find_key(owner, sighting_id))
        shares = self._shares(owner, sighting_id) if existing is not None else {}
        if existing is None:
            all_circles = chosen
            created_at = now
        else:
            previous_circles = list(existing.get("circle_ids", []))
            all_circles = previous_circles + [circle_id for circle_id in chosen if circle_id not in previous_circles]
            created_at = _parse(existing["created_at"])
            previous = _content(existing)
            if not include_place:
                # The city left out applies to the circles chosen; the find keeps the place its other circles show.
                content = replace(content, place=previous.place)
            if (previous.found_at, previous.scientific_name) != (content.found_at, content.scientific_name):
                self._delete_items(_item_keys(owner, sighting_id, previous, previous_circles))
        replaced = [shares[circle_id].extras.photo_key for circle_id in chosen if circle_id in shares]
        new_share = Share(extras=extras, place_hidden=not include_place)
        for circle_id in chosen:
            shares[circle_id] = new_share
        find = Find(
            owner=owner, sighting_id=sighting_id, content=content, circle_ids=all_circles,
            created_at=created_at, updated_at=now,
        )
        # The find (with every circle it may be in), then the shares, then the items: a retry of either the share or
        # a plain put rebuilds the items from what is already written.
        self._write_find(find)
        with self._table.batch_writer() as batch:
            for circle_id in chosen:
                batch.put_item(Item={**_share_key(owner, sighting_id, circle_id), **_share_attributes(new_share, now)})
        self._write_items(find, shares)
        if photos is not None:
            # Kept only once a share names it: a share that fails before here leaves it pending, so it expires.
            if extras.photo_key is not None:
                photos.keep(extras.photo_key)
            still_shown = {share.extras.photo_key for share in shares.values()}
            for key in replaced:
                if key is not None and key not in still_shown:
                    photos.delete(key)
        return find, existing is None

    def delete(self, owner: str, sighting_id: str) -> None:
        """Removes the find with its feed items, species entries and reactions. Deleting one that isn't there (a
        retried delete) changes nothing. The photos its shared cards showed go first, so a delete cut short is
        retried while the shares still name them."""
        existing = self._get(_find_key(owner, sighting_id))
        photos = self._photos
        if photos is not None:
            for share in self._shares(owner, sighting_id).values():
                if share.extras.photo_key is not None:
                    photos.delete(share.extras.photo_key)
        if existing is not None:
            content = _content(existing)
            self._delete_items(_item_keys(owner, sighting_id, content, list(existing.get("circle_ids", []))))
        reactions = self._query_keys(Key("pk").eq(_reactions_pk(owner, sighting_id)))
        # Each reaction's copy under its reactor (issue #64), the find's reaction push time and any waiting push.
        by_reactor = [
            reactor_copy_key(reactor, owner, sighting_id, kind)
            for reactor, _, kind in (str(key["sk"]).removeprefix("REACTION#").rpartition("#") for key in reactions)
            if reactor
        ]
        self._delete_items(
            [*by_reactor, reaction_push_key(owner, sighting_id), reaction_buffer_key(owner, sighting_id)]
        )
        # The reactions last: a delete cut short is finished by the retry, which finds them again.
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

    def as_shown(self, find: Find, circle_id: str) -> dict[str, Any]:
        """The find as the circle sees it, with that circle's shared card: a report's snapshot (#71)."""
        share = self._shares(find.owner, find.sighting_id).get(circle_id)
        content = _shown(find.content, share)
        snapshot: dict[str, Any] = {
            "species_id": content.species_id,
            "scientific_name": content.scientific_name,
            "common_name": content.common_name,
            "method": content.method.value,
            "place": content.place,
            "found_at": _minute(content.found_at),
            "art_key": content.art.key if content.art is not None else None,
        }
        if share is not None:
            snapshot.update(_extras_attributes(share.extras))
        return snapshot

    def feed(
        self, subject: str, circle_id: str, *, limit: int, cursor: str | None, hidden: frozenset[str] = frozenset()
    ) -> FeedPage:
        """A page of the circle's feed, newest find first, for a current member; NotFound for anyone else. The finds
        of `hidden` owners (accounts the reader blocked, #71) are left out, so a page can hold fewer than `limit`
        items while `next_cursor` still leads on."""
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
        last = response.get("LastEvaluatedKey")
        items = [item for item in response["Items"] if item["owner"] not in hidden]
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
                card=_card(item),
            )
            for item in items
        ]
        return FeedPage(items=page, next_cursor=_encode_cursor(last["sk"]) if last else None)

    def _write_find(self, find: Find) -> None:
        self._table.put_item(
            Item={
                **_find_key(find.owner, find.sighting_id),
                **_content_attributes(find.content),
                "circle_ids": find.circle_ids,
                "created_at": _timestamp(find.created_at),
                "updated_at": _timestamp(find.updated_at),
            }
        )

    def _write(self, find: Find, shares: dict[str, Share]) -> None:
        # The find first: a retry after a failure part way reads the circles from it, not from today's memberships.
        self._write_find(find)
        self._write_items(find, shares)

    def _write_items(self, find: Find, shares: dict[str, Share]) -> None:
        """One feed item and species entry per circle the find is in, each the find with that circle's share laid
        over it."""
        owner, sighting_id, content = find.owner, find.sighting_id, find.content
        posted_at = _timestamp(find.created_at)
        with self._table.batch_writer(overwrite_by_pkeys=["pk", "sk"]) as batch:
            for circle_id in find.circle_ids:
                batch.put_item(
                    Item={
                        **_feed_key(circle_id, owner, sighting_id, content),
                        **_content_attributes(_shown(content, shares.get(circle_id))),
                        **_card_attributes(shares.get(circle_id)),
                        "owner": owner,
                        "sighting_id": sighting_id,
                        "posted_at": posted_at,
                    }
                )
                batch.put_item(
                    Item={**_species_key(circle_id, owner, sighting_id, content), "owner": owner, "sighting_id": sighting_id}
                )

    def _shares(self, owner: str, sighting_id: str) -> dict[str, Share]:
        """The find's cards shared by hand, by circle."""
        shares: dict[str, Share] = {}
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": Key("pk").eq(_reactions_pk(owner, sighting_id)) & Key("sk").begins_with("SHARE#"),
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**kwargs)
            for item in response["Items"]:
                shares[str(item["sk"]).removeprefix("SHARE#")] = Share(
                    extras=_extras(item), place_hidden=bool(item.get("place_hidden", False))
                )
            if "LastEvaluatedKey" not in response:
                return shares
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]
    def is_circle_first(self, circle_id: str, owner: str, sighting_id: str, scientific_name: str) -> bool:
        """Whether the find is the circle's earliest surviving item of its species: the push decision at write time
        (issue #63), the same query the feed's mark reads."""
        return self._first_of(circle_id, scientific_name) == (owner, sighting_id)

    def species_between(self, circle_id: str, starts_at: datetime, ends_at: datetime) -> Counter[str]:
        """How many of the circle's feed items found from `starts_at` up to, not including, `ends_at` are of each
        species (scientific name): a goal's progress is the number of keys (issue #65). The feed's sort key starts with
        the found minute, so this is one key range; an item at exactly `ends_at` sorts after the bare minute and is
        left out."""
        species: Counter[str] = Counter()
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": Key("pk").eq(_feed_pk(circle_id))
            & Key("sk").between(_minute(starts_at), _minute(ends_at)),
            "ProjectionExpression": "scientific_name",
            "ConsistentRead": True,
        }
        while True:
            response = self._table.query(**kwargs)
            species.update(str(item["scientific_name"]) for item in response["Items"])
            if "LastEvaluatedKey" not in response:
                return species
            kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]

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
        "new_patch": content.new_patch,
        "threatened": content.threatened,
    }
    if content.place is not None:
        attributes["place"] = content.place
    if content.edition is not None:
        attributes["edition"] = content.edition
    if content.rarity is not None:
        attributes["rarity"] = content.rarity.value
    if content.art is not None:
        attributes["art_kind"] = content.art.kind.value
        attributes["art_key"] = content.art.key
    return attributes


def _shown(content: FindContent, share: Share | None) -> FindContent:
    """The find as a circle sees it: without a place where the card shared there left the city out."""
    if share is not None and share.place_hidden:
        return replace(content, place=None)
    return content


def _extras_attributes(extras: CardExtras) -> dict[str, Any]:
    fields = {"note": extras.note, "caption": extras.caption, "photo_key": extras.photo_key}
    return {name: value for name, value in fields.items() if value is not None}


def _extras(item: dict[str, Any]) -> CardExtras:
    return CardExtras(note=item.get("note"), caption=item.get("caption"), photo_key=item.get("photo_key"))


def _card_attributes(share: Share | None) -> dict[str, Any]:
    """A feed item's extras: marked as a shared card, so one with none chosen still reads as one."""
    return {} if share is None else {"shared_card": True, **_extras_attributes(share.extras)}


def _share_attributes(share: Share, now: datetime) -> dict[str, Any]:
    return {**_extras_attributes(share.extras), "place_hidden": share.place_hidden, "shared_at": _timestamp(now)}


def _card(item: dict[str, Any]) -> CardExtras | None:
    return _extras(item) if item.get("shared_card") else None


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
        # Compatibility: a find stored before #136 has `legendary` and no `new_patch` until it is next put. This read
        # stays until the table's old items are rewritten, which a deploy alone doesn't do.
        new_patch=bool(item.get("new_patch", item.get("legendary", False))),
        rarity=Rarity(item["rarity"]) if "rarity" in item else None,
        threatened=bool(item.get("threatened", False)),
        art=art,
        edition=item.get("edition"),
    )


def _item_keys(owner: str, sighting_id: str, content: FindContent, circle_ids: list[str]) -> list[dict[str, str]]:
    keys: list[dict[str, str]] = []
    for circle_id in circle_ids:
        keys.append(_feed_key(circle_id, owner, sighting_id, content))
        keys.append(_species_key(circle_id, owner, sighting_id, content))
    return keys


def _find_key(owner: str, sighting_id: str) -> dict[str, str]:
    return {"pk": f"ACCOUNT#{owner}", "sk": f"FIND#{sighting_id}"}


def _share_key(owner: str, sighting_id: str, circle_id: str) -> dict[str, str]:
    return {"pk": _reactions_pk(owner, sighting_id), "sk": f"SHARE#{circle_id}"}


def _feed_pk(circle_id: str) -> str:
    return f"CIRCLE#{circle_id}#FEED"


def _species_pk(circle_id: str) -> str:
    return f"CIRCLE#{circle_id}#SPECIES"


def _reactions_pk(owner: str, sighting_id: str) -> str:
    return f"FIND#{owner}#{sighting_id}"


# The reaction items (issue #64, reactions.py) a find's delete takes with it.
REACTIONS_PK = "REACTIONS"


def reactor_copy_key(reactor: str, owner: str, sighting_id: str, kind: str) -> dict[str, str]:
    """A reaction's copy under its reactor, for account deletion (#71)."""
    return {"pk": f"ACCOUNT#{reactor}", "sk": f"REACTION#{owner}#{sighting_id}#{kind}"}


def reaction_push_key(owner: str, sighting_id: str) -> dict[str, str]:
    """When the owner last got a reaction push about the find."""
    return {"pk": f"ACCOUNT#{owner}", "sk": f"REACTIONPUSH#{sighting_id}"}


def reaction_buffer_key(owner: str, sighting_id: str) -> dict[str, str]:
    """The find's reactions waiting for their 10-minute window to close."""
    return {"pk": REACTIONS_PK, "sk": f"{owner}#{sighting_id}"}


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
