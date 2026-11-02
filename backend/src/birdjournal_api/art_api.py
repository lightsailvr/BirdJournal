"""The art job routes (issue #68): the phone's (create, submit, read, list open, received) with the account's access
token, and the art worker's (claim, ready, failed) with the worker token."""

from datetime import UTC, datetime
from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_serializer

from birdjournal_api.art import (
    ArtJob,
    ArtJobStore,
    Expired,
    NewJob,
    NotEligible,
    NotFound,
    UploadExpired,
    UploadMissing,
    WorkerToken,
    WrongOutput,
    WrongState,
)
from birdjournal_api.auth import Subject


def _utc(value: datetime | None) -> str | None:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z") if value else None


class UploadResponse(BaseModel):
    url: str
    method: Literal["PUT"] = "PUT"
    # Sent with the PUT exactly as given: the URL is signed for them.
    headers: dict[str, str]
    expires_at: datetime

    @field_serializer("expires_at")
    def _expires(self, value: datetime) -> str | None:
        return _utc(value)


class JobResponse(BaseModel):
    id: str
    sighting_id: str
    kind: str
    state: str
    legendary: bool
    created_at: datetime
    queued_at: datetime | None
    finished_at: datetime | None
    # When the job fails if it isn't done: 7 days after it was queued.
    expires_at: datetime
    # The painted art on the art CDN, once ready and until the phone says it has it.
    art_url: str | None
    # Why it failed: "expired", "filtered" (the content filter), "no_reference", "painting_failed".
    failure: str | None
    provenance: str | None
    received: bool
    upload: UploadResponse | None = None

    @field_serializer("created_at", "queued_at", "finished_at", "expires_at")
    def _moments(self, value: datetime | None) -> str | None:
        return _utc(value)

    @classmethod
    def of(cls, job: ArtJob, cdn: str, upload: UploadResponse | None = None) -> "JobResponse":
        return cls(
            id=job.id,
            sighting_id=job.sighting_id,
            kind=job.kind,
            state=job.state,
            legendary=job.legendary,
            created_at=job.created_at,
            queued_at=job.queued_at,
            finished_at=job.finished_at,
            expires_at=job.deadline,
            art_url=f"{cdn}/{job.output_key}" if job.state == "ready" and job.received_at is None else None,
            failure=job.failure,
            provenance=job.provenance,
            received=job.received_at is not None,
            upload=upload,
        )


class JobList(BaseModel):
    jobs: list[JobResponse]


class JobCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # Made on the phone, so a create repeated after a lost response is the same job.
    id: UUID
    sighting_id: UUID
    # Photo art comes with #69.
    kind: Literal["scene"]
    scientific_name: str = Field(min_length=1, max_length=120)
    # The pack id of the card's set, whose edition lights the painting; None outside every set.
    edition: str | None = Field(default=None, max_length=60)
    legendary: bool = False
    rarity: Literal["common", "uncommon", "rare", "exceptional"] | None = None
    # The birder asked (Try again, Retry art), rather than the add.
    requested: bool = False


class WorkerClaim(BaseModel):
    id: str
    owner: str
    kind: str
    scientific_name: str
    edition: str | None
    legendary: bool
    input_key: str
    output_key: str
    attempt: int


class WorkerReady(BaseModel):
    model_config = ConfigDict(extra="forbid")

    output_key: str
    # The model, workflow and prompts that painted it, and its fidelity, for the record.
    provenance: str | None = Field(default=None, max_length=500)


class WorkerFailed(BaseModel):
    model_config = ConfigDict(extra="forbid")

    reason: Literal["filtered", "no_reference", "painting_failed", "bad_input"]


def _store(request: Request) -> ArtJobStore:
    store: ArtJobStore | None = request.app.state.art_jobs
    if store is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "art_unavailable")
    return store


def _cdn(request: Request) -> str:
    base: str = request.app.state.art_cdn_base_url
    return base


Jobs = Annotated[ArtJobStore, Depends(_store)]
Cdn = Annotated[str, Depends(_cdn)]


def _worker(request: Request, authorization: Annotated[str | None, Header()] = None) -> None:
    token: WorkerToken | None = request.app.state.worker_token
    scheme, _, presented = (authorization or "").partition(" ")
    if token is None or scheme.lower() != "bearer" or not presented or not token.matches(presented):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "worker_token", headers={"WWW-Authenticate": "Bearer"})


Worker = Annotated[None, Depends(_worker)]


def _refused(error: Exception) -> HTTPException:
    match error:
        case NotFound():
            return HTTPException(status.HTTP_404_NOT_FOUND, "not_found")
        case NotEligible():
            return HTTPException(status.HTTP_409_CONFLICT, "not_eligible")
        case UploadExpired():
            return HTTPException(status.HTTP_409_CONFLICT, "upload_expired")
        case UploadMissing():
            return HTTPException(status.HTTP_409_CONFLICT, "upload_missing")
        case WrongOutput():
            return HTTPException(status.HTTP_409_CONFLICT, "wrong_output")
        case Expired():
            return HTTPException(status.HTTP_410_GONE, "expired")
        case WrongState():
            return HTTPException(status.HTTP_409_CONFLICT, "wrong_state")
    raise error


router = APIRouter()


@router.post("/v1/art/jobs", status_code=status.HTTP_201_CREATED)
def create_job(subject: Subject, body: JobCreate, jobs: Jobs, cdn: Cdn, response: Response) -> JobResponse:
    new = NewJob(
        id=str(body.id),
        sighting_id=str(body.sighting_id),
        kind=body.kind,
        scientific_name=body.scientific_name,
        edition=body.edition,
        legendary=body.legendary,
        rarity=body.rarity,
        requested=body.requested,
    )
    try:
        job, created = jobs.create(subject, new)
    except Exception as error:
        raise _refused(error) from error
    if not created:
        response.status_code = status.HTTP_200_OK
    upload = None
    if job.state == "awaiting_upload":
        url, expires_at = jobs.upload_url(job)
        upload = UploadResponse(url=url, headers={"Content-Type": "image/jpeg"}, expires_at=expires_at)
    return JobResponse.of(job, cdn, upload)


@router.post("/v1/art/jobs/{job_id}/submit")
def submit_job(subject: Subject, job_id: str, jobs: Jobs, cdn: Cdn) -> JobResponse:
    try:
        return JobResponse.of(jobs.submit(subject, job_id), cdn)
    except Exception as error:
        raise _refused(error) from error


@router.get("/v1/art/jobs")
def list_open_jobs(subject: Subject, jobs: Jobs, cdn: Cdn) -> JobList:
    return JobList(jobs=[JobResponse.of(job, cdn) for job in jobs.open_jobs(subject)])


@router.get("/v1/art/jobs/{job_id}")
def get_job(subject: Subject, job_id: str, jobs: Jobs, cdn: Cdn) -> JobResponse:
    try:
        return JobResponse.of(jobs.get(subject, job_id), cdn)
    except Exception as error:
        raise _refused(error) from error


@router.post("/v1/art/jobs/{job_id}/received")
def received_job(subject: Subject, job_id: str, jobs: Jobs, cdn: Cdn) -> JobResponse:
    try:
        return JobResponse.of(jobs.received(subject, job_id), cdn)
    except Exception as error:
        raise _refused(error) from error


# The art worker on comfybox. The owner is in the path because the queue message names it.


@router.post("/internal/art/jobs/{owner}/{job_id}/claim")
def claim_job(_: Worker, owner: str, job_id: str, jobs: Jobs) -> WorkerClaim:
    try:
        job = jobs.claim(owner, job_id)
    except Exception as error:
        raise _refused(error) from error
    return WorkerClaim(
        id=job.id,
        owner=job.owner,
        kind=job.kind,
        scientific_name=job.scientific_name,
        edition=job.edition,
        legendary=job.legendary,
        input_key=job.input_key,
        output_key=job.output_key,
        attempt=job.attempts,
    )


@router.post("/internal/art/jobs/{owner}/{job_id}/ready")
def job_ready(_: Worker, owner: str, job_id: str, body: WorkerReady, jobs: Jobs) -> dict[str, str]:
    try:
        job = jobs.ready(owner, job_id, output_key=body.output_key, provenance=body.provenance)
    except Exception as error:
        raise _refused(error) from error
    return {"state": job.state}


@router.post("/internal/art/jobs/{owner}/{job_id}/failed")
def job_failed(_: Worker, owner: str, job_id: str, body: WorkerFailed, jobs: Jobs) -> dict[str, str]:
    try:
        job = jobs.failed(owner, job_id, reason=body.reason)
    except Exception as error:
        raise _refused(error) from error
    return {"state": job.state}
