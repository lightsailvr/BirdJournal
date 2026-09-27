#!/usr/bin/env bash
# Downloads the pinned model files listed in models/manifest.json into models/ and verifies each SHA-256.
# Safe to re-run: files that already match their checksum are skipped.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models_dir="$repo_root/models"
manifest="$models_dir/manifest.json"
source "$repo_root/scripts/lib/download.sh"

# name<TAB>url<TAB>sha256 per line
entries="$(python3 - "$manifest" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f"{f['name']}\t{f['url']}\t{f['sha256']}")
PY
)"

if ! download_entries "$entries" "$models_dir"; then
    echo "One or more model files failed verification." >&2
    exit 1
fi
echo "All model files present in $models_dir"
