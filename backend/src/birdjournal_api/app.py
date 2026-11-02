"""The API: account get and update (issue #60), circles (issue #61), finds (issue #62) with shared cards (issue #66),
art jobs (issue #68) and pushes (issue #63). Later tickets add their routers here."""

import logging
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated

import boto3
from botocore.config import Config
from fastapi import Depends, FastAPI, Request
from pydantic import BaseModel, ConfigDict, field_serializer, field_validator

from birdjournal_api.accounts import Account, AccountStore, clean_display_name
from birdjournal_api.apns import ApnsSender, DisabledSender, secrets_manager_credentials
from birdjournal_api.art import (
    ArtJobStore,
    ArtNotifier,
    ArtQueue,
    ArtRetention,
    ArtStorage,
    NoNotifier,
    NothingShared,
    S3ArtStorage,
    SqsArtQueue,
    WorkerToken,
)
from birdjournal_api.art_api import router as art_router
from birdjournal_api.auth import (
    SigningKeyResolver,
    Subject,
    TokenVerifier,
    cognito_signing_keys,
)
from birdjournal_api.circles import CircleStore
from birdjournal_api.circles_api import router as circles_router
from birdjournal_api.finds import FindStore
from birdjournal_api.devices import DeviceStore, MuteStore
from birdjournal_api.finds_api import router as finds_router
from birdjournal_api.photos import PhotoStore, S3PhotoStore
from birdjournal_api.pushes import PushSender, PushService
from birdjournal_api.pushes_api import router as pushes_router
from birdjournal_api.settings import Settings

logging.getLogger().setLevel(logging.INFO)

# Presigned upload URLs must be SigV4 on the bucket's own regional host.
S3_CONFIG = Config(signature_version="s3v4", s3={"addressing_style": "virtual"})


class AccountResponse(BaseModel):
    id: str
    display_name: str | None
    created_at: datetime

    @field_serializer("created_at")
    def _utc(self, value: datetime) -> str:
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")

    @classmethod
    def of(cls, account: Account) -> "AccountResponse":
        return cls(id=account.id, display_name=account.display_name, created_at=account.created_at)


class AccountUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    display_name: str

    @field_validator("display_name")
    @classmethod
    def _clean(cls, value: str) -> str:
        return clean_display_name(value)


def create_app(
    settings: Settings,
    *,
    signing_key: SigningKeyResolver | None = None,
    clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    art_storage: ArtStorage | None = None,
    art_queue: ArtQueue | None = None,
    art_notifier: ArtNotifier | None = None,
    art_retention: ArtRetention | None = None,
    photos: PhotoStore | None = None,
    push_sender: PushSender | None = None,
) -> FastAPI:
    """The API over the settings' table. Tests pass a signing key from their own issuer, a clock, and fakes for the art
    buckets, queue and notifier, the shared photos and APNs; otherwise shared cards' photos go to the art bucket, when
    the stack has one."""
    dynamodb = boto3.resource("dynamodb", region_name=settings.region, endpoint_url=settings.dynamodb_endpoint)
    app = FastAPI(title="BirdJournal API")
    app.state.verifier = TokenVerifier(
        issuer=settings.cognito_issuer,
        client_ids=settings.cognito_client_ids,
        signing_key=signing_key or cognito_signing_keys(settings.cognito_issuer),
    )
    app.state.accounts = AccountStore(dynamodb.Table(settings.table_name), clock)
    app.state.circles = CircleStore(dynamodb, settings.table_name, app.state.accounts, clock)
    if photos is None and settings.art_bucket is not None:
        photos = S3PhotoStore(boto3.client("s3", region_name=settings.region), settings.art_bucket)
    app.state.photos = photos
    app.state.clock = clock
    app.state.finds = FindStore(dynamodb, settings.table_name, app.state.accounts, app.state.circles, clock, photos)
    table = dynamodb.Table(settings.table_name)
    app.state.devices = DeviceStore(table, clock)
    app.state.mutes = MuteStore(table, clock)
    app.state.pushes = PushService(
        table, app.state.circles, app.state.finds, app.state.devices, app.state.mutes,
        push_sender or _apns(settings), clock,
    )
    app.state.invite_base_url = settings.invite_base_url
    app.state.art_cdn_base_url = settings.art_cdn_base_url
    app.include_router(circles_router)
    app.include_router(finds_router)
    app.include_router(pushes_router)

    if art_storage is None and settings.upload_bucket and settings.art_bucket:
        art_storage = S3ArtStorage(
            boto3.client("s3", region_name=settings.region, config=S3_CONFIG), upload_bucket=settings.upload_bucket, art_bucket=settings.art_bucket
        )
    if art_queue is None and settings.art_queue_url:
        art_queue = SqsArtQueue(boto3.client("sqs", region_name=settings.region), settings.art_queue_url)
    app.state.art_jobs = (
        ArtJobStore(
            dynamodb.Table(settings.table_name),
            clock,
            rule=settings.art_auto_paint,  # type: ignore[arg-type]
            storage=art_storage,
            queue=art_queue,
            notifier=art_notifier or NoNotifier(),
            retention=art_retention or NothingShared(),
        )
        if art_storage is not None
        else None
    )
    app.state.worker_token = (
        WorkerToken(value=settings.art_worker_token)
        if settings.art_worker_token
        else WorkerToken(
            secret_id=settings.art_worker_token_secret,
            secrets_client=boto3.client("secretsmanager", region_name=settings.region),
        )
        if settings.art_worker_token_secret
        else None
    )
    app.include_router(art_router)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/v1/account")
    def get_account(subject: Subject, accounts: Annotated[AccountStore, Depends(_accounts)]) -> AccountResponse:
        return AccountResponse.of(accounts.get_or_create(subject))

    @app.patch("/v1/account")
    def update_account(
        subject: Subject, update: AccountUpdate, accounts: Annotated[AccountStore, Depends(_accounts)]
    ) -> AccountResponse:
        return AccountResponse.of(accounts.update_display_name(subject, update.display_name))

    return app


def _apns(settings: Settings) -> PushSender:
    if settings.apns_secret_name is None:
        return DisabledSender()
    return ApnsSender(secrets_manager_credentials(settings.apns_secret_name, settings.region), settings.apns_topic)


def _accounts(request: Request) -> AccountStore:
    store: AccountStore = request.app.state.accounts
    return store
