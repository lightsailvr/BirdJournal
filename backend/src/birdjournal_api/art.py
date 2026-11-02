"""Art jobs (issue #68, ADR-0003): scene art painted on comfybox from a glasses photo.

The lifecycle:

1. The phone creates a job (its own UUID, so a repeated create is the same job) for a sighting it identifies by the
   sighting's UUID. The auto-paint rule decides first, so a photo is never uploaded for a job the server would refuse.
   The job starts `awaiting_upload`, with a presigned PUT for `uploads/<sub>/<job id>.jpg` in the private upload
   bucket (objects expire after a day).
2. The phone uploads the photo (faces blurred, metadata stripped) and submits: the job is `queued` and goes on SQS.
3. The art worker claims it (`painting`; a redelivered message claims it again), paints, uploads to the art bucket at
   the key the job was given (`art/<sub>/<unguessable>.jpg`) and reports `ready`, or `failed` with a reason. Either way
   the upload is deleted.
4. The phone learns of it by polling its open jobs (a silent push joins with #63's device tokens), downloads the art
   and says it has it (`received`). Painted art is then deleted from the art bucket unless a find shows it (#70).

A job not finished within 7 days of being queued (or created, if it never was) fails with `expired`; the phone offers
Retry art. A retry is a new job for the same sighting: the server never touches the sighting, which lives on the phone
only (ADR-0004), and the phone keeps the last art until the new job is ready.

Items, beside the account's (tables.py): `ACCOUNT#<sub>` / `ARTJOB#<id>`, one per job, so a birder's jobs are one
query and the worker, whose queue message names the owner, finds a job by key. `ttl` removes a job 30 days after the
phone received its result.
"""

from __future__ import annotations

import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Literal, Protocol

from botocore.exceptions import ClientError

JOB_LIFETIME = timedelta(days=7)
KEPT_AFTER_RECEIVED = timedelta(days=30)
UPLOAD_URL_LIFETIME = timedelta(hours=1)

State = Literal["awaiting_upload", "queued", "painting", "ready", "failed"]
OPEN_STATES = ("awaiting_upload", "queued", "painting")
AutoPaintRule = Literal["every_glasses_add", "legendary_or_rare"]
RARE_LABELS = ("rare", "exceptional")


class ArtError(Exception):
    """A refused art operation; the API maps each subclass to a status."""


class NotFound(ArtError):
    pass


class NotEligible(ArtError):
    """The auto-paint rule doesn't paint this add."""


class UploadMissing(ArtError):
    """Submitted before the photo arrived."""


class WrongState(ArtError):
    """The job isn't in a state that allows this (a claim of a finished job, a report on one never claimed)."""


class Expired(ArtError):
    """Claimed after its 7 days: it has just failed with `expired`."""


class WrongOutput(ArtError):
    """The worker reported art at a key other than the job's."""


class ArtStorage(Protocol):
    """The two buckets, as the API uses them."""

    def upload_url(self, key: str, expires_in: timedelta) -> str: ...
    def has_upload(self, key: str) -> bool: ...
    def delete_upload(self, key: str) -> None: ...
    def delete_art(self, key: str) -> None: ...


class ArtQueue(Protocol):
    def send(self, owner: str, job_id: str) -> None: ...


class ArtNotifier(Protocol):
    """Tells the phone a job finished. The silent push needs device tokens, which #63 registers; until then the phone
    polls its open jobs."""

    def job_finished(self, job: ArtJob) -> None: ...


class ArtRetention(Protocol):
    """Whether something shared still shows a painting (a find, #70, or a shared card, #66), so it must stay."""

    def is_shown(self, owner: str, key: str) -> bool: ...


class NoNotifier:
    def job_finished(self, job: ArtJob) -> None:
        return None


class NothingShared:
    """Until finds carry painted art (#70), nothing on the server shows it, so it goes once the phone has it."""

    def is_shown(self, owner: str, key: str) -> bool:
        return False


def may_auto_paint(rule: AutoPaintRule, *, legendary: bool, rarity: str | None, requested: bool) -> bool:
    """The auto-paint rule (server configuration, `ART_AUTO_PAINT`). Friends phase: every add with a glasses photo.
    Public launch: Legendary and Rare-or-rarer adds; others only on request (Try again, Retry art), whose daily
    allowance comes with #69."""
    if rule == "every_glasses_add" or requested:
        return True
    return legendary or rarity in RARE_LABELS


@dataclass(frozen=True)
class ArtJob:
    id: str
    owner: str
    sighting_id: str
    kind: str
    scientific_name: str
    edition: str | None
    legendary: bool
    state: State
    created_at: datetime
    input_key: str
    output_key: str
    attempts: int = 0
    queued_at: datetime | None = None
    finished_at: datetime | None = None
    received_at: datetime | None = None
    failure: str | None = None
    provenance: str | None = None

    @property
    def deadline(self) -> datetime:
        return (self.queued_at or self.created_at) + JOB_LIFETIME


@dataclass(frozen=True)
class NewJob:
    id: str
    sighting_id: str
    kind: str
    scientific_name: str
    edition: str | None
    legendary: bool
    rarity: str | None
    requested: bool


class ArtJobStore:
    def __init__(
        self,
        table: Any,
        clock: Callable[[], datetime],
        *,
        rule: AutoPaintRule,
        storage: ArtStorage | None,
        queue: ArtQueue | None,
        notifier: ArtNotifier,
        retention: ArtRetention,
    ) -> None:
        self._table = table
        self._clock = clock
        self.rule = rule
        self._storage = storage
        self._queue = queue
        self._notifier = notifier
        self._retention = retention

    @property
    def storage(self) -> ArtStorage:
        if self._storage is None:
            raise RuntimeError("UPLOAD_BUCKET and ART_BUCKET are not set")
        return self._storage

    # The phone.

    def create(self, owner: str, new: NewJob) -> tuple[ArtJob, bool]:
        """The job, created unless one with this id exists (then returned as it is); and whether it was created."""
        if existing := self._read(owner, new.id):
            return self._expire_if_due(existing), False
        if not may_auto_paint(self.rule, legendary=new.legendary, rarity=new.rarity, requested=new.requested):
            raise NotEligible()
        now = self._clock()
        item = {
            **_key(owner, new.id),
            "sighting_id": new.sighting_id,
            "kind": new.kind,
            "scientific_name": new.scientific_name,
            "legendary": new.legendary,
            "state": "awaiting_upload",
            "created_at": now.isoformat(),
            "input_key": f"uploads/{owner}/{new.id}.jpg",
            "output_key": f"art/{owner}/{secrets.token_urlsafe(24)}.jpg",
            "attempts": 0,
        }
        if new.edition:
            item["edition"] = new.edition
        if new.rarity:
            item["rarity"] = new.rarity
        try:
            self._table.put_item(Item=item, ConditionExpression="attribute_not_exists(pk)")
        except ClientError as error:
            if not _conditional(error):
                raise
            # The same create, racing itself (a retried request).
            return self._job(self._table.get_item(Key=_key(owner, new.id), ConsistentRead=True)["Item"]), False
        return self._job(item), True

    def upload_url(self, job: ArtJob) -> tuple[str, datetime]:
        return self.storage.upload_url(job.input_key, UPLOAD_URL_LIFETIME), self._clock() + UPLOAD_URL_LIFETIME

    def submit(self, owner: str, job_id: str) -> ArtJob:
        """Queues a job whose photo has arrived. Submitting again changes nothing and queues nothing."""
        job = self.get(owner, job_id)
        if job.state != "awaiting_upload":
            return job
        if not self.storage.has_upload(job.input_key):
            raise UploadMissing()
        now = self._clock()
        try:
            item = self._table.update_item(
                Key=_key(owner, job_id),
                UpdateExpression="SET #state = :queued, queued_at = :now",
                ConditionExpression="#state = :awaiting",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={":queued": "queued", ":awaiting": "awaiting_upload", ":now": now.isoformat()},
                ReturnValues="ALL_NEW",
            )["Attributes"]
        except ClientError as error:
            if not _conditional(error):
                raise
            return self.get(owner, job_id)
        if self._queue is None:
            raise RuntimeError("ART_QUEUE_URL is not set")
        self._queue.send(owner, job_id)
        return self._job(item)

    def get(self, owner: str, job_id: str) -> ArtJob:
        job = self._read(owner, job_id)
        if job is None:
            raise NotFound()
        return self._expire_if_due(job)

    def open_jobs(self, owner: str) -> list[ArtJob]:
        """Every job whose result the phone hasn't said it has: waiting, painting, or finished but not received."""
        items: list[dict[str, Any]] = []
        query: dict[str, Any] = {
            "KeyConditionExpression": "pk = :pk AND begins_with(sk, :prefix)",
            "FilterExpression": "attribute_not_exists(received_at)",
            "ExpressionAttributeValues": {":pk": f"ACCOUNT#{owner}", ":prefix": "ARTJOB#"},
            "ConsistentRead": True,
        }
        while True:
            page = self._table.query(**query)
            items += page["Items"]
            if "LastEvaluatedKey" not in page:
                break
            query["ExclusiveStartKey"] = page["LastEvaluatedKey"]
        jobs = [self._expire_if_due(self._job(item)) for item in items]
        return sorted(jobs, key=lambda job: job.created_at)

    def received(self, owner: str, job_id: str) -> ArtJob:
        """The phone has stored the result. Painted art leaves the art bucket unless something shared shows it."""
        job = self.get(owner, job_id)
        if job.state not in ("ready", "failed"):
            raise WrongState()
        if job.received_at is not None:
            return job
        if job.state == "ready" and not self._retention.is_shown(owner, job.output_key):
            self.storage.delete_art(job.output_key)
        now = self._clock()
        item = self._table.update_item(
            Key=_key(owner, job_id),
            UpdateExpression="SET received_at = :now, #ttl = :ttl",
            ExpressionAttributeNames={"#ttl": "ttl"},
            ExpressionAttributeValues={":now": now.isoformat(), ":ttl": int((now + KEPT_AFTER_RECEIVED).timestamp())},
            ReturnValues="ALL_NEW",
        )["Attributes"]
        return self._job(item)

    # The worker.

    def claim(self, owner: str, job_id: str) -> ArtJob:
        """The worker takes a queued job, or takes back one it was painting (SQS redelivered the message)."""
        job = self._read(owner, job_id)
        if job is None:
            raise NotFound()
        if self._expire_if_due(job).state == "failed" and job.state != "failed":
            raise Expired()
        if job.state not in ("queued", "painting"):
            raise WrongState()
        try:
            item = self._table.update_item(
                Key=_key(owner, job_id),
                UpdateExpression="SET #state = :painting, claimed_at = :now ADD attempts :one",
                ConditionExpression="#state IN (:queued, :painting)",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={
                    ":painting": "painting", ":queued": "queued", ":now": self._clock().isoformat(), ":one": 1,
                },
                ReturnValues="ALL_NEW",
            )["Attributes"]
        except ClientError as error:
            if not _conditional(error):
                raise
            raise WrongState() from error
        return self._job(item)

    def ready(self, owner: str, job_id: str, *, output_key: str, provenance: str | None) -> ArtJob:
        job = self._read(owner, job_id)
        if job is None:
            raise NotFound()
        if output_key != job.output_key:
            raise WrongOutput()
        if job.state == "ready":
            return job
        updated = self._finish(job, "ready", {"provenance": provenance} if provenance else {})
        return updated

    def failed(self, owner: str, job_id: str, *, reason: str) -> ArtJob:
        job = self._read(owner, job_id)
        if job is None:
            raise NotFound()
        if job.state == "failed":
            return job
        return self._finish(job, "failed", {"failure": reason})

    # Internals.

    def _finish(self, job: ArtJob, state: State, extra: dict[str, Any]) -> ArtJob:
        names = {"#state": "state", **{f"#{name}": name for name in extra}}
        values = {
            ":state": state, ":now": self._clock().isoformat(), ":queued": "queued", ":painting": "painting",
            **{f":{name}": value for name, value in extra.items()},
        }
        sets = ", ".join(["#state = :state", "finished_at = :now", *(f"#{name} = :{name}" for name in extra)])
        try:
            item = self._table.update_item(
                Key=_key(job.owner, job.id),
                UpdateExpression=f"SET {sets}",
                # A report only ends a job that was queued or being painted (a failure may come before a claim: the
                # worker drops a message it can't read).
                ConditionExpression="#state IN (:queued, :painting)",
                ExpressionAttributeNames=names,
                ExpressionAttributeValues=values,
                ReturnValues="ALL_NEW",
            )["Attributes"]
        except ClientError as error:
            if not _conditional(error):
                raise
            raise WrongState() from error
        finished = self._job(item)
        if self._storage is not None:
            self._storage.delete_upload(job.input_key)
        self._notifier.job_finished(finished)
        return finished

    def _expire_if_due(self, job: ArtJob) -> ArtJob:
        if job.state not in OPEN_STATES or self._clock() < job.deadline:
            return job
        try:
            item = self._table.update_item(
                Key=_key(job.owner, job.id),
                UpdateExpression="SET #state = :failed, failure = :expired, finished_at = :now",
                ConditionExpression="#state = :was",
                ExpressionAttributeNames={"#state": "state"},
                ExpressionAttributeValues={
                    ":failed": "failed", ":expired": "expired", ":now": self._clock().isoformat(), ":was": job.state,
                },
                ReturnValues="ALL_NEW",
            )["Attributes"]
        except ClientError as error:
            if not _conditional(error):
                raise
            # Something else moved it on first; read what it is now.
            return self._read(job.owner, job.id) or job
        expired = self._job(item)
        if self._storage is not None:
            self._storage.delete_upload(job.input_key)
        self._notifier.job_finished(expired)
        return expired

    def _read(self, owner: str, job_id: str) -> ArtJob | None:
        item = self._table.get_item(Key=_key(owner, job_id), ConsistentRead=True).get("Item")
        return self._job(item) if item else None

    @staticmethod
    def _job(item: dict[str, Any]) -> ArtJob:
        def moment(name: str) -> datetime | None:
            value = item.get(name)
            return datetime.fromisoformat(value) if value else None

        return ArtJob(
            id=item["sk"].removeprefix("ARTJOB#"),
            owner=item["pk"].removeprefix("ACCOUNT#"),
            sighting_id=item["sighting_id"],
            kind=item["kind"],
            scientific_name=item["scientific_name"],
            edition=item.get("edition"),
            legendary=bool(item.get("legendary", False)),
            state=item["state"],
            created_at=datetime.fromisoformat(item["created_at"]),
            input_key=item["input_key"],
            output_key=item["output_key"],
            attempts=int(item.get("attempts", 0)),
            queued_at=moment("queued_at"),
            finished_at=moment("finished_at"),
            received_at=moment("received_at"),
            failure=item.get("failure"),
            provenance=item.get("provenance"),
        )


def _key(owner: str, job_id: str) -> dict[str, str]:
    return {"pk": f"ACCOUNT#{owner}", "sk": f"ARTJOB#{job_id}"}


def _conditional(error: ClientError) -> bool:
    return error.response["Error"]["Code"] == "ConditionalCheckFailedException"


# The real adapters.


class S3ArtStorage:
    def __init__(self, s3: Any, *, upload_bucket: str, art_bucket: str) -> None:
        self._s3 = s3
        self._uploads = upload_bucket
        self._art = art_bucket

    def upload_url(self, key: str, expires_in: timedelta) -> str:
        url: str = self._s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": self._uploads, "Key": key, "ContentType": "image/jpeg"},
            ExpiresIn=int(expires_in.total_seconds()),
        )
        return url

    def has_upload(self, key: str) -> bool:
        try:
            self._s3.head_object(Bucket=self._uploads, Key=key)
        except ClientError as error:
            # Without s3:ListBucket a missing key answers 403, not 404.
            if error.response["Error"]["Code"] in ("404", "403", "NoSuchKey", "NotFound", "Forbidden"):
                return False
            raise
        return True

    def delete_upload(self, key: str) -> None:
        self._s3.delete_object(Bucket=self._uploads, Key=key)

    def delete_art(self, key: str) -> None:
        self._s3.delete_object(Bucket=self._art, Key=key)


class SqsArtQueue:
    def __init__(self, sqs: Any, queue_url: str) -> None:
        self._sqs = sqs
        self._url = queue_url

    def send(self, owner: str, job_id: str) -> None:
        import json

        self._sqs.send_message(QueueUrl=self._url, MessageBody=json.dumps({"owner": owner, "job_id": job_id}))


class WorkerToken:
    """The art worker's token: given directly (tests, local runs) or read once from Secrets Manager."""

    def __init__(self, *, value: str | None = None, secret_id: str | None = None, secrets_client: Any = None) -> None:
        self._value = value
        self._secret_id = secret_id
        self._client = secrets_client
        self._read_at = 0.0

    def matches(self, presented: str) -> bool:
        expected = self._current()
        return bool(expected) and secrets.compare_digest(presented.encode(), expected.encode())

    def _current(self) -> str | None:
        # Re-read now and then, so a rotated token takes without a redeploy.
        if self._secret_id and (self._value is None or time.monotonic() - self._read_at > 3600):
            self._value = self._client.get_secret_value(SecretId=self._secret_id)["SecretString"]
            self._read_at = time.monotonic()
        return self._value
