#!/usr/bin/env bash
# Shared by scripts/download-models.sh and scripts/download-clips.sh: fetches files listed as
# "relative-path<TAB>url<TAB>sha256" lines into a directory and verifies each checksum. Files that already match
# are skipped; a partial download is removed if curl aborts; an empty sha256 skips verification.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/download.sh"
#   download_entries "$entries" "$destination_dir"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Global, not local: the EXIT trap runs after download_entries has returned.
partial=""
trap '[ -n "$partial" ] && rm -f "$partial"' EXIT

download_entries() {
    local entries="$1" dest="$2"
    local failed=0

    local name url expected target tmp actual
    while IFS=$'\t' read -r name url expected; do
        [ -n "$name" ] || continue
        target="$dest/$name"
        mkdir -p "$(dirname "$target")"
        if [ -f "$target" ] && [ -n "$expected" ] && [ "$(sha256_of "$target")" = "$expected" ]; then
            echo "ok       $name"
            continue
        fi
        echo "fetching $name"
        tmp="$target.download"
        partial="$tmp"
        curl --fail --location --silent --show-error --retry 3 --retry-all-errors --output "$tmp" "$url"
        partial=""
        if [ -n "$expected" ]; then
            actual="$(sha256_of "$tmp")"
            if [ "$actual" != "$expected" ]; then
                echo "CHECKSUM MISMATCH $name" >&2
                echo "  expected $expected" >&2
                echo "  actual   $actual" >&2
                rm -f "$tmp"
                failed=1
                continue
            fi
        fi
        mv "$tmp" "$target"
        echo "verified $name"
    done <<< "$entries"

    return "$failed"
}
