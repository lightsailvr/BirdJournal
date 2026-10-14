#!/bin/sh
# Alternative edit models and LoRAs to try against Qwen-Image-Edit-2511 (#49), into ComfyUI's model folders on
# comfybox, each checked by SHA-256 (Hugging Face's LFS ids). All Apache 2.0, checked 2026-10-14. About 24 GB.
# Run on the box: sh ~/birdjournal-art/download-alternatives.sh
#
# Left out on purpose: flux2-vae.safetensors (its Comfy-Org/flux2-dev repo declares the FLUX non-commercial license;
# the Apache small decoder below stands in), FLUX.2 Klein 9B and FLUX.2 [dev] (non-commercial weights), Qwen-Image 2.1
# (its own commercial license) and OmniGen2 (its Qwen2.5-VL-3B encoder is research-only). ADR-0001.
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

# FLUX.2 [klein] 4B, base (undistilled) and distilled, fp8; the text encoder is the qwen_3_4b already installed for
# Z-Image Turbo (Comfy-Org/z_image_turbo, same hash). VAE: BFL's full encoder with the small decoder.
get diffusion_models flux-2-klein-base-4b-fp8.safetensors \
    $HF/black-forest-labs/FLUX.2-klein-base-4b-fp8/resolve/main/flux-2-klein-base-4b-fp8.safetensors \
    44bab3a86fe98b85d21dd2a4729ebdc3ae51fb8a39f76e457e18c724219e6840
get diffusion_models flux-2-klein-4b-fp8.safetensors \
    $HF/black-forest-labs/FLUX.2-klein-4b-fp8/resolve/main/flux-2-klein-4b-fp8.safetensors \
    97ed34fe0567e436200f2faee3939b88f2b5d99f8af2a4dc16532c4245c0ccb6
get vae full_encoder_small_decoder.safetensors \
    $HF/black-forest-labs/FLUX.2-small-decoder/resolve/main/full_encoder_small_decoder.safetensors \
    ea4273f02d1fafbf8e1d1c2cf6018ed8748652eb0bf34f2dd91171f16f15ab62

# FireRed Image Edit 1.1 (Qwen-Image based: same text encoder and VAE as Qwen-Image-Edit), Q4_K_M GGUF for 24 GB, and
# its 8-step Lightning LoRA.
get unet FireRed-Image-Edit-1.1-transformer-q4_k_m.gguf \
    $HF/FireRedTeam/FireRed-Image-Edit-1.1-ComfyUI/resolve/main/FireRed-Image-Edit-1.1-transformer-q4_k_m.gguf \
    4474f975cbd6e74203d2a4a1ae64c51c2c355a7d9b7ce0db605556cb1c91fff7
get loras FireRed-Image-Edit-1.1-Lightning-8steps-v1.2.safetensors \
    $HF/FireRedTeam/FireRed-Image-Edit-1.1-ComfyUI/resolve/main/FireRed-Image-Edit-1.1-Lightning-8steps-v1.2.safetensors \
    e8089300fd0b76c0bb3441ff64509258e95b483cc7c5a6f955add907d6c8177d

# Consistency LoRAs: for Klein 4B, and two for Qwen-Image-Edit-2511.
get loras f2k_4B_consist_20260314.safetensors \
    $HF/lrzjason/Consistance_Edit_Lora/resolve/main/f2k_4B_consist_20260314.safetensors \
    bed1e7e8747bc4572a20a7fcef436e82cfbfa5430d0162eda713b55d7a3c7ce4
get loras qe2511_consis_alpha_patched.safetensors \
    $HF/lrzjason/Consistance_Edit_Lora/resolve/main/qe2511_consis_alpha_patched.safetensors \
    60bc9573638c0710d3ea2cabdd0c36b6ccbfcb5672664d1f6acc93c9577e3605
get loras qwen-2511_general_edit_lora_v1.safetensors \
    $HF/FractalAIResearch/Kalaido-qwenedit-lora/resolve/main/qwen-2511_general_edit_lora_v1.safetensors \
    665bba55e804c3fc6801a43745ab0ed5c7769d0e25badfb61c4b803d97381450
echo ALL_DONE
