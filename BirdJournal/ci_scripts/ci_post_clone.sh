#!/bin/sh
# Xcode Cloud post-clone hook. Runs after the repository is cloned and before package resolution
# and the build. Xcode Cloud only picks it up from a `ci_scripts` folder beside the .xcodeproj.
#
# The model files in models/manifest.json are gitignored (~80 MB), so a fresh clone lacks them.
# Fetch and verify them here so the app can bundle them exactly as it does from a local checkout.
set -eu

"$CI_PRIMARY_REPOSITORY_PATH/scripts/download-models.sh"
