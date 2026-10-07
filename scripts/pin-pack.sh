#!/usr/bin/env bash
# Records a built pack zip in packs/manifest.json: its name, the release tag and asset it is (or will be) published as,
# its SHA-256 and byte count, its counts and database schema, and whether the app bundles it. Run after scripts/build-pack.sh and before
# `gh release create` (see packs/README.md). An existing entry keeps its `bundled` flag; a new pack is a download
# unless --bundled says otherwise (only one pack is bundled: PackIndex.bundledPackID in the Swift Pack module).
#
#   scripts/pin-pack.sh us-ca-la            # tag pack-us-ca-la-v<version>, asset us-ca-la.zip
#   scripts/pin-pack.sh us-ca-sd            # a downloadable pack
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack_id="${1:-us-ca-la}"
bundled_flag="${2:-}"
zip="$repo_root/build/packs/$pack_id.zip"
manifest="$repo_root/packs/manifest.json"
definition="$repo_root/packbuilder/packs/$pack_id/pack.json"
[ -f "$zip" ] || { echo "no $zip: run scripts/build-pack.sh $pack_id first" >&2; exit 1; }

sha256="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
bytes="$(stat -f%z "$zip")"
# The built pack's database, for the counts and the region the phone shows before a download (issue #28). sqlite3
# ships with macOS.
command -v sqlite3 >/dev/null || { echo "sqlite3 is needed to read the pack's counts" >&2; exit 1; }
database="$repo_root/packs/$pack_id/pack.sqlite"
[ -f "$database" ] || database="$repo_root/build/packs/$pack_id/pack.sqlite"
[ -f "$database" ] || { echo "no pack.sqlite for $pack_id under packs/ or build/packs/" >&2; exit 1; }
species="$(sqlite3 "$database" 'select count(*) from species')"
photos="$(sqlite3 "$database" 'select count(*) from photo')"
region="$(sqlite3 "$database" 'select region from pack')"
schema="$(sqlite3 "$database" 'select schema_version from pack')"
# Schema 3 (issue #41) has the sound table; a schema-2 pack has no sounds.
sounds="$(sqlite3 "$database" "select count(*) from sqlite_master where name = 'sound'")"
[ "$sounds" = 0 ] || sounds="$(sqlite3 "$database" 'select count(*) from sound')"

python3 - "$manifest" "$definition" "$pack_id" "$sha256" "$bytes" "$bundled_flag" "$species" "$photos" "$region" "$schema" "$sounds" <<'PY'
import json, sys
path, definition, pack_id, sha256, size, bundled_flag, species, photos, region, schema, sounds = sys.argv[1:]
manifest = json.load(open(path))
pack = json.load(open(definition))
previous = next((p for p in manifest["packs"] if p["id"] == pack_id), None)
bundled = bundled_flag == "--bundled" or bool(previous and previous.get("bundled"))
entry = {
    "id": pack_id, "name": pack["name"], "version": int(pack["version"]), "bundled": bundled,
    "release": f"pack-{pack_id}-v{pack['version']}", "asset": f"{pack_id}.zip", "sha256": sha256, "bytes": int(size),
    "species": int(species), "photos": int(photos), "sounds": int(sounds), "region": region, "schema_version": int(schema),
}
manifest["packs"] = [p for p in manifest["packs"] if p["id"] != pack_id] + [entry]
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(json.dumps(entry, indent=2))
PY
