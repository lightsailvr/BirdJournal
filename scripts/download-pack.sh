#!/usr/bin/env bash
# Fetches the species packs the app bundles (`bundled` in packs/manifest.json) from this repo's GitHub Releases into
# packs/<id>/, verifying each zip's SHA-256 before unpacking. The bundled Los Angeles pack (about 160 species,
# DECISIONS.md "Species pack") is too big to commit, so a clean checkout runs this before building the app; the Xcode
# Cloud post-clone hook does the same. Safe to re-run: a pack whose unpacked marker matches the manifest is skipped.
# Naming a pack fetches that one whether or not it is bundled; mind that everything under packs/ ships in the app.
#
# The repository is public, so the release assets need no credentials. A logged-in `gh` CLI is used when there is
# one, a GITHUB_TOKEN environment variable when set (both raise the API rate limit), else plain curl.
#
# The zips are kept under build/ (gitignored), never under packs/: the Pack package target copies the whole packs/
# folder into the app's resource bundle, so anything left there would ship.
#
#   scripts/download-pack.sh            # every bundled pack
#   scripts/download-pack.sh us-ca-la   # one pack, bundled or not
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
        curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
            --output "$target" "https://github.com/$repo/releases/download/$tag/$asset"
        return
    fi
    local auth="Authorization: Bearer $GITHUB_TOKEN"
    local asset_id
    asset_id="$(curl --fail --silent --show-error -H "$auth" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repo/releases/tags/$tag" \
        | python3 -c 'import json, sys; name = sys.argv[1]; print(next(a["id"] for a in json.load(sys.stdin)["assets"] if a["name"] == name))' "$asset")"
    curl --fail --location --silent --show-error --retry 3 --retry-all-errors -H "$auth" -H "Accept: application/octet-stream" \
        --output "$target" "https://api.github.com/repos/$repo/releases/assets/$asset_id"
}

# id<TAB>version<TAB>tag<TAB>asset<TAB>sha256 per line: the bundled packs, or the one named
entries="$(python3 - "$manifest" "$only" <<'PY'
import json, sys
only = sys.argv[2]
for p in json.load(open(sys.argv[1]))["packs"]:
    if only == p["id"] or (not only and p.get("bundled")):
        print(f"{p['id']}\t{p['version']}\t{p['release']}\t{p['asset']}\t{p['sha256']}")
PY
)"

failed=0
while IFS=$'\t' read -r id version tag asset expected; do
    [ -n "$id" ] || continue
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
