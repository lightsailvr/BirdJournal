#!/usr/bin/env bash
# Publishes the pack index the phone reads (issue #13): every pack in packs/manifest.json as `PackIndex` in the Swift
# Pack module decodes it (id, name, version, url, sha256, byteCount, since #28 speciesCount, photoCount and region,
# since #41 soundCount and schemaVersion, when the manifest has them, and since #54 the set), uploaded as index.json
# to the rolling `packs` release of this repository (created on first use, replaced on every run). The pack zips stay on their own
# per-version releases; the index points at them by URL. Run after `gh release create pack-<id>-v<n> ...` so every
# listed zip exists.
#
#   scripts/publish-pack-index.sh            # writes build/pack-index/index.json and uploads it
#   scripts/publish-pack-index.sh --dry-run  # only writes the file
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="lightsailvr/BirdJournal"
manifest="$repo_root/packs/manifest.json"
out_dir="$repo_root/build/pack-index"
index="$out_dir/index.json"
tag="packs"
mkdir -p "$out_dir"

# Since #54 each entry also carries its pack's set definition (packbuilder/packs/<id>/set.json), which
# `packbuilder index` checks against the definition first.
(cd "$repo_root/packbuilder" && uv run --quiet packbuilder index --out "$index" --repo "$repo")

if [ "${1:-}" = "--dry-run" ]; then
    exit 0
fi

for asset in $(python3 -c 'import json, sys; print(" ".join(p["release"] + "/" + p["asset"] for p in json.load(open(sys.argv[1]))["packs"]))' "$manifest"); do
    release="${asset%%/*}"
    name="${asset##*/}"
    if ! gh release view "$release" --repo "$repo" --json assets --jq '.assets[].name' | grep -qx "$name"; then
        echo "release $release has no asset $name: publish the pack before the index" >&2
        exit 1
    fi
done

if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$repo" --title "Species pack index" \
        --notes "index.json lists every species pack for the BirdJournal app (packs/manifest.json). Replaced by scripts/publish-pack-index.sh on every pack release."
fi
gh release upload "$tag" "$index" --repo "$repo" --clobber
echo "published $index to release $tag"
