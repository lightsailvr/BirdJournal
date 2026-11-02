"""The API: account get and update (issue #60), circles (issue #61) and finds (issue #62), with shared cards (issue #66). Later tickets add their routers here."""

import logging
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Annotated

import boto3
from fastapi import Depends, FastAPI, Request
from pydantic import BaseModel, ConfigDict, field_serializer, field_validator

from birdjournal_api.accounts import Account, AccountStore, clean_display_name
from birdjournal_api.auth import SigningKeyResolver, Subject, TokenVerifier, cognito_signing_keys
from birdjournal_api.circles import CircleStore
from birdjournal_api.circles_api import router as circles_router
from birdjournal_api.finds import FindStore
from birdjournal_api.finds_api import router as finds_router
from birdjournal_api.photos import PhotoStore, S3PhotoStore
from birdjournal_api.settings import Settings

logging.getLogger().setLevel(logging.INFO)


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
    photos: PhotoStore | None = None,
) -> FastAPI:
    """The API over the settings' table. Tests pass a signing key from their own issuer, a clock and a photo store;
    otherwise the photos of shared cards go to the art bucket, when the stack has one."""
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
    app.state.invite_base_url = settings.invite_base_url
    app.state.art_cdn_base_url = settings.art_cdn_base_url
    app.include_router(circles_router)
    app.include_router(finds_router)

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


def _accounts(request: Request) -> AccountStore:
    store: AccountStore = request.app.state.accounts
    return store
