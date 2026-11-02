"""`python -m artworker`: the art worker, configured from the environment (the service's EnvironmentFile).

    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   the birdjournal-art-worker IAM user's key (the art wizard makes it)
    AWS_REGION                                 us-west-2
    ART_QUEUE_URL, ART_UPLOAD_BUCKET, ART_BUCKET   the stack's outputs ArtQueueUrl, ArtUploadBucket, ArtBucket
    ART_API_URL                                the stack's ApiUrl
    ART_WORKER_TOKEN                           the secret birdjournal/art-worker-token
    COMFY_URL                                  the FLUX.3 ComfyUI on the box (default http://127.0.0.1:8189)
    ART_REFERENCES                             the reference birds, one folder per pack (`packbuilder art-references`)
    ART_FILTER_MODEL                           the content filter's ONNX file (scripts/download-filter.sh)
    ART_CACHE                                  where reference cut-outs are kept between jobs
"""

from __future__ import annotations

import logging
import os
import signal
import sys
from pathlib import Path

import boto3

from artworker.api import WorkerApi
from artworker.content_filter import NsfwFilter
from artworker.scene import References, ScenePainter
from artworker.worker import Worker
from packbuilder.comfy import ComfyClient


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is not set (see `python -m artworker --help`)")
    return value


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    region = os.environ.get("AWS_REGION", "us-west-2")
    references = References(Path(_require("ART_REFERENCES")))
    if not references.by_pack:
        raise SystemExit("ART_REFERENCES has no references.json: export them with `packbuilder art-references`")
    cache = Path(os.environ.get("ART_CACHE", Path.home() / "birdjournal-art" / "cache"))
    worker = Worker(
        sqs=boto3.client("sqs", region_name=region),
        s3=boto3.client("s3", region_name=region),
        queue_url=_require("ART_QUEUE_URL"),
        upload_bucket=_require("ART_UPLOAD_BUCKET"),
        art_bucket=_require("ART_BUCKET"),
        api=WorkerApi(_require("ART_API_URL"), _require("ART_WORKER_TOKEN")),
        painter=ScenePainter(ComfyClient(os.environ.get("COMFY_URL", "http://127.0.0.1:8189")), references, cutouts=cache / "cutouts"),
        content_filter=NsfwFilter(Path(_require("ART_FILTER_MODEL"))),
    )
    signal.signal(signal.SIGTERM, lambda *_: worker.stopping.set())
    logging.getLogger("artworker").info("reference birds: %s", {pack: len(birds) for pack, birds in references.by_pack.items()})
    worker.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
