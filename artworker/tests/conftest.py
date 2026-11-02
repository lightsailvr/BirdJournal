"""The worker against a stub ComfyUI (packbuilder's, which paints from its inputs so the fidelity gate passes), a
local queue and buckets (moto, in process: real boto3 calls, no AWS), and a stub of the API's worker routes."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
from collections.abc import Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import boto3
import pytest
from moto import mock_aws
from PIL import Image

from artworker.api import WorkerApi
from artworker.scene import References, ScenePainter
from artworker.worker import Worker
from packbuilder.comfy import ComfyClient

PACKBUILDER_TESTS = Path(__file__).resolve().parents[2] / "packbuilder" / "tests"
REGION = "us-west-2"
QUEUE = "birdjournal-art"
UPLOADS = "birdjournal-uploads"
ART = "birdjournal-art"
TOKEN = "worker-token"


def _load_comfy_stub() -> Any:
    spec = importlib.util.spec_from_file_location("comfy_stub", PACKBUILDER_TESTS / "comfy_stub.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["comfy_stub"] = module
    spec.loader.exec_module(module)
    return module


comfy_stub = _load_comfy_stub()


@pytest.fixture
def comfy() -> Iterator[Any]:
    state, server = comfy_stub.serve()
    yield state
    server.shutdown()


@pytest.fixture
def references(tmp_path: Path) -> References:
    """Two packs' reference birds on white: a House Finch in Los Angeles, a Red-tailed Hawk only in San Diego."""
    root = tmp_path / "references"
    for pack, species in {
        "us-ca-la": {"Haemorhous mexicanus": ("haemorhous-mexicanus", 14.0, 677925555)},
        "us-ca-sd": {"Haemorhous mexicanus": ("haemorhous-mexicanus", 14.0, 1), "Buteo jamaicensis": ("buteo-jamaicensis", 52.0, 2)},
    }.items():
        folder = root / pack
        folder.mkdir(parents=True)
        listing = {}
        for name, (species_id, length, photo) in species.items():
            comfy_stub.bird_on(Image.new("RGB", (432, 576), "white")).save(folder / f"{species_id}.png")
            listing[name] = {"file": f"{species_id}.png", "length_cm": length, "photo_id": photo, "species_id": species_id}
        (folder / "references.json").write_text(json.dumps({"pack": pack, "species": listing, "missing": [], "no_reference": []}))
    return References(root)


def glasses_photo() -> bytes:
    """A stand-in for a 1080 × 1440 in-stream frame: a park in greens and browns."""
    import io

    image = Image.new("RGB", (1080, 1440), (110, 140, 90))
    for y in range(0, 1440, 40):
        Image.Image.paste(image, (90 + y % 120, 120, 70), (0, y, 1080, y + 12))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=90)
    return buffer.getvalue()


@dataclass
class ApiStub:
    """The API's worker routes: records every call; `claims` answers each claim, `status` overrides every answer."""

    url: str = ""
    calls: list[tuple[str, dict | None, str | None]] = field(default_factory=list)
    claims: dict[str, dict] = field(default_factory=dict)
    status: int | None = None

    def claim_for(self, owner: str, job_id: str, **fields: Any) -> dict:
        claim = {
            "id": job_id, "owner": owner, "kind": "scene", "scientific_name": "Haemorhous mexicanus", "edition": "us-ca-la",
            "legendary": False, "input_key": f"uploads/{owner}/{job_id}.jpg", "output_key": f"art/{owner}/unguessable-{job_id}.jpg",
            "attempt": 1, **fields,
        }
        self.claims[job_id] = claim
        return claim

    def paths(self) -> list[str]:
        return [path for path, _, _ in self.calls]


@pytest.fixture
def api() -> Iterator[ApiStub]:
    state = ApiStub()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args: Any) -> None:
            pass

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            body = json.loads(raw) if raw and raw != b"null" else None
            state.calls.append((self.path, body, self.headers.get("Authorization")))
            status, reply = 200, {"state": "ok"}
            if state.status is not None:
                status, reply = state.status, {"detail": "stubbed"}
            elif self.path.endswith("/claim"):
                job_id = self.path.split("/")[-2]
                status, reply = (200, state.claims[job_id]) if job_id in state.claims else (404, {"detail": "not_found"})
            payload = json.dumps(reply).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    state.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield state
    server.shutdown()


class Filter:
    def __init__(self) -> None:
        self.refuse = False
        self.seen: list[Image.Image] = []

    def allows(self, image: Image.Image) -> bool:
        self.seen.append(image)
        return not self.refuse


@pytest.fixture
def content_filter() -> Filter:
    return Filter()


@dataclass
class Aws:
    sqs: Any
    s3: Any
    queue_url: str

    def send(self, body: dict | str) -> None:
        self.sqs.send_message(QueueUrl=self.queue_url, MessageBody=body if isinstance(body, str) else json.dumps(body))

    def upload(self, key: str, data: bytes) -> None:
        self.s3.put_object(Bucket=UPLOADS, Key=key, Body=data)

    def messages(self) -> dict[str, int]:
        attributes = self.sqs.get_queue_attributes(QueueUrl=self.queue_url, AttributeNames=["All"])["Attributes"]
        return {
            "visible": int(attributes["ApproximateNumberOfMessages"]),
            "in_flight": int(attributes["ApproximateNumberOfMessagesNotVisible"]),
        }

    def art(self) -> dict[str, bytes]:
        listed = self.s3.list_objects_v2(Bucket=ART).get("Contents", [])
        return {item["Key"]: self.s3.get_object(Bucket=ART, Key=item["Key"])["Body"].read() for item in listed}


@pytest.fixture
def aws() -> Iterator[Aws]:
    os.environ.update({"AWS_ACCESS_KEY_ID": "testing", "AWS_SECRET_ACCESS_KEY": "testing", "AWS_DEFAULT_REGION": REGION})
    with mock_aws():
        sqs = boto3.client("sqs", region_name=REGION)
        s3 = boto3.client("s3", region_name=REGION)
        queue_url = sqs.create_queue(QueueName=QUEUE, Attributes={"VisibilityTimeout": "900"})["QueueUrl"]
        for bucket in (UPLOADS, ART):
            s3.create_bucket(Bucket=bucket, CreateBucketConfiguration={"LocationConstraint": REGION})
        yield Aws(sqs, s3, queue_url)


@pytest.fixture
def make_worker(aws: Aws, api: ApiStub, references: References, content_filter: Filter, tmp_path: Path):
    def make(comfy_url: str) -> Worker:
        return Worker(
            sqs=aws.sqs,
            s3=aws.s3,
            queue_url=aws.queue_url,
            upload_bucket=UPLOADS,
            art_bucket=ART,
            api=WorkerApi(api.url, TOKEN),
            painter=ScenePainter(ComfyClient(comfy_url, poll_seconds=0.01, timeout_seconds=10), references, cutouts=tmp_path / "cutouts"),
            content_filter=content_filter,
        )

    return make
