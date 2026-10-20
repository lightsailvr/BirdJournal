# Card art is painted on a home GPU box that pulls jobs from a queue, with no paid fallback

Status: accepted, 2026-10-13. Its choice of model (the second paragraph) is superseded by ADR-0007, 2026-10-19; the rest stands.

Scene art and photo art are painted by an art worker on the home GPU box (RTX 3090 Ti, 24 GB, on the tailnet). It long-polls an SQS queue over outbound connections only, uploads the result to S3 and reports back to the API with a worker token. Nothing reaches into the home network. This is the design ivan-parallax's ADR-0002 planned for the same box. A paid hosted fallback was rejected while the app earns only tips (ADR-0001): when the box is off, art waits and the card shows its pack art with "Artwork is on its way." The queue lets a second worker, such as a hosted Qwen endpoint at about $0.03 per image, join later without changing the app.

The model is Qwen-Image-Edit-2511 (Apache 2.0). FLUX.2 [klein] 9B and FLUX.1 Kontext [dev] are excluded even for a free app, because their non-commercial licenses do not cover use "in direct interactions with or that has impact on end users". The model is confirmed by a bake-off on about ten species before any app work depends on its output.

## Consequences

- At public launch the server limits how much is painted: Legendary and Rare-or-rarer cards automatically, others on request within a daily allowance.
- ComfyUI on the box must not be exposed beyond the tailnet: it listens on the tailnet address only. The art worker talks to it on the box, and pack builds reach it from the maintainer's Mac over the tailnet.
