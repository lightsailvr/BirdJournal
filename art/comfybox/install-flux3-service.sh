#!/bin/sh
# Installs comfyui-flux3.service and starts it, after install-flux3.sh. Run on comfybox with sudo:
#   scp art/comfybox/comfyui-flux3.service art/comfybox/install-flux3-service.sh matt@comfybox:birdjournal-art/
#   ssh -t matt@comfybox 'sudo sh ~/birdjournal-art/install-flux3-service.sh'
# The unit's @TAILNET_ADDRESS@ becomes the box's tailnet address. A ComfyUI started by hand on port 8189 is stopped
# first, so the service can bind it.
set -eu
here=$(dirname "$0")
address=$(tailscale ip -4 | head -n 1)
[ -n "$address" ] || { echo "no tailnet address: is Tailscale up?" >&2; exit 1; }
umask 022
sed "s/@TAILNET_ADDRESS@/$address/g" "$here/comfyui-flux3.service" > /etc/systemd/system/comfyui-flux3.service
systemctl daemon-reload
systemctl is-active --quiet comfyui-flux3 || fuser -k 8189/tcp 2>/dev/null || true
systemctl enable comfyui-flux3
systemctl restart comfyui-flux3
echo "comfyui-flux3 started; listening sockets once it has loaded (about a minute):"
sleep 5
ss -ltn | grep 8189 || echo "(not listening yet; check again with: ss -ltn | grep 8189)"
