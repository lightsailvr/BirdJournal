#!/usr/bin/env python3
"""Refuse a build whose unpacked bundled packs differ from packs/manifest.json."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys


def check(packs: Path) -> list[str]:
    errors = []
    manifest = json.loads((packs / "manifest.json").read_text())
    for pin in manifest["packs"]:
        if not pin.get("bundled"):
            continue
        folder = packs / pin["id"]
        marker = folder / ".unpacked-sha256"
        if not marker.is_file() or marker.read_text().strip() != pin["sha256"]:
            errors.append(f"{pin['id']} is missing or stale (expected v{pin['version']}, unpacked checksum does not match the manifest)")
            continue
        database = folder / "pack.sqlite"
        if not database.is_file():
            errors.append(f"{pin['id']} is missing pack.sqlite")
            continue
        try:
            with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
                identity = connection.execute("SELECT id, version FROM pack").fetchall()
            if identity != [(pin["id"], pin["version"])]:
                errors.append(f"{pin['id']} database does not match its pinned id and version {pin['version']}")
        except sqlite3.Error as error:
            errors.append(f"{pin['id']} database cannot be read: {error}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packs-dir", type=Path, default=Path(__file__).resolve().parents[1] / "packs")
    args = parser.parse_args()
    try:
        errors = check(args.packs_dir)
    except (OSError, ValueError, KeyError) as error:
        errors = [f"cannot verify the bundled pack manifest: {error}"]
    for error in errors:
        print(f"error: Bundled pack {error}. Run scripts/download-pack.sh before building.", file=sys.stderr)
    if errors:
        return 1
    print("Bundled packs match packs/manifest.json.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
