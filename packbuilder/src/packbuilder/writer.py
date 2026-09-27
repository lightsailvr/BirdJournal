"""Writes the pack directory: pack.sqlite, lens/ and phone/ JPEGs, LICENSE (every photo and text credit), report.json
(counts, chosen ids, and the photo and description gaps), and optionally a zip of it (the download format for other
regions, DECISIONS.md "Species pack")."""

from __future__ import annotations

import json
import shutil
import sqlite3
import zipfile
from contextlib import closing
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from packbuilder.candidates import PhotoCandidate, attribution_name
from packbuilder.crops import JPEG_QUALITY, render_lens, render_phone, upright
from packbuilder.definition import PackDefinition, SpeciesEntry
from packbuilder.descriptions import Description
from packbuilder.licenses import credit_line, short_credit
from packbuilder.selection import ScoredPhoto

SCHEMA_VERSION = 2

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
    description_source TEXT,
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
CREATE TABLE lookalike (
    species_id TEXT NOT NULL REFERENCES species(id),
    other_species_id TEXT NOT NULL REFERENCES species(id),
    one_line_difference TEXT NOT NULL
);
CREATE INDEX photo_species ON photo(species_id, rank);
"""


@dataclass(frozen=True)
class ChosenPhoto:
    scored: ScoredPhoto
    original: Path
    """The downloaded original, which the lens and phone JPEGs are cut from."""

    @property
    def candidate(self) -> PhotoCandidate:
        return self.scored.candidate


@dataclass(frozen=True)
class Credit:
    """The attribution a photo record carries; every field is required, so a candidate that lacks one is an error."""

    observer: str
    license: str
    source_url: str

    @classmethod
    def of(cls, candidate: PhotoCandidate) -> "Credit":
        observer = attribution_name(candidate)
        license = candidate.normalized_license
        if observer is None or license is None or candidate.source_url is None:
            raise ValueError(f"photo {candidate.photo_id} lacks attribution; filter_candidates should have rejected it")
        return cls(observer=observer, license=license, source_url=candidate.source_url)

    @property
    def line(self) -> str:
        return credit_line(self.observer, self.license)

    @property
    def short(self) -> str:
        return short_credit(self.observer, self.license)


@dataclass
class SpeciesResult:
    entry: SpeciesEntry
    photos: list[ChosenPhoto]
    """Best first."""
    gap: bool
    candidates: int = 0
    rejected: dict[str, int] | None = None
    """Rejected candidates by `Rejection` value."""
    detected: int = 0
    description: Description | None = None


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
        for rank, chosen in enumerate(result.photos):
            candidate = chosen.candidate
            credit = Credit.of(candidate)
            file_lens = f"lens/{candidate.photo_id}.jpg"
            file_phone = f"phone/{candidate.photo_id}.jpg"
            with Image.open(chosen.original) as opened:
                image = upright(opened)
                render_lens(image, chosen.scored.box).save(out_dir / file_lens, "JPEG", quality=JPEG_QUALITY, optimize=True)
                render_phone(image, chosen.scored.box).save(out_dir / file_phone, "JPEG", quality=JPEG_QUALITY, optimize=True)
            photo_rows.append(
                (
                    f"inat-{candidate.photo_id}",
                    result.entry.id,
                    rank,
                    file_lens,
                    file_phone,
                    credit.observer,
                    candidate.observer_login,
                    credit.license,
                    credit.line,
                    credit.short,
                    credit.source_url,
                    candidate.photo_url("original"),
                    candidate.photo_id,
                    None,
                    chosen.scored.score.total,
                )
            )

    license_text = _license_text(definition, results, built_at)
    (out_dir / "LICENSE").write_text(license_text)

    database = out_dir / "pack.sqlite"
    with closing(sqlite3.connect(database)) as db:
        db.executescript(SCHEMA)
        db.execute(
            "INSERT INTO pack VALUES (?, ?, ?, ?, ?, ?, ?)",
            (definition.id, definition.name, definition.region, definition.version, SCHEMA_VERSION, built_at, license_text),
        )
        db.executemany(
            "INSERT INTO species (id, scientific_name, common_name, birdnet_label, inat_taxon_id, wikipedia_url, summary, field_marks, size, habitat, description_source, sort_order)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (r.entry.id, r.entry.scientific_name, r.entry.common_name, r.entry.birdnet_label, r.entry.inat_taxon_id, r.entry.wikipedia_url, *_description_columns(r.description), order)
                for order, r in enumerate(results)
            ],
        )
        db.executemany("INSERT INTO photo VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", photo_rows)
        db.commit()
        db.execute("VACUUM")

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


def _description_columns(description: Description | None) -> tuple[str | None, str | None, str | None, str | None, str | None]:
    """summary, field_marks, size, habitat, description_source; NULL rather than empty text for what is missing."""
    if description is None:
        return (None, None, None, None, None)
    return tuple(value or None for value in (description.summary, description.field_marks, description.size, description.habitat, description.source))


def _license_text(definition: PackDefinition, results: list[SpeciesResult], built_at: str) -> str:
    lines = [
        f"{definition.name} species pack for BirdJournal (pack id {definition.id}, version {definition.version}, built {built_at})",
        "",
        "Photos come from iNaturalist Open Data (https://github.com/inaturalist/inaturalist-open-data). Each photo is",
        "redistributed under the Creative Commons license its photographer chose on iNaturalist: CC0, CC BY or",
        "CC BY-NC (https://creativecommons.org/licenses/; the observation page below states the exact terms).",
        "Photographers retain copyright unless the photo is CC0. The crops in this pack are derived from the",
        "originals linked below.",
        "",
        "Species names and the BirdNET labels are from the BirdNET+ label file (CC BY-SA 4.0, https://birdnet.cornell.edu).",
        "",
        "Species descriptions (summary, field marks, size and habitat) are adapted from the English Wikipedia articles",
        "listed under \"Text credits\", written by Wikipedia contributors and licensed CC BY-SA 4.0",
        "(https://creativecommons.org/licenses/by-sa/4.0/). Each link is the article revision the text was taken from.",
        "",
        "Photo credits",
        "=============",
    ]
    for result in results:
        lines.append("")
        lines.append(f"{result.entry.common_name} ({result.entry.scientific_name})")
        for chosen in result.photos:
            credit = Credit.of(chosen.candidate)
            lines.append(f"  {credit.line} — {credit.source_url} — photo {chosen.candidate.photo_url('original')}")
    lines += ["", "Text credits", "============"]
    for result in results:
        if result.description and result.description.source:
            lines.append(f"  {result.entry.common_name} — {result.description.source}")
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
                "rejected": r.rejected or {},
                "detected": r.detected,
                "photos": len(r.photos),
                "gap": r.gap,
                "chosen": [chosen.candidate.photo_id for chosen in r.photos],
                "description": r.description.source if r.description and r.description.source else None,
            }
            for r in results
        },
        "gaps": {
            "photos": [r.entry.id for r in results if r.gap],
            "descriptions": [r.entry.id for r in results if r.description is None],
        },
    }
