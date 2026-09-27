#!/usr/bin/env bash
# Builds a species pack from its definition folder into packs/<id>/ (plus build/packs/<id>.zip), fetching the
# detector model, iNaturalist metadata and photos into packbuilder/cache on the way. Needs uv (`brew install uv`);
# uv creates the Python environment on first run.
#
#   scripts/build-pack.sh                 # the bundled Los Angeles pack, us-ca-la
#   scripts/build-pack.sh us-ca-la --limit 60
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack_id="${1:-us-ca-la}"
shift $(( $# > 0 ? 1 : 0 ))

if ! command -v uv >/dev/null; then
    echo "uv is required: brew install uv" >&2
    exit 1
fi

cd "$repo_root/packbuilder"
uv run --quiet packbuilder build "packs/$pack_id" --out "$repo_root/packs/$pack_id" --zip "$repo_root/build/packs/$pack_id.zip" "$@"
