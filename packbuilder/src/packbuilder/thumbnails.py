"""Thumbnails for the art CDN (issues #62 and #136): small images of a built pack's paintings, so a friend's phone can
show any find's patch or pack art without that pack. `scripts/publish-pack-thumbnails.sh` uploads them to the art bucket
under the keys the phone's find policy sends (`FindPolicy.patchArtKey` and `packArtKey` in the app):

- a patch at `packs/<pack id>/patch/<species id>.png`, a PNG because it's cut out on transparency;
- pack art at `packs/<pack id>/<species id>.jpg`, a JPEG, while packs without patches remain.

A thumbnail is at most 320 px on its long side (the feed shows art at about 100 points, three pixels a point), with no
metadata. The key carries no version: a repainted species replaces its thumbnail, and old finds show the new painting
once CloudFront's day of caching passes.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path, PurePosixPath

from PIL import Image

THUMBNAIL_LONG_SIDE = 320
THUMBNAIL_QUALITY = 82
PREFIX = "packs/"
PATCH_FOLDER = "patch"


def thumbnail_key(pack_id: str, art_file: str) -> str:
    """The art CDN key of a `pack_art.file` (`art/<species id>.avif`)."""
    return f"{PREFIX}{pack_id}/{PurePosixPath(art_file).stem}.jpg"


def patch_thumbnail_key(pack_id: str, patch_file: str) -> str:
    """The art CDN key of a `patch.file` (`patch/<species id>.avif`)."""
    return f"{PREFIX}{pack_id}/{PATCH_FOLDER}/{PurePosixPath(patch_file).stem}.png"


def _files(database: sqlite3.Connection, table: str) -> list[str]:
    if not database.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)).fetchone():
        return []
    return [row[0] for row in database.execute(f"SELECT file FROM {table} ORDER BY species_id")]


def write_thumbnails(pack_dir: Path, out_dir: Path) -> dict[str, Path]:
    """Writes one thumbnail per `patch` row under `out_dir/patch/<species id>.png` and per `pack_art` row under
    `out_dir/<species id>.jpg`; returns them by art CDN key. A pack with neither (schema 3, or built with --no-art)
    writes none."""
    database = sqlite3.connect(f"file:{pack_dir / 'pack.sqlite'}?mode=ro", uri=True)
    try:
        (pack_id,) = database.execute("SELECT id FROM pack").fetchone()
        files = _files(database, "pack_art")
        patches = _files(database, "patch")
    finally:
        database.close()
    out_dir.mkdir(parents=True, exist_ok=True)
    written: dict[str, Path] = {}
    for file in files:
        target = out_dir / f"{PurePosixPath(file).stem}.jpg"
        with Image.open(pack_dir / file) as painting:
            image = painting.convert("RGB")
            image.thumbnail((THUMBNAIL_LONG_SIDE, THUMBNAIL_LONG_SIDE), Image.Resampling.LANCZOS)
            # A fresh image carries no EXIF, ICC or XMP from the source.
            image.save(target, "JPEG", quality=THUMBNAIL_QUALITY, optimize=True, progressive=True)
        written[thumbnail_key(pack_id, file)] = target
    for file in patches:
        target = out_dir / PATCH_FOLDER / f"{PurePosixPath(file).stem}.png"
        target.parent.mkdir(exist_ok=True)
        with Image.open(pack_dir / file) as painting:
            image = painting.convert("RGBA")
            image.thumbnail((THUMBNAIL_LONG_SIDE, THUMBNAIL_LONG_SIDE), Image.Resampling.LANCZOS)
            image.save(target, "PNG", optimize=True)
        written[patch_thumbnail_key(pack_id, file)] = target
    return written
