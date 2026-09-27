#!/usr/bin/env bash
# Fetches the built species packs listed in packs/manifest.json from this repo's GitHub Releases into packs/<id>/,
# verifying each zip's SHA-256 before unpacking. The bundled Los Angeles pack (about 160 species, DECISIONS.md
# "Species pack") is too big to commit, so a clean checkout runs this before building the app; the Xcode Cloud
# post-clone hook does the same. Safe to re-run: a pack whose unpacked marker matches the manifest is skipped.
#
# The repository is private, so the release assets need credentials: the `gh` CLI when it is installed and logged
# in (a developer machine), else a GITHUB_TOKEN environment variable with read access to the repository's contents
# (Xcode Cloud: an environment variable on the workflow).
#
# The zips are kept under build/ (gitignored), never under packs/: the Pack package target copies the whole packs/
# folder into the app's resource bundle, so anything left there would ship.
#
#   scripts/download-pack.sh            # every pack in the manifest
#   scripts/download-pack.sh us-ca-la   # one pack
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packs_dir="$repo_root/packs"
manifest="$packs_dir/manifest.json"
downloads="$repo_root/build/pack-downloads"
repo="lightsailvr/BirdJournal"
only="${1:-}"
source "$repo_root/scripts/lib/download.sh"  # sha256_of and the trap that removes a partial download on exit

fetch_asset() {
    local tag="$1" asset="$2" target="$3"
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        gh release download "$tag" --repo "$repo" --pattern "$asset" --output "$target" --clobber
        return
    fi
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        echo "Neither a logged-in gh CLI nor GITHUB_TOKEN is available to fetch $asset from release $tag of $repo." >&2
        return 1
    fi
    local auth="Authorization: Bearer $GITHUB_TOKEN"
    local asset_id
    asset_id="$(curl --fail --silent --show-error -H "$auth" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repo/releases/tags/$tag" \
        | python3 -c 'import json, sys; name = sys.argv[1]; print(next(a["id"] for a in json.load(sys.stdin)["assets"] if a["name"] == name))' "$asset")"
    curl --fail --location --silent --show-error --retry 3 --retry-all-errors -H "$auth" -H "Accept: application/octet-stream" \
        --output "$target" "https://api.github.com/repos/$repo/releases/assets/$asset_id"
}

# id<TAB>version<TAB>tag<TAB>asset<TAB>sha256 per line
entries="$(python3 - "$manifest" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["packs"]:
    print(f"{p['id']}\t{p['version']}\t{p['release']}\t{p['asset']}\t{p['sha256']}")
PY
)"

failed=0
while IFS=$'\t' read -r id version tag asset expected; do
    [ -n "$id" ] || continue
    if [ -n "$only" ] && [ "$only" != "$id" ]; then continue; fi
    pack_dir="$packs_dir/$id"
    marker="$pack_dir/.unpacked-sha256"
    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$expected" ] && [ -f "$pack_dir/pack.sqlite" ]; then
        echo "ok       $id v$version"
        continue
    fi
    mkdir -p "$downloads"
    zip="$downloads/$id-v$version.zip"
    if [ ! -f "$zip" ] || [ "$(sha256_of "$zip")" != "$expected" ]; then
        echo "fetching $asset from release $tag"
        rm -f "$zip"
        partial="$zip.download"
        if ! fetch_asset "$tag" "$asset" "$zip.download"; then
            rm -f "$zip.download"
            partial=""
            failed=1
            continue
        fi
        partial=""
        actual="$(sha256_of "$zip.download")"
        if [ "$actual" != "$expected" ]; then
            echo "CHECKSUM MISMATCH $asset" >&2
            echo "  expected $expected" >&2
            echo "  actual   $actual" >&2
            rm -f "$zip.download"
            failed=1
            continue
        fi
        mv "$zip.download" "$zip"
    fi
    echo "unpacking $id v$version"
    rm -rf "$pack_dir.unpacking"
    mkdir -p "$pack_dir.unpacking"
    unzip -q "$zip" -d "$pack_dir.unpacking"
    rm -rf "$pack_dir"
    mv "$pack_dir.unpacking" "$pack_dir"
    echo "$expected" > "$marker"
    echo "verified $id v$version"
done <<< "$entries"

if [ "$failed" -ne 0 ]; then
    echo "One or more packs failed to download." >&2
    exit 1
fi
echo "All packs present in $packs_dir"
