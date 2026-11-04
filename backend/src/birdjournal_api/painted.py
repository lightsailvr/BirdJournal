"""What is left of painted art. Scene art and photo art (issues #68 to #70) are retired (issue #137): nothing is painted
for a birder any more, and the API that did it is gone. But the paintings already made stay on the art CDN at
`art/<sub>/<unguessable>.jpg`, in a Retain bucket, and they are still the birder's (ADR-0004). So two things stay:

- a find already showing one goes on showing it, until the find moves on or is deleted, and then the painting is deleted
  (`FindStore`);
- account deletion deletes every painting its `ACCOUNT#<sub>` / `ARTJOB#<id>` items name (`AccountDeleter`).

Those are the only reasons the API still touches `art/`. Once no find names a painting and no job item is left, this file
and `ArtKind.PAINTED` can go.
"""

from typing import Any, Protocol


class ArtStorage(Protocol):
    """The art CDN's bucket, as far as the API still writes to it."""

    def delete_art(self, key: str) -> None: ...


class S3ArtStorage:
    def __init__(self, s3: Any, *, art_bucket: str) -> None:
        self._s3 = s3
        self._art = art_bucket

    def delete_art(self, key: str) -> None:
        self._s3.delete_object(Bucket=self._art, Key=key)
