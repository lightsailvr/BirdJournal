#!/usr/bin/env bash
# Downloads the pinned model files listed in models/manifest.json into models/ and verifies each SHA-256.
# Safe to re-run: files that already match their checksum are skipped.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
models_dir="$repo_root/models"
manifest="$models_dir/manifest.json"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# name<TAB>url<TAB>sha256 per line
entries="$(python3 - "$manifest" <<'PY'
import json, sys
for f in json.load(open(sys.argv[1]))["files"]:
    print(f"{f['name']}\t{f['url']}\t{f['sha256']}")
PY
)"

failed=0
while IFS=$'\t' read -r name url expected; do
    [ -n "$name" ] || continue
    target="$models_dir/$name"
    if [ -f "$target" ] && [ "$(sha256_of "$target")" = "$expected" ]; then
        echo "ok       $name"
        continue
    fi
    echo "fetching $name"
    tmp="$target.download"
    curl --fail --location --silent --show-error --retry 3 --output "$tmp" "$url"
    actual="$(sha256_of "$tmp")"
    if [ "$actual" != "$expected" ]; then
        echo "CHECKSUM MISMATCH $name" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        rm -f "$tmp"
        failed=1
        continue
    fi
    mv "$tmp" "$target"
    echo "verified $name"
done <<< "$entries"

if [ "$failed" -ne 0 ]; then
    echo "One or more model files failed verification." >&2
    exit 1
fi
echo "All model files present in $models_dir"
