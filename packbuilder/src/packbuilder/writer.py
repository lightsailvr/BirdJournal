"""Writes the pack directory: pack.sqlite, lens/ and phone/ JPEGs, LICENSE, report.json, and optionally a zip of it
(the download format for other regions, DECISIONS.md "Species pack")."""

from __future__ import annotations

import json
import shutil
import sqlite3
import zipfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from packbuilder.candidates import attribution_name
from packbuilder.crops import JPEG_QUALITY, render_lens, render_phone
from packbuilder.definition import PackDefinition, SpeciesEntry
from packbuilder.licenses import credit_line, short_credit
from packbuilder.selection import ScoredPhoto

SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE pack (
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    region TEXT NOT NULL,
    version INTEGER NOT NULL,
    schema_version INTEGER NOT NULL,
    built_at TEXT NOT NULL,
    license_text TEXT NOT NULL
);
CREATE TABLE species (
    id TEXT PRIMARY KEY,
    scientific_name TEXT NOT NULL UNIQUE,
    common_name TEXT NOT NULL,
    birdnet_label TEXT NOT NULL,
    inat_taxon_id INTEGER,
    wikipedia_url TEXT,
    summary TEXT,
    field_marks TEXT,
    size TEXT,
    habitat TEXT,
    sort_order INTEGER NOT NULL
);
CREATE TABLE photo (
    id TEXT PRIMARY KEY,
    species_id TEXT NOT NULL REFERENCES species(id),
    rank INTEGER NOT NULL,
    file_lens TEXT NOT NULL,
    file_phone TEXT NOT NULL,
    observer TEXT NOT NULL,
    observer_login TEXT,
    license TEXT NOT NULL,
    credit_line TEXT NOT NULL,
    short_credit TEXT NOT NULL,
    source_url TEXT NOT NULL,
    photo_url TEXT NOT NULL,
    inat_photo_id INTEGER NOT NULL,
    tags TEXT,
    score REAL NOT NULL
);
CREATE INDEX photo_species ON photo(species_id, rank);
"""


@dataclass
class SpeciesResult:
    entry: SpeciesEntry
    photos: list[tuple[ScoredPhoto, Path]]
    """Chosen photos, best first, each with the path of its downloaded original."""
    gap: bool
    candidates: int = 0
    rejected: dict | None = None
    detected: int = 0


@dataclass
class WrittenPack:
    directory: Path
    database: Path
    archive: Path | None


def write_pack(definition: PackDefinition, results: list[SpeciesResult], out_dir: Path, built_at: str, archive_path: Path | None = None) -> WrittenPack:
    out_dir = Path(out_dir)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    (out_dir / "lens").mkdir(parents=True)
    (out_dir / "phone").mkdir()

    photo_rows = []
    for result in results:
        for rank, (photo, source) in enumerate(result.photos):
            candidate = photo.candidate
            file_lens = f"lens/{candidate.photo_id}.jpg"
            file_phone = f"phone/{candidate.photo_id}.jpg"
            with Image.open(source) as image:
                image = _upright(image)
                render_lens(image, photo.box).save(out_dir / file_lens, "JPEG", quality=JPEG_QUALITY, optimize=True)
                render_phone(image, photo.box).save(out_dir / file_phone, "JPEG", quality=JPEG_QUALITY, optimize=True)
            observer = attribution_name(candidate)
            license = candidate.normalized_license
            assert observer and license and candidate.source_url, "filter_candidates guarantees attribution"
            photo_rows.append(
                (
                    f"inat-{candidate.photo_id}",
                    result.entry.id,
                    rank,
                    file_lens,
                    file_phone,
                    observer,
                    candidate.observer_login,
                    license,
                    credit_line(observer, license),
                    short_credit(observer, license),
                    candidate.source_url,
                    candidate.photo_url("original"),
                    candidate.photo_id,
                    None,
                    photo.score.total,
                )
            )

    license_text = _license_text(definition, results, built_at)
    (out_dir / "LICENSE").write_text(license_text)

    database = out_dir / "pack.sqlite"
    db = sqlite3.connect(database)
    db.executescript(SCHEMA)
    db.execute(
        "INSERT INTO pack VALUES (?, ?, ?, ?, ?, ?, ?)",
        (definition.id, definition.name, definition.region, definition.version, SCHEMA_VERSION, built_at, license_text),
    )
    db.executemany(
        "INSERT INTO species (id, scientific_name, common_name, birdnet_label, inat_taxon_id, wikipedia_url, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            (r.entry.id, r.entry.scientific_name, r.entry.common_name, r.entry.birdnet_label, r.entry.inat_taxon_id, r.entry.wikipedia_url, order)
            for order, r in enumerate(results)
        ],
    )
    db.executemany("INSERT INTO photo VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", photo_rows)
    db.commit()
    db.execute("VACUUM")
    db.close()

    (out_dir / "report.json").write_text(json.dumps(_report(definition, results, built_at), indent=2) + "\n")

    archive = None
    if archive_path is not None:
        archive = Path(archive_path)
        archive.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zipped:
            for path in sorted(out_dir.rglob("*")):
                if path.is_file():
                    zipped.write(path, path.relative_to(out_dir).as_posix())
    return WrittenPack(directory=out_dir, database=database, archive=archive)


def _upright(image: Image.Image) -> Image.Image:
    from PIL import ImageOps

    return ImageOps.exif_transpose(image) or image


def _license_text(definition: PackDefinition, results: list[SpeciesResult], built_at: str) -> str:
    lines = [
        f"{definition.name} species pack for BirdJournal (pack id {definition.id}, version {definition.version}, built {built_at})",
        "",
        "Photos come from iNaturalist Open Data (https://github.com/inaturalist/inaturalist-open-data). Each photo is",
        "redistributed under the Creative Commons license its photographer chose: CC0, CC BY 4.0 or CC BY-NC 4.0",
        "(https://creativecommons.org/licenses/). Photographers retain copyright unless the photo is CC0. The crops",
        "in this pack are derived from the originals linked below.",
        "",
        "Species names and the BirdNET labels are from the BirdNET+ label file (CC BY-SA 4.0, https://birdnet.cornell.edu).",
        "",
        "Photo credits",
        "=============",
    ]
    for result in results:
        lines.append("")
        lines.append(f"{result.entry.common_name} ({result.entry.scientific_name})")
        for photo, _ in result.photos:
            candidate = photo.candidate
            observer = attribution_name(candidate)
            license = candidate.normalized_license
            lines.append(f"  {credit_line(observer, license)} — {candidate.source_url} — photo {candidate.photo_url('original')}")
    return "\n".join(lines) + "\n"


def _report(definition: PackDefinition, results: list[SpeciesResult], built_at: str) -> dict:
    return {
        "pack": definition.id,
        "version": definition.version,
        "built_at": built_at,
        "species": {
            r.entry.id: {
                "common_name": r.entry.common_name,
                "candidates": r.candidates,
                "rejected": {str(k.value if hasattr(k, "value") else k): v for k, v in (r.rejected or {}).items()},
                "detected": r.detected,
                "photos": len(r.photos),
                "gap": r.gap,
                "chosen": [p.candidate.photo_id for p, _ in r.photos],
            }
            for r in results
        },
    }
