"""The goal routes (issue #65): a circle's goals with their progress, and custom goals made and deleted."""

from datetime import UTC, date, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, field_serializer, field_validator

from birdjournal_api.auth import Subject
from birdjournal_api.circles import NotFound
from birdjournal_api.goals import (
    TARGET_MAX,
    AutomaticGoal,
    GoalKind,
    GoalStatus,
    GoalStore,
    GoalView,
    NotAllowed,
    clean_title,
)


def _utc(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


class Creator(BaseModel):
    id: str
    display_name: str | None


class GoalResponse(BaseModel):
    id: str
    kind: GoalKind
    title: str
    target: int
    # Calendar days in the circle's time zone, both included.
    start_date: date
    end_date: date
    # The same period as instants: from midnight starting the first day to midnight ending the last.
    starts_at: datetime
    ends_at: datetime
    # Distinct species among the circle's finds in the period, now.
    progress: int
    status: GoalStatus
    # When progress first reached the target (it can fall back after a delete; this stays).
    completed_at: datetime | None
    # Null for the monthly goal.
    created_by: Creator | None
    can_delete: bool

    @field_serializer("starts_at", "ends_at")
    def _instant(self, value: datetime) -> str:
        return _utc(value)

    @field_serializer("completed_at")
    def _completed(self, value: datetime | None) -> str | None:
        return _utc(value) if value else None

    @classmethod
    def of(cls, view: GoalView) -> "GoalResponse":
        goal = view.goal
        return cls(
            id=goal.id,
            kind=goal.kind,
            title=goal.title,
            target=goal.target,
            start_date=goal.start_date,
            end_date=goal.end_date,
            starts_at=view.starts_at,
            ends_at=view.ends_at,
            progress=view.progress,
            status=view.status,
            completed_at=goal.completed_at,
            created_by=Creator(id=goal.created_by, display_name=view.created_by_name) if goal.created_by else None,
            can_delete=view.can_delete,
        )


class GoalList(BaseModel):
    goals: list[GoalResponse]


class GoalCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str
    target: int
    start_date: date
    end_date: date

    @field_validator("title")
    @classmethod
    def _title(cls, value: str) -> str:
        return clean_title(value)

    @field_validator("target")
    @classmethod
    def _target(cls, value: int) -> int:
        if not 1 <= value <= TARGET_MAX:
            raise ValueError("bad_target")
        return value


def _goals(request: Request) -> GoalStore:
    store: GoalStore = request.app.state.goals
    return store


Goals = Annotated[GoalStore, Depends(_goals)]

router = APIRouter(prefix="/v1")


@router.get("/circles/{circle_id}/goals")
def list_goals(subject: Subject, circle_id: str, goals: Goals) -> GoalList:
    try:
        return GoalList(goals=[GoalResponse.of(view) for view in goals.goals(subject, circle_id)])
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None


@router.post("/circles/{circle_id}/goals", status_code=status.HTTP_201_CREATED)
def create_goal(subject: Subject, circle_id: str, body: GoalCreate, goals: Goals) -> GoalResponse:
    try:
        view = goals.create(subject, circle_id, body.title, body.target, body.start_date, body.end_date)
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    except ValueError as error:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(error)) from None
    return GoalResponse.of(view)


@router.delete("/circles/{circle_id}/goals/{goal_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_goal(subject: Subject, circle_id: str, goal_id: str, goals: Goals) -> Response:
    try:
        goals.delete(subject, circle_id, goal_id)
    except NotFound:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "not_found") from None
    except AutomaticGoal:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "automatic_goal") from None
    except NotAllowed:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "not_allowed") from None
    return Response(status_code=status.HTTP_204_NO_CONTENT)
