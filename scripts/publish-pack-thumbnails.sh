#!/usr/bin/env bash
# Uploads a built pack's thumbnails to the art CDN (issues #62 and #136), so a friend's phone shows any find's patch or
# pack art without that pack: `packbuilder thumbnails` writes one small image per painting into
# build/pack-thumbnails/<id>/, and they go to the art bucket (the BirdJournal stack's ArtBucket output) under
# packs/<id>/patch/<species id>.png for a patch and packs/<id>/<species id>.jpg for pack art, the keys the phone's find
# policy sends. Part of publishing a pack (packs/README.md, "Publishing a new build"), after the release
# and before or after the index. Needs the deployed stack and the shared account's profile (lsvr-admin); nothing is
# deleted, so finds of a species a later version drops keep their picture.
#
#   scripts/publish-pack-thumbnails.sh us-ca-la            # writes and uploads
#   scripts/publish-pack-thumbnails.sh us-ca-la --dry-run  # only writes build/pack-thumbnails/us-ca-la/
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack_id="${1:?usage: $0 <pack id> [--dry-run]}"
profile="${AWS_PROFILE:-lsvr-admin}"
region="us-west-2"
stack="BirdJournal"

pack_dir="$repo_root/packs/$pack_id"
[ -f "$pack_dir/pack.sqlite" ] || pack_dir="$repo_root/build/packs/$pack_id"
[ -f "$pack_dir/pack.sqlite" ] || { echo "no built pack $pack_id under packs/ or build/packs/: run scripts/build-pack.sh $pack_id" >&2; exit 1; }
out_dir="$repo_root/build/pack-thumbnails/$pack_id"
rm -rf "$out_dir"

(cd "$repo_root/packbuilder" && uv run --quiet packbuilder thumbnails "$pack_dir" --out "$out_dir")

if [ "${2:-}" = "--dry-run" ]; then
    exit 0
fi

bucket="$(aws cloudformation describe-stacks --profile "$profile" --region "$region" --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='ArtBucket'].OutputValue" --output text)"
[ -n "$bucket" ] && [ "$bucket" != "None" ] || { echo "the $stack stack has no ArtBucket output: deploy the art CDN first" >&2; exit 1; }

# A day in caches, so a repainted species reaches old finds by the next day.
aws s3 sync "$out_dir" "s3://$bucket/packs/$pack_id/" --profile "$profile" --region "$region" \
    --exclude "*" --include "*.jpg" --content-type image/jpeg --cache-control "public, max-age=86400"
aws s3 sync "$out_dir" "s3://$bucket/packs/$pack_id/" --profile "$profile" --region "$region" \
    --exclude "*" --include "*.png" --content-type image/png --cache-control "public, max-age=86400"
echo "uploaded $(find "$out_dir" \( -name '*.jpg' -o -name '*.png' \) | wc -l | tr -d ' ') thumbnails to s3://$bucket/packs/$pack_id/"
