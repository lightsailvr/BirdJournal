#!/bin/sh
# Installs birdjournal-artworker.service and starts it. Run on comfybox with sudo, after deploy-to-comfybox.sh has
# copied the worker and the art wizard has written ~/birdjournal-art/artworker.env:
#   ssh -t matt@comfybox 'sudo sh ~/birdjournal-art/repo/artworker/comfybox/install-artworker-service.sh'
set -eu
here=$(dirname "$0")
home=/home/matt/birdjournal-art
[ -f "$home/artworker.env" ] || { echo "$home/artworker.env is missing: run infra/scripts/art-wizard.sh first" >&2; exit 1; }
[ -x "$home/repo/artworker/.venv/bin/python" ] || { echo "the worker isn't installed: run artworker/comfybox/deploy-to-comfybox.sh first" >&2; exit 1; }
chmod 600 "$home/artworker.env"
umask 022
cp "$here/birdjournal-artworker.service" /etc/systemd/system/birdjournal-artworker.service
systemctl daemon-reload
systemctl enable birdjournal-artworker
systemctl restart birdjournal-artworker
sleep 3
systemctl --no-pager --lines=15 status birdjournal-artworker || true
echo "follow it with: journalctl -fu birdjournal-artworker"
