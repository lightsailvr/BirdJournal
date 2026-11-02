# Art worker

BirdJournal's art worker (issue #68, ADR-0003): a Python service on comfybox that paints **scene art**, the species
painted into the glasses photo from an add, on the FLUX.3 ComfyUI (port 8189, loopback; `art/README.md`).

It long-polls the art queue (SQS) as the `birdjournal-art-worker` IAM user, which may only consume that queue, read
`uploads/` in the upload bucket and write `art/` in the art bucket. For each job it:

1. claims the job from the API with its worker token (`POST /internal/art/jobs/<owner>/<id>/claim`);
2. reads the phone's photo (faces already blurred and metadata stripped on the phone);
3. paints it with the committed `scene-art` workflow and `prompts.json` (the Legendary light for a Legendary card),
   from the species' isolated reference bird and a telephoto crop of the photo sized by the bird's length, through
   the fidelity gate (ΔE ≤ 10 and IoU ≥ 0.65 against the reference bird after the colour fit, three seeds at most);
   no prompt names the species;
4. runs the content filter (Falconsai/nsfw_image_detection, Apache 2.0, ONNX; ADR-0007);
5. uploads the JPEG to the art bucket at the job's unguessable key and reports `ready`, or reports `failed` with a
   reason (`no_reference`, `painting_failed`, `filtered`, `bad_input`).

With ComfyUI down it leaves the message for later; the job fails as expired after 7 days in the queue either way.

## Layout

- `src/artworker/`: `scene.py` (the painting, over `packbuilder.art`, `packbuilder.painting` and
  `packbuilder.fidelity`), `content_filter.py`, `api.py`, `worker.py` (the loop) and `__main__.py` (settings from the
  environment; `python -m artworker --help` lists them).
- `comfybox/`: the systemd unit, `deploy-to-comfybox.sh` (copies the worker, the reference birds and the filter to the
  box from the Mac) and `install-artworker-service.sh` (with sudo on the box).
- `scripts/download-filter.sh`: the content filter's ONNX file, revision- and SHA-256-pinned.

The reference birds come from the pack builds: `packbuilder art-references packs/<id> --pack ../packs/<id> --out
../build/art-references/<id>` copies each approved species' isolated bird from the build cache with its length.

## Running it

`infra/scripts/art-wizard.sh` does it all once the maintainer gives the go-ahead: the references, the deploy, the
worker's access key and settings written straight to the box (`~/birdjournal-art/artworker.env`, mode 600), the copy
and the service. On the box: `journalctl -fu birdjournal-artworker`.

## Tests

```sh
cd artworker && uv run pytest
```

Against packbuilder's stub ComfyUI (it paints from its inputs, so the fidelity gate passes), a local queue and buckets
(moto, in process) and a stub of the API's worker routes. `tests/test_content_filter.py` runs the real filter when
`scripts/download-filter.sh` has fetched it, and skips otherwise.
