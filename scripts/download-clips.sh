#!/usr/bin/env bash
# Downloads the labeled test clips listed in fixtures/clips.json (entries with a url) into fixtures/clips/ and
# verifies each SHA-256. Safe to re-run: files that already match are skipped. See fixtures/README.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="$repo_root/fixtures"
manifest="$fixtures_dir/clips.json"
source "$repo_root/scripts/lib/download.sh"

# file<TAB>url<TAB>sha256 per line, only for entries that have a url
entries="$(python3 - "$manifest" <<'PY'
import json, sys
for clip in json.load(open(sys.argv[1]))["clips"]:
    if clip.get("url"):
        print(f"{clip['file']}\t{clip['url']}\t{clip.get('sha256', '')}")
PY
)"

if ! download_entries "$entries" "$fixtures_dir"; then
    echo "One or more clips failed verification." >&2
    exit 1
fi
echo "All clips present in $fixtures_dir/clips"
