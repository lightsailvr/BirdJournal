#!/bin/sh
# Copies the art worker to comfybox and installs its environment, from the Mac (issue #68). Safe to run again: it
# updates the code, the reference birds and the content filter in place and restarts the service if it runs.
#   artworker/comfybox/deploy-to-comfybox.sh [<host>]        # default matt@comfybox
#
# On the box it lands as ~/birdjournal-art/repo/{art,packbuilder,artworker} (the repository's layout, which
# packbuilder.art needs to find art/), ~/birdjournal-art/references/<pack id>/ (the reference birds: export them first
# with `packbuilder art-references`, into build/art-references/<pack id>/) and the filter under
# ~/birdjournal-art/models/. Then install-artworker-service.sh (with sudo) starts the service.
set -eu
host=${1:-matt@comfybox}
repo=$(cd "$(dirname "$0")/../.." && pwd)
references="$repo/build/art-references"
ls "$references"/*/references.json >/dev/null 2>&1 || {
    echo "no reference birds in $references: run, per pack," >&2
    echo "  (cd packbuilder && uv run packbuilder art-references packs/<id> --pack ../packs/<id> --out ../build/art-references/<id>)" >&2
    exit 1
}
ssh "$host" 'mkdir -p ~/birdjournal-art/repo ~/birdjournal-art/references ~/birdjournal-art/models ~/birdjournal-art/cache'
rsync -az --delete --exclude .venv --exclude .pytest_cache --exclude __pycache__ --exclude cache --exclude models \
    "$repo/art" "$repo/packbuilder" "$repo/artworker" "$host:birdjournal-art/repo/"
rsync -az --delete "$references/" "$host:birdjournal-art/references/"
ssh "$host" 'set -e
    command -v uv >/dev/null || [ -x ~/.local/bin/uv ] || curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    cd ~/birdjournal-art/repo/artworker
    uv sync --frozen --no-dev
    sh scripts/download-filter.sh ~/birdjournal-art/models
    if systemctl is-active --quiet birdjournal-artworker; then sudo -n systemctl restart birdjournal-artworker 2>/dev/null || echo "restart it: sudo systemctl restart birdjournal-artworker"; fi'
echo "copied. First time: run infra/scripts/art-wizard.sh (it writes ~/birdjournal-art/artworker.env), then"
echo "  ssh -t $host 'sudo sh ~/birdjournal-art/repo/artworker/comfybox/install-artworker-service.sh'"
