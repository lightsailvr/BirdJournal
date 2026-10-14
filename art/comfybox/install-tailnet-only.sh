#!/bin/sh
# Installs tailnet-only.conf as a drop-in for comfyui.service and restarts ComfyUI. Run on comfybox with sudo:
#   ssh -t matt@100.80.25.1 'sudo sh ~/birdjournal-art/install-tailnet-only.sh'
set -eu
here=$(dirname "$0")
install -d /etc/systemd/system/comfyui.service.d
install -m 644 "$here/tailnet-only.conf" /etc/systemd/system/comfyui.service.d/tailnet-only.conf
systemctl daemon-reload
systemctl restart comfyui
echo "comfyui restarted; listening sockets once it has loaded (about a minute):"
sleep 5
ss -ltn | grep 8188 || echo "(not listening yet; check again with: ss -ltn | grep 8188)"
