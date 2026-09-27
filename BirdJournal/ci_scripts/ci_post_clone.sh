#!/bin/sh
# Xcode Cloud post-clone hook. Runs after the repository is cloned and before package resolution
# and the build. Xcode Cloud only picks it up from a `ci_scripts` folder beside the .xcodeproj.
#
# The model files in models/manifest.json (~80 MB) and the built species packs in packs/manifest.json (the
# bundled Los Angeles pack, ~150 MB) are gitignored, so a fresh clone lacks them. Fetch and verify them here so
# the app can bundle them exactly as it does from a local checkout. The pack download needs a GITHUB_TOKEN
# environment variable on the workflow (the repository is private; see scripts/download-pack.sh).
set -eu

"$CI_PRIMARY_REPOSITORY_PATH/scripts/download-models.sh"
"$CI_PRIMARY_REPOSITORY_PATH/scripts/download-pack.sh"
