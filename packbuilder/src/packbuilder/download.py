"""Fetches files into the cache with a checksum check, and photos from the Open Data bucket."""

from __future__ import annotations

import hashlib
import logging
import os
import threading
import time
from pathlib import Path

import requests

from packbuilder.http import session

from packbuilder.candidates import PhotoCandidate

log = logging.getLogger(__name__)

BODY_ATTEMPTS = 4
"""How often a download whose body breaks off is asked for, in all."""
BODY_PAUSE = 2.0
"""Seconds before the second attempt; each later one waits that much longer."""


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url: str, target: Path, sha256: str | None = None, timeout: int = 120, headers: dict[str, str] | None = None) -> Path:
    """Downloads `url` to `target` unless it is already there (and matches `sha256` when given)."""
    if target.exists() and (sha256 is None or sha256_of(target) == sha256):
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    # One partial file per process and thread: builds running side by side share the cache and may fetch the same photo.
    partial = target.with_suffix(f"{target.suffix}.{os.getpid()}-{threading.get_ident()}.download")
    for attempt in range(1, BODY_ATTEMPTS + 1):
        try:
            with session().get(url, stream=True, timeout=timeout, headers=headers) as response:
                response.raise_for_status()
                with partial.open("wb") as handle:
                    for chunk in response.iter_content(1 << 20):
                        handle.write(chunk)
            break
        except (requests.ConnectionError, requests.Timeout) as error:
            # The session retries a request that fails to start; a body that stalls or breaks off halfway is ours to ask
            # for again (#58: one read timeout on the Open Data bucket ended a pack build at its hundredth species).
            partial.unlink(missing_ok=True)
            if attempt == BODY_ATTEMPTS:
                raise
            log.warning("download of %s broke off (%s); trying again", url, type(error).__name__)
            time.sleep(BODY_PAUSE * attempt)
    if sha256 is not None:
        actual = sha256_of(partial)
        if actual != sha256:
            partial.unlink()
            raise ValueError(f"checksum mismatch for {url}: expected {sha256}, got {actual}")
    partial.replace(target)
    return target


def fetch_photo(candidate: PhotoCandidate, cache_dir: Path, size: str = "original") -> Path | None:
    """The photo at an Open Data size (`large` is 1024 px, `original` up to 2048 px) in the cache, or None when the
    bucket no longer has it."""
    target = Path(cache_dir) / "photos" / size / f"{candidate.photo_id}.{candidate.extension}"
    try:
        return fetch(candidate.photo_url(size), target)
    except requests.HTTPError as error:
        log.warning("photo %s unavailable: %s", candidate.photo_id, error)
        return None
