"""The art worker's reference birds (issue #68): every species' isolated reference bird from a pack build, for scene art.

Scene art paints the same bird pack art does: the species' reference photo, isolated by FLUX.3 on white and fitted
back to the photo's colours (`painting.Painter.isolate`, #57). The pack build caches those birds under
`cache/art/isolated/`, keyed by photo, isolation seed and workflow, and `art.lock.json` says which one each species'
pack art was painted from. This export copies them, with each bird's length (which sizes the telephoto crop), into a
folder the art worker on comfybox reads:

    <out>/references.json   {"pack": id, "species": {scientific name: {"file", "length_cm", "photo_id", "species_id"}},
                             "missing": [scientific names with no cached bird], "no_reference": [painted from text]}
    <out>/<species id>.png  the bird on white

Only species whose pack art the maintainer approved are exported: the reference was looked at on the contact sheets
(well lit, the whole bird, its feet showing).
"""

from __future__ import annotations

import json
import shutil
import sqlite3
from pathlib import Path

from packbuilder.art import length_cm
from packbuilder.pack_art import APPROVED, ArtLock

REFERENCES_FILE = "references.json"


def isolated_bird(cache_dir: Path, entry: dict) -> Path | None:
    """The cached isolated bird a lock entry's pack art was painted from. The cache names a bird by the seed its
    isolation started from (`<photo>-s<seed>-<workflow>-i<prompt hash>.png`), and the JSON beside it, like the lock,
    records the seed that won (a retry's is the next one); the lock doesn't pin the isolation prompt, so among matches
    the newest wins."""
    if not entry.get("photos") or entry.get("isolate_seed") is None or not entry.get("isolate"):
        return None
    candidates = sorted((cache_dir / "isolated").glob(f"{entry['photos'][0]}-s*-{entry['isolate']}-i*.png"), key=lambda path: path.stat().st_mtime)
    matches = [path for path in candidates if _won_with(path) == entry["isolate_seed"]]
    return matches[-1] if matches else None


def _won_with(bird: Path) -> int | None:
    info = bird.with_suffix(".json")
    return json.loads(info.read_text()).get("seed") if info.exists() else None


def pack_species(pack_db: Path) -> dict[str, tuple[str, str | None]]:
    """Each species' scientific name and size text ("16 cm") by species id, from a built pack."""
    connection = sqlite3.connect(f"file:{pack_db}?mode=ro", uri=True)
    try:
        return {row[0]: (row[1], row[2]) for row in connection.execute("SELECT id, scientific_name, size FROM species")}
    finally:
        connection.close()


def export(pack_id: str, lock: ArtLock, overrides: dict[str, dict], pack_db: Path, cache_dir: Path, out: Path) -> dict:
    """Writes the references for one pack into `out` (replacing what was there) and returns references.json."""
    known = pack_species(pack_db)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    species: dict[str, dict] = {}
    missing: list[str] = []
    no_reference: list[str] = []
    for species_id, entry in sorted(lock.species.items()):
        if species_id not in known or entry.get("review") != APPROVED:
            continue
        name, size = known[species_id]
        if not entry.get("photos"):
            no_reference.append(name)
            continue
        bird = isolated_bird(cache_dir, entry)
        if bird is None:
            missing.append(name)
            continue
        pinned = overrides.get(name, {}).get("art", {}) if isinstance(overrides.get(name), dict) else {}
        length = pinned.get("length_cm") or length_cm(size)
        if length is None:
            missing.append(name)
            continue
        shutil.copyfile(bird, out / f"{species_id}.png")
        species[name] = {"file": f"{species_id}.png", "length_cm": float(length), "photo_id": entry["photos"][0], "species_id": species_id}
    references = {"pack": pack_id, "species": species, "missing": missing, "no_reference": no_reference}
    (out / REFERENCES_FILE).write_text(json.dumps(references, indent=2, ensure_ascii=False) + "\n")
    return references
