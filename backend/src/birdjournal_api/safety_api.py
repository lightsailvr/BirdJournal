"""The safety routes (issue #71): report a find or an account, block and unblock an account, and delete one's own
account."""

from datetime import UTC
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Body, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from birdjournal_api.auth import CurrentIdentity, Subject
from birdjournal_api.circles import NotFound
from birdjournal_api.deletion import AccountDeleter
from birdjournal_api.safety import (
    BlockStore,
    OwnAccount,
    ReportKind,
    ReportReason,
    ReportStore,
    TooManyReports,
    clean_details,
)


class ReportBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: ReportKind
    # The account reported, or the find's owner.
    account_id: str = Field(min_length=1, max_length=128)
    # The circle where the reporter saw it.
    circle_id: str = Field(min_length=1, max_length=64)
    # The find, for a find's report.
    sighting_id: UUID | None = None
    reason: ReportReason
    details: str | None = None

    @field_validator("details")
    @classmethod
    def _details(cls, value: str | None) -> str | None:
        return clean_details(value)

    @model_validator(mode="after")
    def _find_named(self) -> "ReportBody":
        if self.kind is ReportKind.FIND and self.sighting_id is None:
            raise ValueError("A find's report names the sighting")
        return self


class ReportResponse(BaseModel):
    id: str
    created_at: str


class BlockedAccount(BaseModel):
    id: str
    display_name: str | None


class BlocksResponse(BaseModel):
    accounts: list[BlockedAccount]


class DeleteAccountBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # From the app's own Sign in with Apple, asked again at deletion, so the API can revoke the birder's Apple token.
    apple_authorization_code: str | None = Field(default=None, max_length=2000)


def _reports(request: Request) -> ReportStore:
    store: ReportStore = request.app.state.reports
    return store


def _blocks(request: Request) -> BlockStore:
    store: BlockStore = request.app.state.blocks
    return store


def _deleter(request: Request) -> AccountDeleter:
    deleter: AccountDeleter = request.app.state.deleter
    return deleter


Reports = Annotated[ReportStore, Depends(_reports)]
Blocks = Annotated[BlockStore, Depends(_blocks)]
Deleter = Annotated[AccountDeleter, Depends(_deleter)]

router = APIRouter(prefix="/v1")


@router.post("/reports", status_code=status.HTTP_201_CREATED)
def report(subject: Subject, body: ReportBody, reports: Reports) -> ReportResponse:
    try:
        filed = reports.report(
            subject, kind=body.kind, account=body.account_id, circle_id=body.circle_id,
            sighting_id=str(body.sighting_id).lower() if body.sighting_id else None,
            reason=body.reason, details=body.details,
        )
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    except OwnAccount:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "own_account") from None
    except TooManyReports:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "too_many_reports") from None
    return ReportResponse(
        id=filed.id, created_at=filed.created_at.astimezone(UTC).isoformat().replace("+00:00", "Z")
    )


@router.get("/blocks")
def blocks(subject: Subject, store: Blocks) -> BlocksResponse:
    return BlocksResponse(
        accounts=[BlockedAccount(id=account, display_name=name) for account, name in store.blocked(subject)]
    )


@router.put("/blocks/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
def block(subject: Subject, account_id: str, store: Blocks) -> Response:
    try:
        store.block(subject, account_id)
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    except OwnAccount:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "own_account") from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/blocks/{account_id}", status_code=status.HTTP_204_NO_CONTENT)
def unblock(subject: Subject, account_id: str, store: Blocks) -> Response:
    store.unblock(subject, account_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/account", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(
    identity: CurrentIdentity, deleter: Deleter, body: Annotated[DeleteAccountBody | None, Body()] = None
) -> Response:
    deleter.delete(
        identity.subject, identity.username,
        apple_authorization_code=body.apple_authorization_code if body is not None else None,
    )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
