"""The circle routes (issue #61): create, list, read, invite, preview and accept an invite, leave, remove a member."""

from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, field_serializer, field_validator

from birdjournal_api.auth import Subject
from birdjournal_api.circles import (
    Circle,
    CircleDetail,
    CircleFull,
    CircleStore,
    Forbidden,
    InviteExpired,
    InviteRevoked,
    NotFound,
    clean_circle_name,
    clean_time_zone,
)


def _utc(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


class CircleResponse(BaseModel):
    id: str
    name: str
    created_by: str
    created_at: datetime
    time_zone: str
    member_count: int
    # Whether the account asking created the circle (so may remove members).
    is_creator: bool

    @field_serializer("created_at")
    def _created(self, value: datetime) -> str:
        return _utc(value)

    @classmethod
    def of(cls, circle: Circle, subject: str) -> "CircleResponse":
        return cls(
            id=circle.id,
            name=circle.name,
            created_by=circle.created_by,
            created_at=circle.created_at,
            time_zone=circle.time_zone,
            member_count=circle.member_count,
            is_creator=circle.created_by == subject,
        )


class MemberResponse(BaseModel):
    id: str
    display_name: str | None
    joined_at: datetime
    is_creator: bool

    @field_serializer("joined_at")
    def _joined(self, value: datetime) -> str:
        return _utc(value)


class CircleDetailResponse(CircleResponse):
    members: list[MemberResponse]

    @classmethod
    def of_detail(cls, detail: CircleDetail, subject: str) -> "CircleDetailResponse":
        return cls(
            **CircleResponse.of(detail.circle, subject).model_dump(),
            members=[
                MemberResponse(
                    id=member.id,
                    display_name=member.display_name,
                    joined_at=member.joined_at,
                    is_creator=member.is_creator,
                )
                for member in detail.members
            ],
        )


class CircleList(BaseModel):
    circles: list[CircleResponse]


class CircleCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    # The creator's device's zone; the goals (a later ticket) run their months in it.
    time_zone: str = "UTC"

    @field_validator("name")
    @classmethod
    def _name(cls, value: str) -> str:
        return clean_circle_name(value)

    @field_validator("time_zone")
    @classmethod
    def _zone(cls, value: str) -> str:
        return clean_time_zone(value)


class InviteResponse(BaseModel):
    token: str
    # The link to share and the QR code's payload: the same URL.
    url: str
    expires_at: datetime

    @field_serializer("expires_at")
    def _expires(self, value: datetime) -> str:
        return _utc(value)


class InvitePreviewResponse(BaseModel):
    circle: CircleResponse
    invited_by: str | None
    expires_at: datetime
    already_member: bool

    @field_serializer("expires_at")
    def _expires(self, value: datetime) -> str:
        return _utc(value)


def _circles(request: Request) -> CircleStore:
    store: CircleStore = request.app.state.circles
    return store


def _invite_base_url(request: Request) -> str:
    base: str = request.app.state.invite_base_url
    return base


Circles = Annotated[CircleStore, Depends(_circles)]


def _refused(error: Exception) -> HTTPException:
    match error:
        case NotFound():
            return HTTPException(status.HTTP_404_NOT_FOUND, "not_found")
        case Forbidden():
            return HTTPException(status.HTTP_403_FORBIDDEN, "creator_only")
        case InviteRevoked():
            return HTTPException(status.HTTP_403_FORBIDDEN, "invite_revoked")
        case CircleFull():
            return HTTPException(status.HTTP_409_CONFLICT, "circle_full")
        case InviteExpired():
            return HTTPException(status.HTTP_410_GONE, "invite_expired")
        case ValueError():
            return HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error))
    raise error


router = APIRouter(prefix="/v1")


@router.get("/circles")
def list_circles(subject: Subject, circles: Circles) -> CircleList:
    return CircleList(circles=[CircleResponse.of(circle, subject) for circle in circles.circles_of(subject)])


@router.post("/circles", status_code=status.HTTP_201_CREATED)
def create_circle(subject: Subject, body: CircleCreate, circles: Circles, request: Request) -> CircleDetailResponse:
    detail = circles.create(subject, body.name, body.time_zone)
    # Its first monthly goal and its place in the goals' rollover (issue #65).
    request.app.state.goals.circle_created(detail.circle)
    return CircleDetailResponse.of_detail(detail, subject)


@router.get("/circles/{circle_id}")
def read_circle(subject: Subject, circle_id: str, circles: Circles) -> CircleDetailResponse:
    try:
        return CircleDetailResponse.of_detail(circles.detail(subject, circle_id), subject)
    except NotFound as error:
        raise _refused(error) from None


@router.post("/circles/{circle_id}/invites", status_code=status.HTTP_201_CREATED)
def create_invite(
    subject: Subject, circle_id: str, circles: Circles, base: Annotated[str, Depends(_invite_base_url)]
) -> InviteResponse:
    try:
        invite = circles.create_invite(subject, circle_id)
    except NotFound as error:
        raise _refused(error) from None
    return InviteResponse(token=invite.token, url=f"{base}/i/{invite.token}", expires_at=invite.expires_at)


@router.delete("/circles/{circle_id}/members/me", status_code=status.HTTP_204_NO_CONTENT)
def leave_circle(subject: Subject, circle_id: str, circles: Circles) -> Response:
    try:
        circles.leave(subject, circle_id)
    except NotFound as error:
        raise _refused(error) from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/circles/{circle_id}/members/{member_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_member(subject: Subject, circle_id: str, member_id: str, circles: Circles) -> Response:
    try:
        circles.remove(subject, circle_id, member_id)
    except (NotFound, Forbidden, ValueError) as error:
        raise _refused(error) from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/invites/{token}")
def preview_invite(subject: Subject, token: str, circles: Circles) -> InvitePreviewResponse:
    try:
        preview = circles.preview(subject, token)
    except (NotFound, InviteExpired) as error:
        raise _refused(error) from None
    return InvitePreviewResponse(
        circle=CircleResponse.of(preview.circle, subject),
        invited_by=preview.invited_by,
        expires_at=preview.invite.expires_at,
        already_member=preview.already_member,
    )


@router.post("/invites/{token}/accept")
def accept_invite(subject: Subject, token: str, circles: Circles) -> CircleDetailResponse:
    try:
        return CircleDetailResponse.of_detail(circles.accept(subject, token), subject)
    except (NotFound, InviteExpired, InviteRevoked, CircleFull) as error:
        raise _refused(error) from None
