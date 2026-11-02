"""The worker's side of the BirdJournal API (backend art_api.py): claim, ready and failed, with the worker token."""

from __future__ import annotations

from dataclasses import dataclass

import requests


@dataclass(frozen=True)
class Claim:
    id: str
    owner: str
    kind: str
    scientific_name: str
    edition: str | None
    legendary: bool
    input_key: str
    output_key: str
    attempt: int


class Gone(Exception):
    """Nothing to paint: the job finished, expired, never got its photo, or doesn't exist. Drop the message."""


class Unavailable(Exception):
    """The API refused the token or isn't answering: keep the message for later."""


class WorkerApi:
    def __init__(self, base_url: str, token: str, session: requests.Session | None = None, timeout: float = 15.0):
        self.base_url = base_url.rstrip("/")
        self.session = session or requests.Session()
        self.session.headers["Authorization"] = f"Bearer {token}"
        self.timeout = timeout

    def claim(self, owner: str, job_id: str) -> Claim:
        response = self._post(f"/internal/art/jobs/{owner}/{job_id}/claim", None)
        return Claim(**response.json())

    def ready(self, claim: Claim, provenance: str) -> None:
        self._post(f"/internal/art/jobs/{claim.owner}/{claim.id}/ready", {"output_key": claim.output_key, "provenance": provenance[:500]})

    def failed(self, owner: str, job_id: str, reason: str) -> None:
        self._post(f"/internal/art/jobs/{owner}/{job_id}/failed", {"reason": reason})

    def _post(self, path: str, body: dict | None) -> requests.Response:
        try:
            response = self.session.post(f"{self.base_url}{path}", json=body, timeout=self.timeout)
        except requests.RequestException as error:
            raise Unavailable(str(error)) from error
        if response.status_code in (404, 409, 410):
            raise Gone(f"{response.status_code} {response.text}")
        if response.status_code >= 400:
            raise Unavailable(f"{response.status_code} {response.text}")
        return response
