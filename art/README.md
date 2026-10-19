# Card art

Card art is painted by FLUX.3 Image Klein in ComfyUI on comfybox, the home GPU box (ADR-0003; the model is ADR-0007, proposed). This folder holds what the painting depends on, so that the pack builder (pack art, #57) and the art worker (scene art and photo art, #68 and #69) paint the same way:

- `prompts.json`: the prompt templates for pack, scene and photo art, the isolation prompt, the editions' themes and the standard and Legendary light, with a version.
- `workflows/{pack,scene,photo}-art.json`, `workflows/bird-isolate.json` and `workflows/bird-cutout.json`: the ComfyUI graphs (API format, under `graph`), with a version each. `packbuilder.art.Workflow` fills the nodes titled `image 1`, `image 2`, `prompt`, `canvas` (the size, where it isn't the card's) and `sampler` (the seed); `packbuilder.comfy.ComfyClient` uploads the images, queues the graph and fetches the image it saved.
- `comfybox/`: the FLUX.3 ComfyUI's install script, systemd unit and model download, and the shared ComfyUI's tailnet-only drop-in.
- `bakeoff/plan.json`: the species (with their lengths), reference photos and glasses scenes (with their perch points) of the #49 bake-off.
- `comfyui/`: editor workflows from the Qwen-Image-Edit-2511 and FLUX.2 [klein] rounds of the bake-off, kept for the record (`DECISIONS.md`, "Art model bake-off").

Bump a file's `version` when its content changes; a pack's art lock (#57) records both versions with each painting.

## How a painting is made

Every painting is a natural-history watercolour with touches of gouache, and every bird in it comes from a real photo, given to FLUX.3 as `<ref_image_0>`. FLUX.3 reads a caption of the finished picture, not an instruction, so the templates describe the result. No template names the species: a name pulls in the model's stereotype of it (a red finch became a Northern Cardinal, a dull female a bright male), and the reference is the identity.

- **Pack art** (`pack-art.json`, one image): the species' open-license reference bird, isolated (below), framed by the edition's motifs on a pale paper ground.
- **Scene art** (`scene-art.json`, two images): the same isolated bird as `<ref_image_0>` and, as `<ref_image_1>`, the telephoto crop of the glasses photo from the add (`packbuilder.art.telephoto_crop`). The glasses' wide lens makes a bird the size of a leaf, so the crop zooms in as a long lens would from the same spot: 12× for a 14.5 cm House Finch and in proportion to the bird's length for others (4× for a Cooper's Hawk, 17× for a hummingbird), so that every bird is painted at card size and at its true size against the place. The crop's perch point (the bake-off plan's `perch`, the middle of the photo otherwise) lands a little below the middle. The place keeps its own shapes and colours; the edition adds only its light and a few accents of its colours, because its motifs would be claims about a place the photo doesn't show.
- **Photo art** (`photo-art.json`, one image): the birder's own photo, cropped to 3:4 around the bird with room around it, painted with its setting.
- **Legendary** scene and photo art get a golden glow behind the bird, a warm rim of light and deeper corners; the bird keeps its true colours. Pack art, the same for every birder, has none.

**Isolating the reference** (`bird-isolate.json`, `prompts.json`'s `isolate`). Given a photo crop as `<ref_image_0>`, FLUX.3 carries the photo's perch, leaves and framing into the painting. Given a cut-out (BiRefNet), it paints the cut-out's flaws: a tail tip cut off by a branch becomes a loose strip, a twig across the shoulder a notch. So FLUX.3 first paints the reference bird alone on white at the crop's own size, completing what the perch hid, in the photo's own light. Then the bird is cut out of that painting, and its colours are fitted back to the photo's (below), with the same retries if it isn't faithful. Pack and scene art then paint from this bird.

**Fidelity, the colour fit and the gate** (`packbuilder.fidelity`). The bird's markings are its identification and must not change. FLUX.3 mostly keeps the pattern, but it shifts colour and tone, most for a dim photo, and now and then paints a different bird (a Great Egret came out a streaked brown bird). Both birds are cut out, the photo's is registered onto the painted one (a scale and a shift maximising the outlines' IoU), and the colours are compared inside both after a 6 px blur: the mean CIE76 ΔE, where 2.3 is just noticeable, and its 95th percentile. The fit then gives the painted bird the photo's colour and tone: each Lab channel's mean and spread over the painted bird's own interior are matched to the photo bird's, inside the bird only, so the brushwork stays and nothing outside the bird moves. (A line fitted pixel by pixel did better on paper but needs the outlines to line up; where they didn't, it flattened the bird into a silhouette.) A painting is **faithful** when, after the fit, its bird is within ΔE 10 of the photo's and the outlines overlap by at least 0.65: a colour or exposure shift is fitted away, a different pattern or shape is not. An unfaithful painting is painted again with the next seed, three times at most, and if none is faithful the closest is kept and marked for review. The fitted painting is the card art. A dim photo therefore gives a dim bird: art references must be well-lit.

## The model

| File (the FLUX.3 ComfyUI's `models/` folder) | Source | License |
| --- | --- | --- |
| `diffusion_models/flux3_image_klein_sd_int8_convrot.safetensors` | `black-forest-labs/flux-3-image-klein-comfy` (gated) | FLUX Kommunity License v1.0 |
| `text_encoders/qwen3vl_4b_int8_convrot.safetensors` | the same | Qwen3-VL-4B-Instruct, Apache 2.0 |
| `vae/flux2-vae.safetensors` | the same | FLUX Kommunity License v1.0 |
| `RMBG/BiRefNet/BiRefNet-general.safetensors` and its three code and config files | `1038lab/BiRefNet`, a re-host of BiRefNet-general | MIT upstream (ZhengPeng7/BiRefNet); the re-host declares none |

The distilled checkpoint in int8, which runs on the 3090 Ti (Ampere has no FP8 or FP4; the NVFP4 files need Blackwell): 16 steps, no guidance (cfg 1, the negative zeroed, so there is no negative prompt), euler and simple, the references at their own resolution (at most 1536 px a side) and an 864 × 1152 canvas, as ComfyUI 0.41's `image_flux3_klein_distilled_image_edit` template. A painting takes about 14 s on the box (18 s for scene art's two references), an isolation 13 s and a BiRefNet cut-out 1.3 s, and the same inputs and seed give the same image. The FLUX Kommunity License allows a Qualifying User (under US$5M gross annual revenue) to use the outputs commercially and to run the model in production to make them, on two conditions: content filtering or review of the outputs, and a disclosure that they are AI-generated. ADR-0007 sets out how BirdJournal meets them; until it is accepted, the model is an evaluation.

The cut-out runs BiRefNet-general through the `BiRefNetRMBG` node of the comfyui-rmbg custom node pack (commit 58f1947). The same pack's `RMBG` node runs RMBG-2.0, which is CC BY-NC and must not be used (ADR-0001). The node fetches the weights from the `1038lab/BiRefNet` re-host, whose file differs from upstream's `model.safetensors`; confirm the provenance, or switch to the upstream weights, before the art worker ships (#68).

## comfybox

The box runs two ComfyUIs, both on loopback and the box's tailnet address only (`comfybox`, 100.80.25.1), never the home LAN, because ComfyUI has no authentication:

- **Port 8188**, `comfyui.service`: the shared ComfyUI 0.34 (`~/comfyui-easy-install`), with ivan-parallax's custom node packs, Qwen-Image-Edit-2511 and the earlier rounds' alternatives. `comfybox/tailnet-only.conf` is its systemd drop-in.
- **Port 8189**, `comfyui-flux3.service`: ComfyUI 0.41.1 (`~/comfyui-flux3`) for FLUX.3, which needs 0.41 and which the shared install's node packs are not ready for. It borrows the shared install's Python and torch and adds only what 0.41.1 pins differently, plus comfyui-rmbg for BiRefNet. All card art runs here.

Set up or update the FLUX.3 ComfyUI on the box (it needs `hf auth login` with an account that has accepted the FLUX Kommunity License on the gated repository, and `download-models.sh` run once for BiRefNet):

```sh
scp art/comfybox/install-flux3.sh art/comfybox/fetch-gated.py art/comfybox/comfyui-flux3.service art/comfybox/install-flux3-service.sh matt@100.80.25.1:birdjournal-art/
ssh matt@100.80.25.1 'sh ~/birdjournal-art/install-flux3.sh'
ssh -t matt@100.80.25.1 'sudo sh ~/birdjournal-art/install-flux3-service.sh'
```

`install-flux3.sh` is safe to run again: it checks the ComfyUI tag, the node's commit and every model file's SHA-256. `fetch-gated.py` downloads in 16 ranged parts, because on FLUX.3's release day Hugging Face's Xet transfer stalled and a single connection gave about 1.5 MB/s. Check the service with `ss -ltn | grep 8189` on the box: two sockets, 127.0.0.1 and 100.80.25.1.

The shared drop-in: install or update it with sudo on the box.

```sh
scp art/comfybox/tailnet-only.conf art/comfybox/install-tailnet-only.sh matt@100.80.25.1:birdjournal-art/
ssh -t matt@100.80.25.1 'sudo sh ~/birdjournal-art/install-tailnet-only.sh'
```

It also runs ComfyUI without `--highvram` and `--use-sage-attention`: the first stops ComfyUI offloading part of a model, so the 20.5 GB Qwen model ran out of the 24 GB card, and the second turned every Qwen image black. `comfyui-flux3.service` leaves both out too.

## Tuning by hand

On the FLUX.3 ComfyUI (`http://comfybox:8189`), open the template "Flux.3 Image Klein Distilled: Image Edit", plug a second `Load Image` into `Set Reference Multi Latent` for scene art (the bird first, then the place), and paste the prompt from `prompts.json` with its placeholders filled. The inputs the bake-off painted from are in `build/art-bakeoff/v<prompts version>/` (`isolated/` for the birds). When a look is right, its template goes into `prompts.json` and any graph change into `workflows/`, with the versions bumped, and `python -m packbuilder.bakeoff paint` repaints the plan into a new folder.

## The bake-off (#49)

```sh
cd packbuilder
uv run python -m packbuilder.bakeoff references --limit 150 --keep 12   # ranks open-license photos, writes a draft plan
uv run python -m packbuilder.bakeoff paint --scenes ../build/art-bakeoff/scenes
uv run python -m packbuilder.bakeoff sheets --scenes ../build/art-bakeoff/scenes
```

`references` ranks each species' CC0 and CC BY photos among the Los Angeles and San Diego packs' cached candidates the way a pack build ranks photos, and draws them on `build/art-bakeoff/references.jpg`. Pick the reference, the two stand-in birder photos and, where it should differ, a `scene_reference` in `plan.json` by hand: a well-lit, typical adult, because a dim photo gives a dim bird. The scenes are the sightings' glasses photos, pulled from the phone with `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.matthewcelia.mybirdjournal --source "Library/Application Support/Frames/<file>.jpg" --destination ../build/art-bakeoff/scenes/`; they stay out of the repository, and each needs a `perch` in the plan.

`paint` is resumable and writes `build/art-bakeoff/v<prompts version>/`: per species each painting (the card art, colours fitted) and `<name>-raw.png` (FLUX.3's own), `isolated/` (the reference birds on white), `cutouts/`, and `results.json` (prompt, seed, versions, ComfyUI's time and both birds' fidelity per painting). `sheets` adds one contact sheet per species (the references, FLUX.3's paintings and the fitted ones) and an overview to `sheets/`. The whole plan, 90 paintings and 13 isolations with their retries, takes about 40 minutes run on the box itself. From the Mac it waits on the tailnet, which has run at 420 KB/s; to run it on the box, copy `packbuilder/src`, `art/` and the scenes to a checkout-shaped folder there and run with the FLUX.3 venv's Python (`PYTHONPATH=src ~/comfyui-flux3/.venv/bin/python -m packbuilder.bakeoff paint --comfy http://127.0.0.1:8189 ...`).
