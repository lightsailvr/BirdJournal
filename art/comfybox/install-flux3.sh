#!/bin/sh
# Sets up the ComfyUI that paints card art with FLUX.3 Image Klein (ADR-0007, proposed): ComfyUI 0.41.1 beside the
# shared ComfyUI 0.34 that comfyui.service runs, which ivan-parallax's custom node packs depend on and which FLUX.3 is
# too new for. It borrows the shared install's Python and torch, adds only what 0.41.1 pins differently, and takes
# the comfyui-rmbg node (BiRefNet, for the cut-outs) at the commit the shared install runs. Safe to run again.
#
# Run on the box as matt, after `hf auth login` with an account that has accepted the FLUX Kommunity License on
# huggingface.co/black-forest-labs/flux-3-image-klein-comfy, and after download-models.sh (for BiRefNet):
#   scp art/comfybox/install-flux3.sh art/comfybox/fetch-gated.py matt@100.80.25.1:birdjournal-art/
#   ssh matt@100.80.25.1 'sh ~/birdjournal-art/install-flux3.sh'
# Then install-flux3-service.sh runs it as comfyui-flux3.service on port 8189.
set -eu
ROOT=${ROOT:-$HOME/comfyui-flux3}
SHARED=${SHARED:-$HOME/comfyui-easy-install}
COMFY_TAG=v0.41.1
RMBG_COMMIT=58f1947a11567a9f8b707223185570850e773856
here=$(cd "$(dirname "$0")" && pwd)

[ -d "$ROOT/.git" ] || git clone -q --depth 1 --branch $COMFY_TAG https://github.com/comfyanonymous/ComfyUI "$ROOT"
[ "$(git -C "$ROOT" describe --tags)" = $COMFY_TAG ] || { echo "$ROOT is not ComfyUI $COMFY_TAG" >&2; exit 1; }

# The shared python_embeded is itself a venv, so --system-site-packages would not reach its torch: a .pth file puts
# its site-packages after the new venv's own, so the pins below shadow the shared versions and nothing else changes.
[ -x "$ROOT/.venv/bin/python" ] || "$SHARED/python_embeded/bin/python3" -m venv "$ROOT/.venv"
shared_site=$("$SHARED/python_embeded/bin/python3" -c 'import site; print(site.getsitepackages()[0])')
venv_site=$("$ROOT/.venv/bin/python" -c 'import site; print(site.getsitepackages()[0])')
echo "$shared_site" > "$venv_site/zz-comfy-embedded.pth"
# ComfyUI 0.41.1's requirements.txt pins; and a pyOpenSSL that works with the shared cryptography 50, without which
# two of ComfyUI's own node modules (nodes_latent, nodes_post_processing) fail to import.
"$ROOT/.venv/bin/python" -m pip install -q comfyui-frontend-package==1.55.17 comfyui-workflow-templates==0.11.85 \
    comfyui-embedded-docs==0.5.14 comfy-kitchen==0.2.37 comfy-aimdo==0.5.6 pyOpenSSL==26.4.0
"$ROOT/.venv/bin/python" -c 'import torch; assert torch.cuda.is_available(); print("torch", torch.__version__, "with CUDA")'

rmbg=$ROOT/custom_nodes/comfyui-rmbg
[ -d "$rmbg/.git" ] || git clone -q https://github.com/1038lab/ComfyUI-RMBG "$rmbg"
git -C "$rmbg" -c advice.detachedHead=false checkout -q $RMBG_COMMIT

# BiRefNet-general (MIT upstream; see art/README.md on the re-host), hard-linked from the shared install's models.
mkdir -p "$ROOT/models/RMBG/BiRefNet"
for f in BiRefNet-general.safetensors birefnet.py BiRefNet_config.py config.json; do
    ln -f "$SHARED/ComfyUI/models/RMBG/BiRefNet/$f" "$ROOT/models/RMBG/BiRefNet/$f"
done
cd "$ROOT/models/RMBG/BiRefNet" && sha256sum -c - <<EOF
77277264c0e8c74149d3ff2fade4fd8176965b7108f3c5fc3b8c9c811edb4519  BiRefNet-general.safetensors
bd2986cee78b6d649ba7464066a0ba393cc45910ba1cb413ed91ca8fbb226f86  birefnet.py
e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52  BiRefNet_config.py
966a1f0165b072d2d1309756e71907750e535ba5c3790d8cd0e69713ff3a56cd  config.json
EOF

# FLUX.3 Image Klein, distilled, int8 (the int8 files run on the 3090 Ti, which has no FP8 or FP4), its Qwen3-VL-4B
# text encoder and the FLUX.2 VAE, all from the gated ComfyUI repository under the FLUX Kommunity License. About 11 GB.
fetch() { # path sha256
    "$ROOT/.venv/bin/python" "$here/fetch-gated.py" black-forest-labs/flux-3-image-klein-comfy "$1" "$ROOT/models" "$2"
}
fetch diffusion_models/flux3_image_klein_sd_int8_convrot.safetensors 847d8933548afd93df4af2cac2498e70891bf28d9dae06d695f536992e168fe2
fetch text_encoders/qwen3vl_4b_int8_convrot.safetensors 32de113cbf8282b02cbff0794b637b9d6676da09314a1db5a30bcea9bf4ee01c
fetch vae/flux2-vae.safetensors 868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3
echo "FLUX.3 ComfyUI ready in $ROOT"
