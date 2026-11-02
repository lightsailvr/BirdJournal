"""The find routes (issue #62): put and delete a find, keyed by the sighting's id, and a circle's feed, paged. A card
shared by hand (issue #66): an upload URL for its original photo, and the share."""

from datetime import UTC, datetime
from typing import Annotated, Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict, ValidationInfo, field_serializer, field_validator, model_validator

from birdjournal_api.auth import Subject
from birdjournal_api.circles import NotFound
from birdjournal_api.finds import (
    CAPTION_MAX,
    FEED_PAGE_DEFAULT,
    FEED_PAGE_MAX,
    ArtKind,
    ArtReference,
    BadCursor,
    CardExtras,
    FeedItem,
    Find,
    FindContent,
    FindStore,
    Method,
    NOTE_MAX,
    PhotoUnavailable,
    Rarity,
    clean_art,
    clean_found_at,
    clean_name,
    clean_place,
    clean_text,
)
from birdjournal_api.photos import PhotoStore, new_photo_key


def _utc(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


class ArtBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: ArtKind
    # The object's key on the art CDN: packs/<pack id>/<file>.jpg for pack art.
    key: str


class FindBody(BaseModel):
    """The find policy's payload. Anything else, a coordinate above all, is refused (`extra="forbid"`)."""

    model_config = ConfigDict(extra="forbid")

    species_id: str
    scientific_name: str
    common_name: str
    method: Method
    place: str | None = None
    found_at: datetime
    legendary: bool = False
    rarity: Rarity | None = None
    threatened: bool = False
    art: ArtBody | None = None

    @field_validator("species_id", "scientific_name", "common_name")
    @classmethod
    def _names(cls, value: str, info: ValidationInfo) -> str:
        return clean_name(value, field=info.field_name or "name")

    @field_validator("found_at")
    @classmethod
    def _minute(cls, value: datetime) -> datetime:
        return clean_found_at(value)

    @model_validator(mode="after")
    def _place(self) -> "FindBody":
        self.place = clean_place(self.place, threatened=self.threatened)
        return self

    def content(self) -> FindContent:
        return FindContent(
            species_id=self.species_id,
            scientific_name=self.scientific_name,
            common_name=self.common_name,
            method=self.method,
            place=self.place,
            found_at=self.found_at,
            legendary=self.legendary,
            rarity=self.rarity,
            threatened=self.threatened,
            art=clean_art(self.art.kind, self.art.key) if self.art is not None else None,
        )


class ArtResponse(BaseModel):
    kind: ArtKind
    key: str
    # On the art CDN; null when the stack has none yet (the phone falls back to the reference photo or a tile).
    url: str | None

    @classmethod
    def of(cls, art: ArtReference | None, base_url: str | None) -> "ArtResponse | None":
        if art is None:
            return None
        return cls(kind=art.kind, key=art.key, url=f"{base_url}/{art.key}" if base_url else None)


class FindFields(BaseModel):
    sighting_id: str
    species_id: str
    scientific_name: str
    common_name: str
    method: Method
    place: str | None
    found_at: datetime
    legendary: bool
    rarity: Rarity | None
    art: ArtResponse | None

    @field_serializer("found_at")
    def _found(self, value: datetime) -> str:
        return _utc(value)

    @staticmethod
    def fields(sighting_id: str, content: FindContent, base_url: str | None) -> dict[str, Any]:
        return {
            "sighting_id": sighting_id,
            "species_id": content.species_id,
            "scientific_name": content.scientific_name,
            "common_name": content.common_name,
            "method": content.method,
            "place": content.place,
            "found_at": content.found_at,
            "legendary": content.legendary,
            "rarity": content.rarity,
            "art": ArtResponse.of(content.art, base_url),
        }


class FindResponse(FindFields):
    # The circles the find went to when it was first written.
    circle_ids: list[str]

    @classmethod
    def of(cls, find: Find, base_url: str | None) -> "FindResponse":
        return cls(**FindFields.fields(find.sighting_id, find.content, base_url), circle_ids=find.circle_ids)


class PhotoBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # The key the upload URL gave: photos/<sub>/<unguessable>.jpg.
    key: str


class CardBody(BaseModel):
    """A card shared by hand (issue #66): the find policy's payload for it, the circles chosen and the extras chosen.
    `include_place` false means the city was turned off: the card shows no place in those circles."""

    model_config = ConfigDict(extra="forbid")

    find: FindBody
    circle_ids: list[str]
    include_place: bool = True
    note: str | None = None
    caption: str | None = None
    photo: PhotoBody | None = None

    @field_validator("note")
    @classmethod
    def _note(cls, value: str | None) -> str | None:
        return clean_text(value, field="note", limit=NOTE_MAX)

    @field_validator("caption")
    @classmethod
    def _caption(cls, value: str | None) -> str | None:
        return clean_text(value, field="caption", limit=CAPTION_MAX)

    @model_validator(mode="after")
    def _no_place(self) -> "CardBody":
        if not self.include_place:
            self.find.place = None
        return self

    def extras(self) -> CardExtras:
        return CardExtras(note=self.note, caption=self.caption, photo_key=self.photo.key if self.photo else None)


class PhotoUploadResponse(BaseModel):
    key: str
    upload_url: str
    # Send these with the PUT: the URL's signature covers them.
    headers: dict[str, str]
    expires_at: datetime

    @field_serializer("expires_at")
    def _expires(self, value: datetime) -> str:
        return _utc(value)


class PhotoResponse(BaseModel):
    key: str
    url: str | None


class CardResponse(BaseModel):
    """What a card shared by hand to this circle adds to the find."""

    note: str | None
    caption: str | None
    photo: PhotoResponse | None

    @classmethod
    def of(cls, card: CardExtras | None, base_url: str | None) -> "CardResponse | None":
        if card is None:
            return None
        photo = (
            PhotoResponse(key=card.photo_key, url=f"{base_url}/{card.photo_key}" if base_url else None)
            if card.photo_key
            else None
        )
        return cls(note=card.note, caption=card.caption, photo=photo)


class Owner(BaseModel):
    id: str
    display_name: str | None


class FeedItemResponse(FindFields):
    owner: Owner
    # The earliest surviving find of this species in the circle, apart from anyone's Legendary.
    circle_first: bool
    is_mine: bool
    # The note, caption and photo of a card shared by hand to this circle; null for an automatic find.
    card: CardResponse | None

    @classmethod
    def of(cls, item: FeedItem, subject: str, base_url: str | None) -> "FeedItemResponse":
        return cls(
            **FindFields.fields(item.sighting_id, item.content, base_url),
            owner=Owner(id=item.owner, display_name=item.owner_name),
            circle_first=item.circle_first,
            is_mine=item.owner == subject,
            card=CardResponse.of(item.card, base_url),
        )


class FeedResponse(BaseModel):
    items: list[FeedItemResponse]
    # Pass back as `cursor` for the next page; null on the last.
    next_cursor: str | None


def _finds(request: Request) -> FindStore:
    store: FindStore = request.app.state.finds
    return store


def _art_base_url(request: Request) -> str | None:
    base: str | None = request.app.state.art_cdn_base_url
    return base


def _photos(request: Request) -> PhotoStore | None:
    photos: PhotoStore | None = request.app.state.photos
    return photos


Finds = Annotated[FindStore, Depends(_finds)]
Photos = Annotated[PhotoStore | None, Depends(_photos)]
ArtBaseUrl = Annotated[str | None, Depends(_art_base_url)]


def _sighting_id(raw: str) -> str:
    """The phone's sighting identifier: a UUID, stored in its canonical lower-case form."""
    try:
        return str(UUID(raw))
    except ValueError:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "bad_sighting_id") from None


router = APIRouter(prefix="/v1")


@router.put("/finds/{sighting_id}")
def put_find(
    subject: Subject, sighting_id: str, body: FindBody, finds: Finds, base: ArtBaseUrl, response: Response
) -> FindResponse:
    try:
        content = body.content()
    except ValueError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from None
    find, created = finds.put(subject, _sighting_id(sighting_id), content)
    response.status_code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return FindResponse.of(find, base)


@router.post("/finds/{sighting_id}/photo", status_code=status.HTTP_201_CREATED)
def create_photo_upload(subject: Subject, sighting_id: str, photos: Photos, request: Request) -> PhotoUploadResponse:
    """A presigned PUT for a shared card's original photo. The photo waits, tagged pending, until a share names it,
    and expires after a day if none does."""
    _sighting_id(sighting_id)
    if photos is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "photos_unavailable")
    upload = photos.upload(new_photo_key(subject), now=request.app.state.clock())
    return PhotoUploadResponse(key=upload.key, upload_url=upload.url, headers=upload.headers, expires_at=upload.expires_at)


@router.put("/finds/{sighting_id}/card")
def share_card(
    subject: Subject, sighting_id: str, body: CardBody, finds: Finds, base: ArtBaseUrl, response: Response
) -> FindResponse:
    try:
        find, created = finds.share(
            subject, _sighting_id(sighting_id), body.find.content(), body.circle_ids, body.extras(),
            include_place=body.include_place,
        )
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    except PhotoUnavailable:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "photos_unavailable") from None
    except ValueError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from None
    response.status_code = status.HTTP_201_CREATED if created else status.HTTP_200_OK
    return FindResponse.of(find, base)


@router.delete("/finds/{sighting_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_find(subject: Subject, sighting_id: str, finds: Finds) -> Response:
    finds.delete(subject, _sighting_id(sighting_id))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/circles/{circle_id}/feed")
def read_feed(
    subject: Subject,
    circle_id: str,
    finds: Finds,
    base: ArtBaseUrl,
    limit: Annotated[int, Query(ge=1, le=FEED_PAGE_MAX)] = FEED_PAGE_DEFAULT,
    cursor: str | None = None,
) -> FeedResponse:
    try:
        page = finds.feed(subject, circle_id, limit=limit, cursor=cursor)
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    except BadCursor:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "bad_cursor") from None
    return FeedResponse(
        items=[FeedItemResponse.of(item, subject, base) for item in page.items], next_cursor=page.next_cursor
    )
