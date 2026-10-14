"""A small client for ComfyUI's HTTP API on comfybox (ADR-0003: it listens on loopback and the box's tailnet address,
never the home LAN).

One painting is: upload the input images, queue the filled workflow, poll its history until it finishes, download
the image its "output" node saved. ComfyUI has no authentication; the tailnet is the boundary.
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass

import requests

from packbuilder.art import Workflow
from packbuilder.http import session

UPLOAD_FOLDER = "birdjournal"


class PaintingFailed(RuntimeError):
    pass


@dataclass(frozen=True)
class Painting:
    image: bytes
    seconds: float
    """ComfyUI's own time from the start of the execution to its success, model loading included."""


class ComfyClient:
    def __init__(self, base_url: str, poll_seconds: float = 1.0, timeout_seconds: float = 900.0):
        self.base_url = base_url.rstrip("/")
        self.poll_seconds = poll_seconds
        self.timeout_seconds = timeout_seconds
        self.client_id = str(uuid.uuid4())
        # The builder's session retries GETs only, so the history and image polls survive a dropped connection while
        # POST /prompt is never sent twice.
        self.http = session()

    def upload(self, name: str, data: bytes) -> str:
        """Uploads an input image (replacing one of the same name) and returns the name LoadImage takes."""
        response = self.http.post(
            f"{self.base_url}/upload/image",
            files={"image": (name, data, "application/octet-stream")},
            data={"subfolder": UPLOAD_FOLDER, "overwrite": "true"},
            timeout=120,
        )
        response.raise_for_status()
        uploaded = response.json()
        return f"{uploaded['subfolder']}/{uploaded['name']}" if uploaded.get("subfolder") else uploaded["name"]

    def paint(self, workflow: Workflow, images: list[tuple[str, bytes]], prompt: str | None = None, negative: str | None = None, seed: int | None = None) -> Painting:
        """Runs a workflow once and returns the image it saved: `images` are (file name, bytes) for "image 1",
        "image 2", ... in order. Any failure, the network's included, is a `PaintingFailed`."""
        try:
            names = [self.upload(name, data) for name, data in images]
            graph = workflow.fill(images=names, prompt=prompt, negative=negative, seed=seed)
            response = self.http.post(f"{self.base_url}/prompt", json={"prompt": graph, "client_id": self.client_id}, timeout=60)
            if response.status_code != 200:
                raise PaintingFailed(f"ComfyUI refused the {workflow.name} workflow: {_refusal(response)}")
            entry = self._wait(response.json()["prompt_id"])
            return Painting(image=self._output(entry), seconds=_execution_seconds(entry))
        except requests.RequestException as error:
            raise PaintingFailed(f"ComfyUI at {self.base_url}: {error}") from error

    def _wait(self, prompt_id: str) -> dict:
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            response = self.http.get(f"{self.base_url}/history/{prompt_id}", timeout=30)
            response.raise_for_status()
            entry = response.json().get(prompt_id)
            if entry is not None:
                status = entry.get("status") or {}
                if status.get("status_str") == "error":
                    raise PaintingFailed(f"painting {prompt_id} failed: {_error_message(status)}")
                if status.get("completed"):
                    return entry
            if time.monotonic() > deadline:
                raise PaintingFailed(f"painting {prompt_id} timed out after {self.timeout_seconds:g} s")
            time.sleep(self.poll_seconds)

    def _output(self, entry: dict) -> bytes:
        for output in entry.get("outputs", {}).values():
            for image in output.get("images", []):
                if image.get("type") == "output":
                    response = self.http.get(
                        f"{self.base_url}/view",
                        params={"filename": image["filename"], "subfolder": image.get("subfolder", ""), "type": "output"},
                        timeout=120,
                    )
                    response.raise_for_status()
                    return response.content
        raise PaintingFailed("the workflow finished without saving an image")


def _execution_seconds(entry: dict) -> float:
    stamps = {name: data.get("timestamp") for name, data in (entry.get("status") or {}).get("messages", [])}
    start, end = stamps.get("execution_start"), stamps.get("execution_success")
    return (end - start) / 1000 if start is not None and end is not None else float("nan")


def _error_message(status: dict) -> str:
    for name, data in status.get("messages", []):
        if name == "execution_error":
            return f"{data.get('node_type')}: {data.get('exception_message', '').strip()}"
    return "unknown error"


def _refusal(response: requests.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        return response.text[:500]
    details = [
        error.get("details") or error.get("message", "")
        for node in (body.get("node_errors") or {}).values()
        for error in node.get("errors", [])
    ]
    return "; ".join(filter(None, details)) or (body.get("error") or {}).get("message", "unknown error")
