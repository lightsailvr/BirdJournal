"""Fetches files into the cache with a checksum check, and photos from the Open Data bucket."""

from __future__ import annotations

import hashlib
import logging
from pathlib import Path

import requests

from packbuilder.candidates import PhotoCandidate

log = logging.getLogger(__name__)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(url: str, target: Path, sha256: str | None = None, timeout: int = 120) -> Path:
    """Downloads `url` to `target` unless it is already there (and matches `sha256` when given)."""
    if target.exists() and (sha256 is None or sha256_of(target) == sha256):
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".download")
    with requests.get(url, stream=True, timeout=timeout) as response:
        response.raise_for_status()
        with partial.open("wb") as handle:
            for chunk in response.iter_content(1 << 20):
                handle.write(chunk)
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
