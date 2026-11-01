#!/bin/sh
# Installs tailnet-only.conf as a drop-in for comfyui.service, its @TAILNET_ADDRESS@ filled in with the box's tailnet
# address, and restarts ComfyUI. Run on comfybox with sudo:
#   ssh -t matt@comfybox 'sudo sh ~/birdjournal-art/install-tailnet-only.sh'
set -eu
here=$(dirname "$0")
address=$(tailscale ip -4 | head -n 1)
[ -n "$address" ] || { echo "no tailnet address: is Tailscale up?" >&2; exit 1; }
umask 022
install -d /etc/systemd/system/comfyui.service.d
sed "s/@TAILNET_ADDRESS@/$address/g" "$here/tailnet-only.conf" > /etc/systemd/system/comfyui.service.d/tailnet-only.conf
systemctl daemon-reload
systemctl restart comfyui
echo "comfyui restarted; listening sockets once it has loaded (about a minute):"
sleep 5
ss -ltn | grep 8188 || echo "(not listening yet; check again with: ss -ltn | grep 8188)"
