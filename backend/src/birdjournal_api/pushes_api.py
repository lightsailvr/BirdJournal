"""The push routes (issue #63): register and unregister a phone, and mute or unmute a circle or a friend."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict

from birdjournal_api.auth import Subject
from birdjournal_api.circles import CircleStore
from birdjournal_api.devices import DeviceStore, Environment, MuteStore, clean_token


class DeviceBody(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # `sandbox` for a development-signed build, `production` for TestFlight and the App Store.
    environment: Environment


class MutesResponse(BaseModel):
    circles: list[str]
    friends: list[str]


def _devices(request: Request) -> DeviceStore:
    store: DeviceStore = request.app.state.devices
    return store


def _mutes(request: Request) -> MuteStore:
    store: MuteStore = request.app.state.mutes
    return store


def _circles(request: Request) -> CircleStore:
    store: CircleStore = request.app.state.circles
    return store


Devices = Annotated[DeviceStore, Depends(_devices)]
Muting = Annotated[MuteStore, Depends(_mutes)]
Circles = Annotated[CircleStore, Depends(_circles)]


def _token(raw: str) -> str:
    try:
        return clean_token(raw)
    except ValueError:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "bad_device_token") from None


router = APIRouter(prefix="/v1")


@router.put("/account/devices/{token}", status_code=status.HTTP_204_NO_CONTENT)
def register_device(subject: Subject, token: str, body: DeviceBody, devices: Devices) -> Response:
    devices.register(subject, _token(token), body.environment)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/account/devices/{token}", status_code=status.HTTP_204_NO_CONTENT)
def unregister_device(subject: Subject, token: str, devices: Devices) -> Response:
    devices.unregister(subject, _token(token))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/mutes")
def read_mutes(subject: Subject, mutes: Muting) -> MutesResponse:
    current = mutes.mutes_of(subject)
    return MutesResponse(circles=sorted(current.circles), friends=sorted(current.friends))


@router.put("/circles/{circle_id}/mute", status_code=status.HTTP_204_NO_CONTENT)
def mute_circle(subject: Subject, circle_id: str, mutes: Muting, circles: Circles) -> Response:
    if not circles.is_member(subject, circle_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found")
    mutes.mute_circle(subject, circle_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/circles/{circle_id}/mute", status_code=status.HTTP_204_NO_CONTENT)
def unmute_circle(subject: Subject, circle_id: str, mutes: Muting) -> Response:
    mutes.unmute_circle(subject, circle_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/friends/{friend_id}/mute", status_code=status.HTTP_204_NO_CONTENT)
def mute_friend(subject: Subject, friend_id: str, mutes: Muting, circles: Circles) -> Response:
    if friend_id == subject:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "cannot_mute_yourself")
    # Only someone the birder shares a circle with: an account's existence never leaks.
    if not circles.share_a_circle(subject, friend_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found")
    mutes.mute_friend(subject, friend_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/friends/{friend_id}/mute", status_code=status.HTTP_204_NO_CONTENT)
def unmute_friend(subject: Subject, friend_id: str, mutes: Muting) -> Response:
    mutes.unmute_friend(subject, friend_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
