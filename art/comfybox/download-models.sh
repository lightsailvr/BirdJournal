#!/bin/sh
# Downloads Qwen-Image-Edit-2511 (fp8mixed), its 4-step Lightning LoRA, the text encoder and the VAE (all Apache 2.0)
# and BiRefNet-general for scene art's cut-out into ComfyUI's model folders on comfybox, and checks each file's SHA-256.
# About 32 GB; a partial download resumes. Run on the box: sh ~/birdjournal-art/download-models.sh
set -eu
MODELS=${MODELS:-/home/matt/comfyui-easy-install/ComfyUI/models}
HF=https://huggingface.co

get() { # folder file url sha256
    mkdir -p "$MODELS/$1"
    target="$MODELS/$1/$2"
    if [ ! -f "$target" ]; then
        curl -fL --retry 5 -C - -o "$target.part" "$3"
        mv "$target.part" "$target"
    fi
    echo "$4  $target" | sha256sum -c -
}

get vae qwen_image_vae.safetensors \
    $HF/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors \
    a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f
get loras Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors \
    $HF/lightx2v/Qwen-Image-Edit-2511-Lightning/resolve/main/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors \
    22226e8d05d354bb356627d428809f5afd7819399b077238a2b70a82883a904f
get text_encoders qwen_2.5_vl_7b_fp8_scaled.safetensors \
    $HF/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors \
    cb5636d852a0ea6a9075ab1bef496c0db7aef13c02350571e388aea959c5c0b4
get diffusion_models qwen_image_edit_2511_fp8mixed.safetensors \
    $HF/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors \
    c9fdc158e46d3b61ef75f21ae866ca2fe808bf4a53643120d1c1e87c19280a4e

# BiRefNet-general where the comfyui-rmbg node looks for it (models/RMBG/BiRefNet), from the 1038lab/BiRefNet re-host
# the node uses. Upstream (ZhengPeng7/BiRefNet) is MIT; the re-host declares no license (see art/README.md).
BIREFNET=$HF/1038lab/BiRefNet/resolve/main
get RMBG/BiRefNet BiRefNet-general.safetensors $BIREFNET/BiRefNet-general.safetensors \
    77277264c0e8c74149d3ff2fade4fd8176965b7108f3c5fc3b8c9c811edb4519
get RMBG/BiRefNet birefnet.py $BIREFNET/birefnet.py \
    bd2986cee78b6d649ba7464066a0ba393cc45910ba1cb413ed91ca8fbb226f86
get RMBG/BiRefNet BiRefNet_config.py $BIREFNET/BiRefNet_config.py \
    e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52
get RMBG/BiRefNet config.json $BIREFNET/config.json \
    966a1f0165b072d2d1309756e71907750e535ba5c3790d8cd0e69713ff3a56cd
