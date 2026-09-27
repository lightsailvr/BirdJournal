"""`packbuilder build <definition-dir> --out <pack-dir>`: builds one pack from its definition folder."""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from packbuilder.definition import PackDefinition
from packbuilder.detector import BirdDetector, ensure_model
from packbuilder.pipeline import BuildOptions, build_pack


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="packbuilder", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="build a pack")
    build.add_argument("definition", type=Path, help="folder holding pack.json and overrides.json")
    build.add_argument("--out", type=Path, required=True, help="pack directory to write (replaced)")
    build.add_argument("--source", choices=["api", "opendata"], default="api", help="iNaturalist API (default) or the Open Data metadata CSVs")
    build.add_argument("--metadata-dir", type=Path, help="folder with the extracted Open Data CSVs (with --source opendata)")
    build.add_argument("--cache", type=Path, default=Path(__file__).resolve().parents[2] / "cache", help="download cache (default: packbuilder/cache)")
    build.add_argument("--limit", type=int, default=60, help="cleared candidates per species to download and detect (default 60)")
    build.add_argument("--min-photos", type=int, default=3, help="photos per species below which a gap is logged (default 3)")
    build.add_argument("--max-photos", type=int, default=5, help="photos kept per species (default 5)")
    build.add_argument("--zip", type=Path, metavar="PATH", help="also write a zip of the pack at PATH")
    build.add_argument("--built-at", help="ISO timestamp to record instead of now (for reproducible output)")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stderr)
    definition = PackDefinition.load(args.definition / "pack.json")

    if args.source == "opendata":
        if not args.metadata_dir:
            parser.error("--source opendata needs --metadata-dir")
        from packbuilder.metadata_opendata import OpenDataMetadata

        metadata = OpenDataMetadata(args.metadata_dir, definition.bounding_box, [s.inat_taxon_id for s in definition.species])
    else:
        from packbuilder.metadata_api import APIMetadata

        metadata = APIMetadata(definition.place_id, args.cache, created_before=definition.created_before)

    detector = BirdDetector(ensure_model(args.cache))
    options = BuildOptions(cache_dir=args.cache, out_dir=args.out, candidate_limit=args.limit, min_photos=args.min_photos, max_photos=args.max_photos, archive_path=args.zip, built_at=args.built_at)
    build_pack(definition, args.definition / "overrides.json", metadata, detector, options)
    return 0


if __name__ == "__main__":
    sys.exit(main())
