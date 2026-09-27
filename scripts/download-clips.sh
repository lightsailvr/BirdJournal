#!/usr/bin/env bash
# Downloads the labeled test clips listed in fixtures/clips.json (entries with a url) into fixtures/clips/ and
# verifies each SHA-256. Safe to re-run: files that already match are skipped. See fixtures/README.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures_dir="$repo_root/fixtures"
manifest="$fixtures_dir/clips.json"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# file<TAB>url<TAB>sha256 per line, only for entries that have a url
entries="$(python3 - "$manifest" <<'PY'
import json, sys
for clip in json.load(open(sys.argv[1]))["clips"]:
    if clip.get("url"):
        print(f"{clip['file']}\t{clip['url']}\t{clip.get('sha256', '')}")
PY
)"

partial=""
trap '[ -n "$partial" ] && rm -f "$partial"' EXIT

failed=0
while IFS=$'\t' read -r file url expected; do
    [ -n "$file" ] || continue
    target="$fixtures_dir/$file"
    mkdir -p "$(dirname "$target")"
    if [ -f "$target" ] && [ -n "$expected" ] && [ "$(sha256_of "$target")" = "$expected" ]; then
        echo "ok       $file"
        continue
    fi
    echo "fetching $file"
    tmp="$target.download"
    partial="$tmp"
    curl --fail --location --silent --show-error --retry 3 --retry-all-errors --output "$tmp" "$url"
    partial=""
    if [ -n "$expected" ]; then
        actual="$(sha256_of "$tmp")"
        if [ "$actual" != "$expected" ]; then
            echo "CHECKSUM MISMATCH $file" >&2
            echo "  expected $expected" >&2
            echo "  actual   $actual" >&2
            rm -f "$tmp"
            failed=1
            continue
        fi
    fi
    mv "$tmp" "$target"
    echo "verified $file"
done <<< "$entries"

if [ "$failed" -ne 0 ]; then
    echo "One or more clips failed verification." >&2
    exit 1
fi
echo "All clips present in $fixtures_dir/clips"
