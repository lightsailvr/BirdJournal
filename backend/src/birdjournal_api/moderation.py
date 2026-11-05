"""Moderation of pictures before anyone else sees them (issue #71, spec v2 "Safety"): Amazon Rekognition's
DetectModerationLabels on a card's original photo, when it is shared to circles.

A flagged photo is withheld from the circle: the share is refused (422 `photo_flagged`) and the photo deleted, so the
birder can send the card again without it.

**Behind a switch** (`MODERATION`, `moderation` in `infra/cdk.json`): off in the friends phase, when every circle is a
handful of friends, and on for the public launch. Off, Rekognition is never called.

Rekognition reads the object straight from S3 (same region), with the API's own permission to read it.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
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
    """The switch, the moderator and the bucket a shared photo is in."""

    enabled: bool
    moderator: ImageModerator | None = None
    art_bucket: str | None = None

    def photo_flag(self, key: str) -> str | None:
        """Why a shared photo is withheld, or None (always None while the switch is off)."""
        if not self.enabled:
            return None
        if self.moderator is None or self.art_bucket is None:
            raise RuntimeError("Moderation is on but has no moderator or bucket")
        for name, parent in self.moderator.labels(self.art_bucket, key):
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
