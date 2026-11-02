"""The reaction and compare routes (issue #64): put and delete a fixed reaction on a friend's find, and a friend's
species for Compare birds."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel

from birdjournal_api.auth import Subject
from birdjournal_api.circles import CircleStore, NotFound
from birdjournal_api.finds import Method
from birdjournal_api.finds_api import Owner, ReactionResponse, _sighting_id
from birdjournal_api.reactions import OwnFind, ReactionKind, ReactionStore


class ReactionsResponse(BaseModel):
    # Every kind, in the order the phone shows them.
    reactions: list[ReactionResponse]


class ComparedSpeciesResponse(BaseModel):
    species_id: str
    scientific_name: str
    common_name: str
    # The friend's best: seen beats heard.
    method: Method


class CompareResponse(BaseModel):
    friend: Owner
    species: list[ComparedSpeciesResponse]


def _reactions(request: Request) -> ReactionStore:
    store: ReactionStore = request.app.state.reactions
    return store


def _circles(request: Request) -> CircleStore:
    store: CircleStore = request.app.state.circles
    return store


Reactions = Annotated[ReactionStore, Depends(_reactions)]
Circles = Annotated[CircleStore, Depends(_circles)]

router = APIRouter(prefix="/v1")


@router.put("/finds/{owner}/{sighting_id}/reactions/{kind}")
def put_reaction(
    subject: Subject, owner: str, sighting_id: str, kind: ReactionKind, reactions: Reactions
) -> ReactionsResponse:
    try:
        counts = reactions.put(subject, owner, _sighting_id(sighting_id), kind)
    except OwnFind:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "own_find") from None
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    return ReactionsResponse(reactions=ReactionResponse.all(counts))


@router.delete("/finds/{owner}/{sighting_id}/reactions/{kind}")
def delete_reaction(
    subject: Subject, owner: str, sighting_id: str, kind: ReactionKind, reactions: Reactions
) -> ReactionsResponse:
    try:
        counts = reactions.delete(subject, owner, _sighting_id(sighting_id), kind)
    except OwnFind:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "own_find") from None
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    return ReactionsResponse(reactions=ReactionResponse.all(counts))


@router.get("/friends/{friend_id}/compare")
def compare(subject: Subject, friend_id: str, reactions: Reactions, circles: Circles) -> CompareResponse:
    if friend_id == subject:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "cannot_compare_with_yourself")
    try:
        species = reactions.compare(subject, friend_id)
    except NotFound:
        # Only someone the birder shares a circle with: an account's existence never leaks.
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    return CompareResponse(
        friend=Owner(id=friend_id, display_name=circles.display_names([friend_id]).get(friend_id)),
        species=[
            ComparedSpeciesResponse(
                species_id=entry.species_id, scientific_name=entry.scientific_name,
                common_name=entry.common_name, method=entry.method,
            )
            for entry in species
        ],
    )
