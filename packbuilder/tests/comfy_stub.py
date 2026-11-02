"""A stub ComfyUI that paints (issue #57): it serves /upload/image, /prompt, /history and /view like the real one,
records every graph it is sent with the images it was given, and answers each workflow with a picture made from its
inputs, so that the fidelity gate passes for a faithful "painting":

- the cut-out (`BiRefNetRMBG`) makes every pixel that is neither near white nor the photo's BACKGROUND opaque;
- a painting with a reference returns that reference with its BACKGROUND made white, at the canvas size;
- a painting from text alone returns a plain bird on white.

`unfaithful` holds the output prefixes (workflows) whose paintings come back with the bird's colour channels swapped,
which no colour fit repairs.
"""

from __future__ import annotations

import io
import json
import threading
from dataclasses import dataclass, field
from email.parser import BytesParser
from email.policy import default as default_policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
from PIL import Image, ImageDraw

BACKGROUND = (70, 110, 80)
"""The background of the stub's reference photos: a green the cut-out leaves out."""


@dataclass
class Job:
    graph: dict
    names: list[str]
    """What each "image N" node loads, in order: the uploaded file's subfolder and name."""
    images: list[bytes]
    """The uploaded image of each "image N" node, in order."""

    def node(self, title: str) -> dict:
        return next(node for node in self.graph.values() if node.get("_meta", {}).get("title") == title)

    @property
    def kind(self) -> str:
        """"cutout", "reference" (a painting from an image) or "text"."""
        if any(node["class_type"] == "BiRefNetRMBG" for node in self.graph.values()):
            return "cutout"
        return "reference" if self.images else "text"

    @property
    def prompt(self) -> str:
        return self.node("prompt")["inputs"]["text"]

    @property
    def seed(self) -> int:
        return self.node("sampler")["inputs"]["seed"]

    @property
    def filename_prefix(self) -> str:
        return self.node("output")["inputs"]["filename_prefix"]


@dataclass
class StubComfy:
    url: str = ""
    uploads: dict[str, bytes] = field(default_factory=dict)
    jobs: list[Job] = field(default_factory=list)
    outputs: dict[str, bytes] = field(default_factory=dict)
    unfaithful: set[str] = field(default_factory=set)

    @property
    def paintings(self) -> list[Job]:
        """Every job but the cut-outs."""
        return [job for job in self.jobs if job.kind != "cutout"]

    def run(self, job: Job) -> bytes:
        if job.kind == "cutout":
            image = np.asarray(Image.open(io.BytesIO(job.images[0])).convert("RGB")).astype(int)
            white = np.all(image > 235, axis=-1)
            background = np.all(np.abs(image - BACKGROUND) < 12, axis=-1)
            cutout = Image.fromarray(image.astype(np.uint8)).convert("RGBA")
            cutout.putalpha(Image.fromarray(((~white & ~background) * 255).astype(np.uint8)))
            return png(cutout)
        canvas = job.node("canvas")["inputs"]
        size = (canvas["width"], canvas["height"])
        if job.kind == "text":
            return png(bird_on(Image.new("RGB", size, "white")))
        image = np.asarray(Image.open(io.BytesIO(job.images[0])).convert("RGB")).copy()
        image[np.all(np.abs(image.astype(int) - BACKGROUND) < 12, axis=-1)] = 255
        if job.filename_prefix in self.unfaithful:
            image = image[..., ::-1].copy()
        return png(Image.fromarray(image).resize(size))


def png(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    return buffer.getvalue()


def bird_on(image: Image.Image, box=(0.3, 0.3, 0.7, 0.75), colours=((180, 60, 40), (120, 95, 70))) -> Image.Image:
    """A two-tone bird (a red head over a brown body) drawn on `image` inside the normalised `box`."""
    width, height = image.size
    x0, y0, x1, y1 = box[0] * width, box[1] * height, box[2] * width, box[3] * height
    draw = ImageDraw.Draw(image)
    draw.ellipse((x0, y0 + (y1 - y0) * 0.35, x1, y1), fill=colours[1])
    draw.ellipse((x0 + (x1 - x0) * 0.2, y0, x1 - (x1 - x0) * 0.2, y0 + (y1 - y0) * 0.5), fill=colours[0])
    return image


def serve() -> tuple[StubComfy, ThreadingHTTPServer]:
    state = StubComfy()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _reply(self, status, body, content_type="application/json"):
            payload = body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.path == "/upload/image":
                message = BytesParser(policy=default_policy).parsebytes(b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
                fields = {part.get_param("name", header="content-disposition"): part for part in message.iter_parts()}
                subfolder = fields["subfolder"].get_content().strip()
                state.uploads[f"{subfolder}/{fields['image'].get_filename()}"] = fields["image"].get_content()
                self._reply(200, {"name": fields["image"].get_filename(), "subfolder": subfolder, "type": "input"})
            elif self.path == "/prompt":
                graph = json.loads(body)["prompt"]
                loads = sorted(
                    (node for node in graph.values() if node["class_type"] == "LoadImage"),
                    key=lambda node: node["_meta"]["title"],
                )
                names = [node["inputs"]["image"] for node in loads]
                job = Job(graph=graph, names=names, images=[state.uploads[name] for name in names])
                state.jobs.append(job)
                job_id = f"job-{len(state.jobs)}"
                state.outputs[job_id] = state.run(job)
                self._reply(200, {"prompt_id": job_id, "number": len(state.jobs), "node_errors": {}})
            else:
                self._reply(404, {})

        def do_GET(self):
            url = urlparse(self.path)
            if url.path.startswith("/history/"):
                job_id = url.path.removeprefix("/history/")
                self._reply(200, {job_id: {
                    "outputs": {"60": {"images": [{"filename": f"{job_id}.png", "subfolder": "birdjournal", "type": "output"}]}},
                    "status": {"status_str": "success", "completed": True, "messages": [["execution_start", {"timestamp": 0}], ["execution_success", {"timestamp": 2000}]]},
                }})
            elif url.path == "/view":
                job_id = parse_qs(url.query)["filename"][0].removesuffix(".png")
                self._reply(200, state.outputs[job_id], "image/png")
            else:
                self._reply(404, {})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    state.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return state, server
