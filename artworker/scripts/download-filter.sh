#!/bin/sh
# Downloads the art worker's content filter (ADR-0007): Falconsai/nsfw_image_detection (Apache 2.0) as the ONNX export
# onnx-community/nsfw_image_detection-ONNX, pinned to a revision and checked against its SHA-256.
#   sh artworker/scripts/download-filter.sh [<dir>]     # default: artworker/models
set -eu
revision=1ceb3c7fe1e9f3f2507e6df577437f23a9149fd5
sha256=a4316a4fb750169ac4fcabaabee1fcbd982b0ee8c0cc63fe3e944954bb9a7d9c
dir=${1:-$(cd "$(dirname "$0")/.." && pwd)/models}
target="$dir/nsfw_image_detection.onnx"
mkdir -p "$dir"
check() {
    if command -v sha256sum >/dev/null; then sum=$(sha256sum "$1" | cut -d' ' -f1); else sum=$(shasum -a 256 "$1" | cut -d' ' -f1); fi
    [ "$sum" = "$sha256" ]
}
if [ -f "$target" ] && check "$target"; then
    echo "$target is in place"
    exit 0
fi
curl -fL --retry 3 -o "$target.part" "https://huggingface.co/onnx-community/nsfw_image_detection-ONNX/resolve/$revision/onnx/model.onnx"
check "$target.part" || { echo "SHA-256 mismatch for the content filter" >&2; rm -f "$target.part"; exit 1; }
mv "$target.part" "$target"
echo "$target"
