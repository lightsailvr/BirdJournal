# Card art

Card art is painted by Qwen-Image-Edit-2511 in ComfyUI on comfybox, the home GPU box (ADR-0003). This folder holds what the painting depends on, so that the pack builder (pack art, #57) and the art worker (scene art and photo art, #68 and #69) paint the same way:

- `prompts.json`: the prompt templates for pack, scene and photo art, the negative prompt, the editions' themes and the standard and Legendary light, with a version.
- `workflows/{pack,scene,photo}-art.json` and `workflows/bird-cutout.json`: the ComfyUI graphs (API format, under `graph`), with a version each. `packbuilder.art.Workflow` fills the nodes titled `image 1`, `prompt`, `negative` and `sampler` (the seed); `packbuilder.comfy.ComfyClient` uploads the images, queues the graph and fetches the image it saved.
- `comfybox/`: the ComfyUI service drop-in that keeps it on the tailnet, and the model download script.
- `bakeoff/plan.json`: the species, reference photos and glasses scenes of the #49 bake-off.
- `comfyui/{pack,scene,photo}-art-tuning.json`: the same paintings as ComfyUI editor workflows, for tuning the style by hand (below).

Bump a file's `version` when its content changes; a pack's art lock (#57) records both versions with each painting.

## The model

| File (ComfyUI `models/` folder) | Source | License |
| --- | --- | --- |
| `diffusion_models/qwen_image_edit_2511_fp8mixed.safetensors` | `Comfy-Org/Qwen-Image-Edit_ComfyUI` | Apache 2.0 |
| `loras/Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors` (installed for quick tests; the workflows don't use it) | `lightx2v/Qwen-Image-Edit-2511-Lightning` | Apache 2.0 |
| `text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors` | `Comfy-Org/Qwen-Image_ComfyUI` | Apache 2.0 |
| `vae/qwen_image_vae.safetensors` | `Comfy-Org/Qwen-Image_ComfyUI` | Apache 2.0 |
| `RMBG/BiRefNet/BiRefNet-general.safetensors` and its three code and config files | `1038lab/BiRefNet`, a re-host of BiRefNet-general | MIT upstream (ZhengPeng7/BiRefNet); the re-host declares none |

`comfybox/download-models.sh` fetches them on the box and checks their SHA-256. The art graphs follow ComfyUI's `image_qwen_image_edit_2511` template at full quality: 40 steps, cfg 4 (so the negative prompt counts), euler and simple, shift 3.1, and the `index_timestep_zero` reference method. Every painting is 864 × 1152 (3:4 portrait, about a megapixel): image 1 is scaled and centre-cropped to that size and sets the canvas, so crop inputs to 3:4 first (`packbuilder.art.card_crop_box`). A painting takes about 3.5 minutes (with the 4-step Lightning LoRA it took 12 s, but painted flatter), and the same inputs and seed give the same image. FLUX-family models are excluded by their non-commercial licenses (ADR-0001, ADR-0003).

**Scene art is a composite**: the glasses photo is zoomed to the viewfinder's crop (the middle half of each side, `card_crop_box(..., zoom=2)`), the species' reference bird is cut out onto transparency by `bird-cutout.json` and pasted in near the middle at card size (`packbuilder.art.paste_bird`), and the painting blends it in. The bird's identity comes from a real photo: asked to add the bird from a second image, Qwen drew its own idea of the species (a red finch became a Northern Cardinal) at the wrong scale. The scene reference must be unobstructed, since a twig across the bird cuts a hole in it. The cut-out runs BiRefNet-general through the `BiRefNetRMBG` node of the comfyui-rmbg custom node pack (commit 58f1947 on the box). The same pack's `RMBG` node runs RMBG-2.0, which is CC BY-NC and must not be used (ADR-0001). The node fetches the weights from the `1038lab/BiRefNet` re-host, whose file differs from upstream's `model.safetensors`; confirm the provenance, or switch to the upstream weights, before the art worker ships (#68).

What the bake-off taught the templates (details in `DECISIONS.md`, "Art model bake-off"): scene and photo art never name the species, because a name pulls in the model's stereotype of it (a female or young bird became a bright male); pack art does, and needs a well-lit, typical adult reference for the same reason.

## Tuning by hand

The look is tuned by hand in ComfyUI's editor, then the batch paints with it. On comfybox the three workflows sit in the Workflows sidebar under `BirdJournal/` (`pack art tuning`, `scene art tuning`, `photo art tuning`; copies in `comfyui/`). Each has a read-me note and five groups:

1. **Picture**: `image 1`, a dropdown in which the sample inputs start with `birdjournal-` (ComfyUI lists only the top of its input folder). That is every species' pack reference, two photo-art photos each, and scene composites of every species in three full-resolution glasses photos.
2. **Prompt**: the template with its `{placeholders}` kept, the negative prompt, and one small node per placeholder that fills it in.
3. **Quality**: Fast preview on (4-step Lightning, about 12 s) or off (40 steps, cfg 4, about 3.5 minutes).
4. **Model**.
5. The painting itself.

When a look is right, save the workflow with Fast preview off. Then the template, the negative prompt and the field values go into `prompts.json`, and the graph, exported in API format with the node titles `image 1`, `prompt`, `negative`, `sampler` and `output` kept, into `workflows/<kind>-art.json`. Bump both versions, and `python -m packbuilder.bakeoff paint` repaints the plan.

**Style pass** (`comfyui/style-pass.json`, on comfybox as `BirdJournal/style pass`) restyles a finished telephoto painting (`birdjournal-telephoto-<spot>`) with the photo-art graph. The reference bird goes in as image 2, so the restyle keeps the species. Its note holds six style paragraphs, from fantasy line art to an epic Renaissance myth painting, to paste in. `comfyui/alternatives/klein-4b-distilled-style-pass.json` does the same with Klein 4B distilled, from one image.

## Alternative models

`comfybox/download-alternatives.sh` installs the Apache 2.0 alternatives to compare with Qwen-Image-Edit-2511 at putting a real bird into a scene. Each is SHA-256-checked:

- FLUX.2 [klein] 4B, base and distilled, in fp8, with BFL's small-decoder VAE.
- FireRed Image Edit 1.1 as the official Q4_K_M GGUF, with its 8-step Lightning LoRA.
- Three consistency LoRAs: one for Klein 4B (lrzjason) and two for Qwen 2511 (lrzjason, Kalaido).

`comfyui/alternatives/` holds ComfyUI's own templates for them, adapted, and they sit on comfybox under `BirdJournal/alternatives/`:

- **Inputs**: the bird cut out onto white (`birdjournal-bird-<species>`) and a zoomed glasses photo (`birdjournal-glasses-<scene>`).
- **Prompt and seed**: the research's prompt and a fixed seed.
- **Licensing and memory**:
  - The distilled Klein uses the small-decoder VAE in place of `flux2-vae`, whose repository declares the FLUX non-commercial license.
  - FireRed loads the GGUF in place of its 41 GB bf16 file.

**Telephoto scene** (`comfyui/alternatives/klein-4b-distilled-telephoto.json`, on comfybox as `Klein 4B distilled - telephoto scene`): through the glasses' wide lens a bird is the size of a leaf. So the workflow crops a 10–15× frame out of the full-resolution glasses photo (`birdjournal-glasses-<scene>-3024`) around a perch, the way a long lens would frame it from the same spot. It blurs the crop into a 300 mm lens's bokeh and gives it to FLUX.2 [klein] 4B distilled as image 2, with the bird cut out onto white as image 1. The read-me note holds the crop sizes per zoom and the audition's spots. About 7 s a painting.

Left out on purpose (ADR-0001):

- FLUX.2 [klein] 9B and FLUX.2 [dev]: non-commercial weights.
- Qwen-Image 2.1: its own commercial license.
- OmniGen2: its Qwen2.5-VL-3B encoder is research-only.

## comfybox

ComfyUI has no authentication, so it listens on loopback and the box's tailnet address only (`http://comfybox:8188`, 100.80.25.1), never the home LAN. `comfybox/tailnet-only.conf` is a systemd drop-in for `comfyui.service` that sets that up and waits for tailscaled before binding. Install or update it with sudo on the box:

```sh
scp art/comfybox/tailnet-only.conf art/comfybox/install-tailnet-only.sh matt@100.80.25.1:birdjournal-art/
ssh -t matt@100.80.25.1 'sudo sh ~/birdjournal-art/install-tailnet-only.sh'
```

Check it with `ss -ltn | grep 8188` on the box: two sockets, 127.0.0.1 and 100.80.25.1. A request to the box's LAN address is refused. The drop-in also runs ComfyUI without `--highvram` and `--use-sage-attention`: the first stops ComfyUI offloading part of a model, so the 20.5 GB Qwen model ran out of the 24 GB card, and the second turned every Qwen image black.

## The bake-off (#49)

```sh
cd packbuilder
uv run python -m packbuilder.bakeoff references --limit 150 --keep 12   # ranks open-license photos, writes a draft plan
uv run python -m packbuilder.bakeoff paint --scenes ../build/art-bakeoff/scenes
uv run python -m packbuilder.bakeoff sheets --scenes ../build/art-bakeoff/scenes
```

`references` ranks each species' CC0 and CC BY photos among the Los Angeles and San Diego packs' cached candidates the way a pack build ranks photos, and draws them on `build/art-bakeoff/references.jpg`. Pick the reference, the two stand-in birder photos and, where the reference isn't a clean perched bird, a `scene_reference` in `plan.json` by hand. The scenes are the sightings' glasses photos, pulled from the phone with `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.matthewcelia.mybirdjournal --source "Library/Application Support/Frames/<file>.jpg" --destination ../build/art-bakeoff/scenes/`; they stay out of the repository. `paint` is resumable and writes the paintings, the cut-outs and composites, `results.json` (prompt, seed, versions, ComfyUI's time per painting) and, with `sheets`, one contact sheet per species plus an overview to `build/art-bakeoff/`. At full quality all 90 paintings take about five hours.
