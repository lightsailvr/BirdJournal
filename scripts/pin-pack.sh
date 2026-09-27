#!/usr/bin/env bash
# Records a built pack zip in packs/manifest.json: the release tag and asset it is (or will be) published as, its
# SHA-256 and byte count. Run after scripts/build-pack.sh and before `gh release create` (see packs/README.md).
#
#   scripts/pin-pack.sh us-ca-la            # tag pack-us-ca-la-v<version>, asset us-ca-la.zip
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pack_id="${1:-us-ca-la}"
zip="$repo_root/build/packs/$pack_id.zip"
manifest="$repo_root/packs/manifest.json"
[ -f "$zip" ] || { echo "no $zip: run scripts/build-pack.sh $pack_id first" >&2; exit 1; }

version="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$repo_root/packbuilder/packs/$pack_id/pack.json")"
sha256="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
bytes="$(stat -f%z "$zip")"

python3 - "$manifest" "$pack_id" "$version" "$sha256" "$bytes" <<'PY'
import json, sys
path, pack_id, version, sha256, size = sys.argv[1:]
manifest = json.load(open(path))
entry = {"id": pack_id, "version": int(version), "release": f"pack-{pack_id}-v{version}", "asset": f"{pack_id}.zip", "sha256": sha256, "bytes": int(size)}
manifest["packs"] = [p for p in manifest["packs"] if p["id"] != pack_id] + [entry]
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
print(json.dumps(entry, indent=2))
PY
