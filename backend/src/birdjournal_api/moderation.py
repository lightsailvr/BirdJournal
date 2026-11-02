"""Moderation of pictures before anyone else sees them (issue #71, spec v2 "Safety"): Amazon Rekognition's
DetectModerationLabels on an art job's input (the face-blurred glasses or library photo, at submit), on its output (the
painting, when the worker reports it ready) and on a card's original photo (when it is shared to circles).

A flagged input or painting fails its job (`flagged`, with the upload or the painting deleted); a flagged photo is
withheld from the circle: the share is refused (422 `photo_flagged`) and the photo deleted, so the birder can send the
card again without it.

**Behind a switch** (`MODERATION`, `moderation` in `infra/cdk.json`): off in the friends phase, when every circle is a
handful of friends and the worker's own content filter guards the paintings (#68), and on for the public launch. Off,
Rekognition is never called.

Rekognition reads the object straight from S3 (same region), with the API's own permission to read it.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Protocol

log = logging.getLogger(__name__)

# Rekognition's default is 50; 60 leaves borderline beach photos alone and still catches what matters.
MIN_CONFIDENCE = 60.0
# Rekognition can't read it at all: a picture nobody can check is not shown either.
UNREADABLE = "Unreadable image"
# The top-level categories that withhold a picture: Rekognition's current taxonomy (version 7) and the names the
# earlier one used. Swimwear, alcohol, tobacco and gambling are left alone: a birder's photo may show any of them.
FLAGGED_CATEGORIES = frozenset(
    {
        "Explicit",
        "Explicit Nudity",
        "Non-Explicit Nudity of Intimate parts and Kissing",
        "Suggestive",
        "Violence",
        "Visually Disturbing",
        "Rude Gestures",
        "Hate Symbols",
        UNREADABLE,
    }
)


class ImageModerator(Protocol):
    """The labels Rekognition gives an S3 object: every label's name and its parent's ("" at the top)."""

    def labels(self, bucket: str, key: str) -> list[tuple[str, str]]: ...


@dataclass
class Moderation:
    """The switch, the moderator and the two buckets an image can be in."""

    enabled: bool
    moderator: ImageModerator | None = None
    upload_bucket: str | None = None
    art_bucket: str | None = None
    checked: list[str] = field(default_factory=list)

    def upload_flag(self, key: str) -> str | None:
        """Why an art job's input is withheld, or None (always None while the switch is off)."""
        return self._flag(self.upload_bucket, key)

    def art_flag(self, key: str) -> str | None:
        """Why a painting or a shared photo (both in the art bucket) is withheld, or None."""
        return self._flag(self.art_bucket, key)

    def _flag(self, bucket: str | None, key: str) -> str | None:
        if not self.enabled:
            return None
        if self.moderator is None or bucket is None:
            raise RuntimeError("Moderation is on but has no moderator or bucket")
        self.checked.append(key)
        for name, parent in self.moderator.labels(bucket, key):
            category = parent or name
            if category in FLAGGED_CATEGORIES or name in FLAGGED_CATEGORIES:
                log.info("moderation flagged %s: %s / %s", key, parent, name)
                return category
        return None


class RekognitionModerator:
    def __init__(self, rekognition: Any) -> None:
        self._rekognition = rekognition

    def labels(self, bucket: str, key: str) -> list[tuple[str, str]]:
        try:
            response = self._rekognition.detect_moderation_labels(
                Image={"S3Object": {"Bucket": bucket, "Name": key}}, MinConfidence=MIN_CONFIDENCE
            )
        except self._rekognition.exceptions.InvalidImageFormatException:
            return [(UNREADABLE, "")]
        except self._rekognition.exceptions.ImageTooLargeException:
            return [(UNREADABLE, "")]
        return [(label["Name"], label.get("ParentName", "")) for label in response.get("ModerationLabels", [])]
