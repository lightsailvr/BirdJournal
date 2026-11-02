"""The API: account get and update (issue #60), circles (issue #61), finds (issue #62) with shared cards (issue #66),
art jobs (issue #68), pushes (issue #63), reactions and compare (issue #64), goals (issue #65), and reports, blocks,
moderation and account deletion (issue #71). Later tickets add their routers here."""

import logging
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated

import boto3
import httpx2
from botocore.config import Config
from fastapi import Depends, FastAPI, Request
from pydantic import BaseModel, ConfigDict, field_serializer, field_validator

from birdjournal_api.accounts import Account, AccountStore, clean_display_name
from birdjournal_api.apns import ApnsSender, DisabledSender, secrets_manager_credentials
from birdjournal_api.art import (
    ArtJobStore,
    ArtNotifier,
    ArtQueue,
    ArtStorage,
    NoNotifier,
    FindsShowArt,
    PaintedArt,
    S3ArtStorage,
    SqsArtQueue,
    WorkerToken,
)
from birdjournal_api.art_api import router as art_router
from birdjournal_api.auth import (
    CurrentIdentity,
    SigningKeyResolver,
    TokenVerifier,
    cognito_signing_keys,
)
from birdjournal_api.circles import CircleStore
from birdjournal_api.deletion import (
    AccountDeleter,
    AppleSignIn,
    AppleTokens,
    CognitoUsers,
    UserDirectory,
    secrets_manager_apple_key,
    user_pool_id,
)
from birdjournal_api.moderation import ImageModerator, Moderation, RekognitionModerator
from birdjournal_api.circles_api import router as circles_router
from birdjournal_api.finds import FindStore
from birdjournal_api.devices import DeviceStore, MuteStore
from birdjournal_api.finds_api import router as finds_router
from birdjournal_api.goals import GoalStore
from birdjournal_api.goals_api import router as goals_router
from birdjournal_api.photos import PhotoStore, S3PhotoStore
from birdjournal_api.pushes import PushSender, PushService
from birdjournal_api.pushes_api import router as pushes_router
from birdjournal_api.reactions import ReactionStore
from birdjournal_api.reactions_api import router as reactions_router
from birdjournal_api.safety import BlockStore, Mailer, NoMailer, ReportStore, SesMailer
from birdjournal_api.safety_api import router as safety_router
from birdjournal_api.settings import Settings

logging.getLogger().setLevel(logging.INFO)

# Presigned upload URLs must be SigV4 on the bucket's own regional host.
S3_CONFIG = Config(signature_version="s3v4", s3={"addressing_style": "virtual"})


class AccountResponse(BaseModel):
    id: str
    display_name: str | None
    created_at: datetime
    # How the birder signs in, `apple` or `google`: the app asks Apple again at deletion only for an Apple account.
    provider: str | None = None

    @field_serializer("created_at")
    def _utc(self, value: datetime) -> str:
        return value.astimezone(UTC).isoformat().replace("+00:00", "Z")

    @classmethod
    def of(cls, account: Account, provider: str | None = None) -> "AccountResponse":
        return cls(id=account.id, display_name=account.display_name, created_at=account.created_at, provider=provider)


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
    photos: PhotoStore | None = None,
    push_sender: PushSender | None = None,
    mailer: Mailer | None = None,
    moderator: ImageModerator | None = None,
    users: UserDirectory | None = None,
    apple: AppleTokens | None = None,
) -> FastAPI:
    """The API over the settings' table. Tests pass a signing key from their own issuer, a clock, and fakes for the art
    buckets, queue and notifier, the shared photos, APNs, the report mail, Rekognition, the user pool and Apple;
    otherwise shared cards' photos go to the art bucket, when the stack has one."""
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
    if art_storage is None and settings.upload_bucket and settings.art_bucket:
        art_storage = S3ArtStorage(
            boto3.client("s3", region_name=settings.region, config=S3_CONFIG), upload_bucket=settings.upload_bucket, art_bucket=settings.art_bucket
        )
    # Painted art on finds (#70): a find shows a painting only while the server holds it, and lets it go after.
    table = dynamodb.Table(settings.table_name)
    painted = PaintedArt(table, art_storage, clock)
    # Rekognition (#71), behind the switch: never called while it is off.
    if moderator is None and settings.moderation:
        moderator = RekognitionModerator(boto3.client("rekognition", region_name=settings.region))
    moderation = Moderation(
        enabled=settings.moderation, moderator=moderator, upload_bucket=settings.upload_bucket,
        art_bucket=settings.art_bucket,
    )
    app.state.moderation = moderation
    app.state.finds = FindStore(
        dynamodb, settings.table_name, app.state.accounts, app.state.circles, clock, photos, painted, moderation
    )
    app.state.devices = DeviceStore(table, clock)
    app.state.mutes = MuteStore(table, clock)
    app.state.goals = GoalStore(table, app.state.circles, app.state.finds, clock)
    app.state.pushes = PushService(
        table, app.state.circles, app.state.finds, app.state.devices, app.state.mutes, app.state.goals,
        push_sender or _apns(settings), clock,
    )
    app.state.reactions = ReactionStore(
        dynamodb, settings.table_name, app.state.circles, app.state.finds, app.state.devices, app.state.mutes,
        app.state.pushes, clock,
    )
    app.state.invite_base_url = settings.invite_base_url
    app.state.art_cdn_base_url = settings.art_cdn_base_url
    if mailer is None:
        mailer = (
            SesMailer(boto3.client("sesv2", region_name=settings.region), sender=settings.report_sender or settings.report_email, recipient=settings.report_email)
            if settings.report_email
            else NoMailer()
        )
    app.state.reports = ReportStore(
        table, app.state.circles, app.state.finds, mailer, clock, art_cdn_base_url=settings.art_cdn_base_url
    )
    app.state.blocks = BlockStore(app.state.circles, app.state.mutes)
    if users is None:
        users = CognitoUsers(boto3.client("cognito-idp", region_name=settings.region), user_pool_id(settings.cognito_issuer))
    if apple is None and settings.apple_sign_in_secret_name:
        apple = AppleSignIn(
            secrets_manager_apple_key(settings.apple_sign_in_secret_name, settings.region), settings.apple_client_id,
            post=lambda url, **kwargs: httpx2.post(url, timeout=5, **kwargs),
        )
    app.state.deleter = AccountDeleter(
        table, app.state.circles, app.state.finds, app.state.devices, art_storage=art_storage, users=users, apple=apple
    )
    app.include_router(safety_router)
    app.include_router(circles_router)
    app.include_router(finds_router)
    app.include_router(pushes_router)
    app.include_router(goals_router)
    app.include_router(reactions_router)

    if art_queue is None and settings.art_queue_url:
        art_queue = SqsArtQueue(boto3.client("sqs", region_name=settings.region), settings.art_queue_url)
    app.state.art_jobs = (
        ArtJobStore(
            dynamodb.Table(settings.table_name),
            clock,
            rule=settings.art_auto_paint,  # type: ignore[arg-type]
            daily_allowance=settings.art_daily_allowance,
            storage=art_storage,
            queue=art_queue,
            notifier=art_notifier or NoNotifier(),
            retention=FindsShowArt(app.state.finds.shown_art),
            moderation=moderation,
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
    def get_account(identity: CurrentIdentity, accounts: Annotated[AccountStore, Depends(_accounts)]) -> AccountResponse:
        return AccountResponse.of(accounts.get_or_create(identity.subject), identity.provider)

    @app.patch("/v1/account")
    def update_account(
        identity: CurrentIdentity, update: AccountUpdate, accounts: Annotated[AccountStore, Depends(_accounts)]
    ) -> AccountResponse:
        return AccountResponse.of(accounts.update_display_name(identity.subject, update.display_name), identity.provider)

    return app


def _apns(settings: Settings) -> PushSender:
    if settings.apns_secret_name is None:
        return DisabledSender()
    return ApnsSender(secrets_manager_credentials(settings.apns_secret_name, settings.region), settings.apns_topic)


def _accounts(request: Request) -> AccountStore:
    store: AccountStore = request.app.state.accounts
    return store
