"""Pack-art thumbnails for the art CDN (issue #62): small JPEGs of a built pack's paintings, so a friend's phone can
show any find's pack art without that pack. `scripts/publish-pack-thumbnails.sh` uploads them to the art bucket under
`packs/<pack id>/<species id>.jpg`, the key the phone's find policy sends (`FindPolicy.packArtKey` in the app).

A thumbnail is at most 320 px on its long side (the feed shows art at about 100 points, three pixels a point), JPEG
for every phone and browser, with no metadata. The key carries no version: a repainted species replaces its thumbnail,
and old finds show the new painting once CloudFront's day of caching passes.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path, PurePosixPath

from PIL import Image

THUMBNAIL_LONG_SIDE = 320
THUMBNAIL_QUALITY = 82
PREFIX = "packs/"


def thumbnail_key(pack_id: str, art_file: str) -> str:
    """The art CDN key of a `pack_art.file` (`art/<species id>.avif`)."""
    return f"{PREFIX}{pack_id}/{PurePosixPath(art_file).stem}.jpg"


def write_thumbnails(pack_dir: Path, out_dir: Path) -> dict[str, Path]:
    """Writes one thumbnail per `pack_art` row under `out_dir/<species id>.jpg`; returns them by art CDN key. A pack
    without pack art (schema 3, or built with --no-art) writes none."""
    database = sqlite3.connect(f"file:{pack_dir / 'pack.sqlite'}?mode=ro", uri=True)
    try:
        (pack_id,) = database.execute("SELECT id FROM pack").fetchone()
        has_art = database.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'pack_art'").fetchone()
        files = [row[0] for row in database.execute("SELECT file FROM pack_art ORDER BY species_id")] if has_art else []
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
    return written
