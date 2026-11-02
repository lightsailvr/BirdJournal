"""The tests' photo bucket (issue #66)."""

from datetime import datetime

from birdjournal_api.photos import CONTENT_TYPE, PENDING_TAG, UPLOAD_LIFETIME, PhotoUpload


class MemoryPhotoStore:
    """The tests' bucket: what was uploaded, which photos are still pending, and what was deleted."""

    def __init__(self) -> None:
        self.objects: dict[str, int] = {}
        self.pending: set[str] = set()
        self.deleted: list[str] = []

    def upload(self, key: str, *, now: datetime) -> PhotoUpload:
        return PhotoUpload(
            key=key, url=f"https://bucket.test/{key}?signed", headers={"Content-Type": CONTENT_TYPE, "x-amz-tagging": PENDING_TAG},
            expires_at=now + UPLOAD_LIFETIME,
        )

    def arrive(self, key: str, size: int = 200_000) -> None:
        """The phone's PUT landing."""
        self.objects[key] = size
        self.pending.add(key)

    def size(self, key: str) -> int | None:
        return self.objects.get(key)

    def keep(self, key: str) -> None:
        self.pending.discard(key)

    def delete(self, key: str) -> None:
        self.objects.pop(key, None)
        self.pending.discard(key)
        self.deleted.append(key)
