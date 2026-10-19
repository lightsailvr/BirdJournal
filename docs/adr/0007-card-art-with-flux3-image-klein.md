# Card art is painted by FLUX.3 Image Klein under the FLUX Kommunity License

Status: proposed, 2026-10-19. Supersedes ADR-0003's choice of model (Qwen-Image-Edit-2511); the rest of ADR-0003 stands.

The #49 bake-off settled on FLUX.3 Image Klein, which Black Forest Labs released on 2026-10-15: the distilled 5.6B checkpoint in int8, on comfybox, painting a natural-history watercolour of a bird taken from a real photo. The maintainer picked its look over every Qwen-Image-Edit-2511 and FLUX.2 [klein] 4B round. It keeps the bird's pattern without inventing marks, and it paints a card in 10–17 s at full quality, against Qwen's 207 s, so the art worker's daily allowance can grow.

ADR-0003 excluded FLUX models because the FLUX.2 [dev] and FLUX.1 Kontext [dev] license is non-commercial and does not cover use "in direct interactions with or that has impact on end users". FLUX.3 Image Klein comes under a different license, the FLUX Kommunity License v1.0. Its non-commercial grant has the same end-user exclusion, but section 2.a adds a grant for a Qualifying User, anyone whose gross annualized revenue with their affiliates is under US$5M. A Qualifying User may use the outputs, including those of derivatives, for commercial purposes, and may run the model in a production environment solely to generate those outputs. BirdJournal is free with optional tips (ADR-0001), far under the threshold, so it relies on the Qualifying User grant, not the non-commercial one. Tips may count as revenue toward the threshold.

The license's conditions on outputs (section 2.e) and how BirdJournal meets them:

- **Content filters or review.** Pack art is reviewed by the maintainer on contact sheets before a pack ships. Scene and photo art are painted for a birder without review, so the art worker (#68) must run a filter on every painting before it reaches a card. Black Forest Labs' reference code uses Falconsai/nsfw_image_detection; check its license before adopting it.
- **Disclosure that the output was generated.** The style guide already labels card art "AI illustration" or "AI-embellished from your photo"; the reverse's art provenance should also name the model.

The license is personal to the licensee and not sublicensable, and it forbids distributing the weights without its notice. The weights stay on comfybox and never ship in the app or a pack: only paintings do. The FLUX.2 VAE that FLUX.3 decodes with comes from the same repository under the same license. Its text encoder, Qwen3-VL-4B-Instruct, is Apache 2.0.

This reading of the license is the maintainer's to confirm, and it is not legal advice.

## Consequences

- ADR-0001's "no card art from a non-commercially licensed model" holds in substance. The FLUX Kommunity License is non-commercial except for a Qualifying User's outputs, and BirdJournal uses only that exception. Crossing US$5M in revenue, a paid tier or a corporate owner over the threshold reopens this ADR, as would any change to ADR-0001.
- Before the art worker ships (#68): a content filter on every scene and photo painting, and the model's name in the card's art provenance.
- The model needs ComfyUI 0.41. It runs on its own ComfyUI beside the shared 0.34 install (`comfyui-flux3.service`, port 8189, tailnet-only like the shared one), so ivan-parallax's custom node packs are untouched.
- The Qwen-Image-Edit-2511 models stay installed on the shared ComfyUI. A hosted Qwen endpoint (ADR-0003) is no longer a like-for-like fallback; a hosted FLUX.3 endpoint (Black Forest Labs' API) would need its own terms checked.
