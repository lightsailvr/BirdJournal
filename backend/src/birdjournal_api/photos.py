"""Original photos on shared cards (issue #66, spec v2 "Shared card", ADR-0004): the phone blurs the faces and strips
the metadata (`SharedPhoto.prepare`), asks for an upload URL, PUTs the JPEG straight to the art CDN's bucket, and names
the key in the card it shares. The photo is then shown in the circles the card went to, and only there.

Keys are `photos/<sub>/<unguessable>.jpg` in the art CDN's bucket (#68's ArtCdn, no bucket of its own): nothing lists
the bucket, so the URL is the only way to the picture.

The upload is a presigned POST whose policy caps the size (`content-length-range`, at most 5 MB), fixes the content
type and the key, and tags the object `pending=true`. The bucket's lifecycle rule expires
pending photos after a day, so a photo uploaded for a card the birder never sent doesn't stay; sharing the card
removes the tag. The server deletes a shared photo when its card stops showing it: the find deleted, or a later share
to the same circle with another photo or none.
"""

import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Protocol

PHOTOS_PREFIX = "photos/"
UPLOAD_LIFETIME = timedelta(minutes=15)
# A face-blurred photo the phone re-encodes at 2048 px on the long side is well under this.
PHOTO_MAX_BYTES = 5 * 1024 * 1024
CONTENT_TYPE = "image/jpeg"
_PHOTO_KEY = re.compile(r"^photos/[A-Za-z0-9-]+/[0-9a-f-]{36}/[A-Za-z0-9_-]{20,}\.jpg$")
PENDING_TAGGING = "<Tagging><TagSet><Tag><Key>pending</Key><Value>true</Value></Tag></TagSet></Tagging>"


@dataclass(frozen=True)
class PhotoUpload:
    key: str
    url: str
    # The form fields the POST must carry before the file: the key, the content type, the tagging, the policy and its
    # signature.
    fields: dict[str, str]
    expires_at: datetime


class PhotoStore(Protocol):
    def upload(self, key: str, *, now: datetime) -> PhotoUpload: ...

    def size(self, key: str) -> int | None:
        """The object's size in bytes; None when it isn't there."""
        ...

    def keep(self, key: str) -> None:
        """Takes the pending tag off, so the lifecycle rule leaves the photo alone."""
        ...

    def delete(self, key: str) -> None:
        """Deletes the photo; deleting one that isn't there is no error."""
        ...


def new_photo_key(owner: str, sighting_id: str) -> str:
    return f"{PHOTOS_PREFIX}{owner}/{sighting_id}/{secrets.token_urlsafe(24)}.jpg"


def is_photo_key_of(key: str, owner: str, sighting_id: str) -> bool:
    """A key this account's upload URL could have made for this sighting, so one photo never ends up on two finds
    (deleting one would take the other's picture)."""
    return ".." not in key and bool(_PHOTO_KEY.fullmatch(key)) and key.startswith(f"{PHOTOS_PREFIX}{owner}/{sighting_id}/")


class S3PhotoStore:
    """The art CDN's bucket (`ART_BUCKET`), under `photos/`."""

    def __init__(self, s3: Any, bucket: str) -> None:
        self._s3 = s3
        self._bucket = bucket

    def upload(self, key: str, *, now: datetime) -> PhotoUpload:
        post = self._s3.generate_presigned_post(
            Bucket=self._bucket,
            Key=key,
            Fields={"Content-Type": CONTENT_TYPE, "tagging": PENDING_TAGGING},
            Conditions=[
                {"Content-Type": CONTENT_TYPE},
                {"tagging": PENDING_TAGGING},
                ["content-length-range", 1, PHOTO_MAX_BYTES],
            ],
            ExpiresIn=int(UPLOAD_LIFETIME.total_seconds()),
        )
        return PhotoUpload(key=key, url=post["url"], fields=dict(post["fields"]), expires_at=now + UPLOAD_LIFETIME)

    def size(self, key: str) -> int | None:
        try:
            head = self._s3.head_object(Bucket=self._bucket, Key=key)
        except self._s3.exceptions.ClientError as error:
            if error.response.get("Error", {}).get("Code") in ("404", "NoSuchKey", "NotFound"):
                return None
            raise
        size: int = head["ContentLength"]
        return size

    def keep(self, key: str) -> None:
        self._s3.delete_object_tagging(Bucket=self._bucket, Key=key)

    def delete(self, key: str) -> None:
        self._s3.delete_object(Bucket=self._bucket, Key=key)
