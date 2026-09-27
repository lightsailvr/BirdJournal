#!/usr/bin/env bash
# Builds a species pack from its definition folder, fetching the detector model, iNaturalist metadata and photos into
# packbuilder/cache on the way. The pack the app bundles (`bundled` in packs/manifest.json) is written to packs/<id>/,
# which the Pack package target ships as a resource; every other pack goes to build/packs/<id>/, so a downloadable pack
# never ends up in the app binary. Both write build/packs/<id>.zip, the release asset. Needs uv (`brew install uv`);
# uv creates the Python environment on first run.
#
#   scripts/build-pack.sh                 # the bundled Los Angeles pack, us-ca-la
#   scripts/build-pack.sh us-ca-sd        # a downloadable pack, to build/packs/us-ca-sd/
#   scripts/build-pack.sh us-ca-la --limit 60
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack_id="${1:-us-ca-la}"
shift $(( $# > 0 ? 1 : 0 ))

if ! command -v uv >/dev/null; then
    echo "uv is required: brew install uv" >&2
    exit 1
fi

bundled="$(python3 -c 'import json, sys
packs = json.load(open(sys.argv[1]))["packs"]
print("yes" if any(p["id"] == sys.argv[2] and p.get("bundled") for p in packs) else "no")' "$repo_root/packs/manifest.json" "$pack_id")"
if [ "$bundled" = yes ]; then
    out="$repo_root/packs/$pack_id"
else
    out="$repo_root/build/packs/$pack_id"
fi
echo "building $pack_id into $out"

cd "$repo_root/packbuilder"
uv run --quiet packbuilder build "packs/$pack_id" --out "$out" --zip "$repo_root/build/packs/$pack_id.zip" "$@"
