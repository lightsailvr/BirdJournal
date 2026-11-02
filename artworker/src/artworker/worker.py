"""The art worker's loop (issues #68 and #69, ADR-0003): long-poll the queue, claim, paint (scene art, or photo art from
the birder's own photo), filter, upload, report.

Everything goes outward from the box: SQS, S3 and the API over HTTPS, ComfyUI on loopback. Nothing reaches in.

What happens to a message:

- **Painted**: the art goes to the art bucket at the job's own key, the API hears `ready`, the message is deleted.
- **Refused** (no reference bird, no bird in a photo-art photo, the content filter, no faithful painting, an unreadable
  photo): the API hears
  `failed` with the reason, the message is deleted, and the card offers Retry art.
- **Gone** (the job finished, expired or never existed): the message is deleted.
- **Not now** (ComfyUI down, the API or S3 not answering): the message is left. ComfyUI is checked before each poll,
  so while it is down no message is taken at all; one that fails mid-painting is left. It comes back after the queue's
  visibility timeout (or the shorter `retry_after` set here), and after five receives goes to the dead-letter queue;
  the job still fails as expired after 7 days, so the phone never waits forever.
"""

from __future__ import annotations

import io
import json
import logging
import threading
import time
from dataclasses import dataclass
from typing import Any

import requests
from botocore.exceptions import BotoCoreError, ClientError
from PIL import Image, UnidentifiedImageError

from artworker.api import Gone, Unavailable, WorkerApi
from artworker.content_filter import ContentFilter
from artworker.photo import NoBird, PhotoPainter
from artworker.scene import NoReference, ScenePainter, Unfaithful
from packbuilder.comfy import PaintingFailed

log = logging.getLogger("artworker")

RETRY_AFTER_SECONDS = 300
"""A job that couldn't be painted now (ComfyUI down) comes back after five minutes, not the queue's fifteen."""
CACHE_CONTROL = "public, max-age=31536000, immutable"
COMFY_DOWN_WAIT_SECONDS = 60
"""How often a worker whose ComfyUI is down looks again, without touching the queue."""


@dataclass(frozen=True)
class Outcome:
    """What became of one message: `painted`, `refused:<reason>`, `gone` or `later`."""

    result: str
    delete: bool


class Worker:
    def __init__(
        self,
        *,
        sqs: Any,
        s3: Any,
        queue_url: str,
        upload_bucket: str,
        art_bucket: str,
        api: WorkerApi,
        painter: ScenePainter,
        content_filter: ContentFilter,
        photo_painter: PhotoPainter | None = None,
    ):
        self.sqs, self.s3 = sqs, s3
        self.queue_url, self.upload_bucket, self.art_bucket = queue_url, upload_bucket, art_bucket
        self.api, self.painter, self.content_filter = api, painter, content_filter
        # Photo art paints on the same ComfyUI with the same cut-outs.
        self.photo_painter = photo_painter or PhotoPainter(painter.painter, painter.prompts)
        self.stopping = threading.Event()
        self._comfy_down = False

    def run(self) -> None:
        log.info("art worker polling %s", self.queue_url)
        while not self.stopping.is_set():
            try:
                if self.poll_when_ready() is None:
                    self.stopping.wait(COMFY_DOWN_WAIT_SECONDS)
            except (BotoCoreError, ClientError) as error:
                log.warning("couldn't reach the queue: %s; trying again in a minute", error)
                self.stopping.wait(60)

    def comfy_is_up(self) -> bool:
        """Whether the FLUX.3 ComfyUI answers at all. Checked before taking a message, so a ComfyUI that is restarting
        or crashed while this service runs never burns a job's five receives into the dead-letter queue."""
        try:
            self.painter.painter.client.http.get(f"{self.painter.painter.client.base_url}/system_stats", timeout=5)
        except requests.RequestException:
            return False
        return True

    def poll_when_ready(self, wait_seconds: int = 20) -> list[Outcome] | None:
        """One long poll if ComfyUI is up; None (no message taken) if it isn't."""
        if not self.comfy_is_up():
            if not self._comfy_down:
                log.warning("ComfyUI isn't answering; leaving the queue alone until it does")
            self._comfy_down = True
            return None
        if self._comfy_down:
            log.info("ComfyUI is back; polling again")
        self._comfy_down = False
        return self.poll_once(wait_seconds)

    def poll_once(self, wait_seconds: int = 20) -> list[Outcome]:
        messages = self.sqs.receive_message(
            QueueUrl=self.queue_url, MaxNumberOfMessages=1, WaitTimeSeconds=wait_seconds
        ).get("Messages", [])
        outcomes = []
        for message in messages:
            outcome = self.handle(message["Body"])
            log.info("message %s: %s", message["MessageId"], outcome.result)
            if outcome.delete:
                self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=message["ReceiptHandle"])
            else:
                self.sqs.change_message_visibility(
                    QueueUrl=self.queue_url, ReceiptHandle=message["ReceiptHandle"], VisibilityTimeout=RETRY_AFTER_SECONDS
                )
            outcomes.append(outcome)
        return outcomes

    def handle(self, body: str) -> Outcome:
        try:
            message = json.loads(body)
            owner, job_id = str(message["owner"]), str(message["job_id"])
        except (ValueError, KeyError, TypeError):
            log.error("an unreadable message, dropped: %r", body[:200])
            return Outcome("gone", delete=True)
        try:
            return self._paint(owner, job_id)
        except Gone as error:
            log.info("job %s: nothing to do (%s)", job_id, error)
            return Outcome("gone", delete=True)
        except Unavailable as error:
            log.warning("job %s: the API isn't answering (%s); later", job_id, error)
            return Outcome("later", delete=False)

    def _paint(self, owner: str, job_id: str) -> Outcome:
        claim = self.api.claim(owner, job_id)
        started = time.monotonic()
        try:
            photo = self.s3.get_object(Bucket=self.upload_bucket, Key=claim.input_key)["Body"].read()
        except ClientError as error:
            if error.response["Error"]["Code"] in ("NoSuchKey", "404", "AccessDenied", "403"):
                return self._refuse(owner, job_id, "bad_input", f"no photo at {claim.input_key}")
            log.warning("job %s: couldn't read the photo (%s); later", job_id, error)
            return Outcome("later", delete=False)
        except BotoCoreError as error:
            log.warning("job %s: couldn't reach S3 (%s); later", job_id, error)
            return Outcome("later", delete=False)
        try:
            if claim.kind == "photo":
                art = self.photo_painter.paint(claim.id, photo, claim.scientific_name, claim.edition, claim.legendary)
            else:
                art = self.painter.paint(claim.id, photo, claim.scientific_name, claim.edition, claim.legendary)
        except NoBird:
            return self._refuse(owner, job_id, "no_bird", "no bird to paint in the birder's photo")
        except NoReference:
            return self._refuse(owner, job_id, "no_reference", f"no reference bird for {claim.scientific_name}")
        except Unfaithful as error:
            return self._refuse(owner, job_id, "painting_failed", str(error))
        except UnidentifiedImageError:
            return self._refuse(owner, job_id, "bad_input", "the photo isn't an image")
        except (PaintingFailed, requests.RequestException) as error:
            log.warning("job %s: ComfyUI couldn't paint (%s); later", job_id, error)
            return Outcome("later", delete=False)
        except ValueError as error:  # no bird to measure in any painting
            return self._refuse(owner, job_id, "painting_failed", str(error))
        if not self.content_filter.allows(Image.open(io.BytesIO(art.jpeg))):
            return self._refuse(owner, job_id, "filtered", "the content filter refused the painting")
        try:
            self.s3.put_object(
                Bucket=self.art_bucket, Key=claim.output_key, Body=art.jpeg, ContentType="image/jpeg", CacheControl=CACHE_CONTROL
            )
        except (BotoCoreError, ClientError) as error:
            log.warning("job %s: couldn't upload the painting (%s); later", job_id, error)
            return Outcome("later", delete=False)
        self.api.ready(claim, art.provenance)
        log.info("job %s painted in %.0f s: %s", job_id, time.monotonic() - started, art.provenance)
        return Outcome("painted", delete=True)

    def _refuse(self, owner: str, job_id: str, reason: str, why: str) -> Outcome:
        log.warning("job %s failed (%s): %s", job_id, reason, why)
        self.api.failed(owner, job_id, reason)
        return Outcome(f"refused:{reason}", delete=True)
