"""Candidates from the iNaturalist Open Data metadata dump (tab-separated CSVs), queried with DuckDB.

The dump (`s3://inaturalist-open-data/metadata/inaturalist-open-data-latest.tar.gz`) unpacks to
observations.csv, photos.csv, taxa.csv and observers.csv, tens of gigabytes in all; DuckDB scans them without
loading them into memory. Column names follow Metadata/structure.sql in inaturalist/inaturalist-open-data.
"""

from __future__ import annotations

from pathlib import Path

import duckdb

from packbuilder.candidates import PhotoCandidate
from packbuilder.definition import BoundingBox


class OpenDataMetadata:
    def __init__(self, metadata_dir: Path, bounding_box: BoundingBox):
        self.metadata_dir = Path(metadata_dir)
        self.bounding_box = bounding_box
        for name in ("observations.csv", "photos.csv", "observers.csv"):
            if not (self.metadata_dir / name).exists():
                raise FileNotFoundError(f"{name} not found in {self.metadata_dir}")

    def candidates_for(self, taxon_id: int) -> list[PhotoCandidate]:
        box = self.bounding_box
        query = """
            SELECT p.photo_id, p.extension, p.license, obs.name, obs.login,
                   o.observation_uuid, o.taxon_id, o.quality_grade, p.width, p.height, p.position
            FROM read_csv(?, delim='\t', header=true, quote='') AS o
            JOIN read_csv(?, delim='\t', header=true, quote='') AS p ON p.observation_uuid = o.observation_uuid
            LEFT JOIN read_csv(?, delim='\t', header=true, quote='') AS obs ON obs.observer_id = p.observer_id
            WHERE o.taxon_id = ? AND o.quality_grade = 'research'
              AND o.latitude BETWEEN ? AND ? AND o.longitude BETWEEN ? AND ?
            ORDER BY p.photo_id
        """
        rows = duckdb.execute(
            query,
            [
                str(self.metadata_dir / "observations.csv"),
                str(self.metadata_dir / "photos.csv"),
                str(self.metadata_dir / "observers.csv"),
                taxon_id,
                box.south, box.north, box.west, box.east,
            ],
        ).fetchall()
        return [
            PhotoCandidate(
                photo_id=int(photo_id),
                extension=str(extension),
                license=None if license is None else str(license),
                observer_name=None if name is None else str(name),
                observer_login=None if login is None else str(login),
                observation_id=None,
                observation_uuid=str(observation_uuid),
                taxon_id=int(row_taxon),
                quality_grade=None if grade is None else str(grade),
                width=None if width is None else int(width),
                height=None if height is None else int(height),
                position=None if position is None else int(position),
            )
            for photo_id, extension, license, name, login, observation_uuid, row_taxon, grade, width, height, position in rows
        ]
