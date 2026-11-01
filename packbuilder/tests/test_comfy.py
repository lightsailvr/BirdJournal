"""The ComfyUI client against a stub of the four endpoints it uses: /upload/image, /prompt, /history and /view."""

import json
import threading
from email.parser import BytesParser
from email.policy import default as default_policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import pytest

from packbuilder.art import Workflow
from packbuilder.comfy import ComfyClient, PaintingFailed

PNG = b"\x89PNG painted"


class StubComfy:
    """Records what the client sends; `history` is what /history/<id> returns once the job is done."""

    def __init__(self):
        self.uploads: dict[str, bytes] = {}
        self.queued: list[dict] = []
        self.history_calls = 0
        self.running_polls = 1
        self.prompt_status = 200
        self.prompt_reply = {"prompt_id": "job-1", "number": 0, "node_errors": {}}
        self.history = {
            "outputs": {"60": {"images": [{"filename": "art_00001_.png", "subfolder": "birdjournal", "type": "output"}]}},
            "status": {
                "status_str": "success",
                "completed": True,
                "messages": [["execution_start", {"timestamp": 1000}], ["execution_cached", {"timestamp": 1001}], ["execution_success", {"timestamp": 35500}]],
            },
        }


@pytest.fixture
def stub():
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
                image = fields["image"]
                subfolder = fields["subfolder"].get_content().strip()
                state.uploads[f"{subfolder}/{image.get_filename()}"] = image.get_content()
                self._reply(200, {"name": image.get_filename(), "subfolder": subfolder, "type": "input"})
            elif self.path == "/prompt":
                state.queued.append(json.loads(body)["prompt"])
                self._reply(state.prompt_status, state.prompt_reply)
            else:
                self._reply(404, {})

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/history/job-1":
                state.history_calls += 1
                # Running for the first `running_polls` polls, then done.
                self._reply(200, {} if state.history_calls <= state.running_polls else {"job-1": state.history})
            elif url.path == "/view":
                query = parse_qs(url.query)
                found = query == {"filename": ["art_00001_.png"], "subfolder": ["birdjournal"], "type": ["output"]}
                self._reply(200 if found else 404, PNG if found else b"", "image/png")
            else:
                self._reply(404, {})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    state.url = f"http://127.0.0.1:{server.server_address[1]}"
    yield state
    server.shutdown()


def _titled(graph, title):
    (node,) = [n for n in graph.values() if n["_meta"]["title"] == title]
    return node


def test_paint_uploads_the_images_queues_the_filled_workflow_and_returns_the_painting(stub):
    client = ComfyClient(stub.url, poll_seconds=0)

    painting = client.paint(Workflow.load("scene-art"), images=[("bird.png", b"bird"), ("scene.png", b"scene")], prompt="Paint the bird", seed=7)

    assert painting.image == PNG
    assert painting.seconds == pytest.approx(34.5)
    assert stub.uploads == {"birdjournal/bird.png": b"bird", "birdjournal/scene.png": b"scene"}
    (queued,) = stub.queued
    assert _titled(queued, "image 1")["inputs"]["image"] == "birdjournal/bird.png"
    assert _titled(queued, "image 2")["inputs"]["image"] == "birdjournal/scene.png"
    assert _titled(queued, "prompt")["inputs"]["text"] == "Paint the bird"
    assert _titled(queued, "sampler")["inputs"]["seed"] == 7


def test_paint_sets_the_canvas_where_it_isnt_the_cards(stub):
    client = ComfyClient(stub.url, poll_seconds=0)

    client.paint(Workflow.load("bird-isolate"), images=[("crop.png", b"crop")], prompt="isolate", seed=49, size=(1152, 1536))

    (queued,) = stub.queued
    assert (_titled(queued, "canvas")["inputs"]["width"], _titled(queued, "canvas")["inputs"]["height"]) == (1152, 1536)


def test_a_failed_painting_raises_with_comfyuis_message(stub):
    stub.history["status"] = {
        "status_str": "error",
        "completed": False,
        "messages": [["execution_start", {"timestamp": 1000}], ["execution_error", {"node_type": "KSampler", "exception_message": "CUDA out of memory"}]],
    }
    client = ComfyClient(stub.url, poll_seconds=0)

    with pytest.raises(PaintingFailed, match="KSampler: CUDA out of memory"):
        client.paint(Workflow.load("photo-art"), images=[("photo.png", b"photo")], prompt="p", seed=1)


def test_a_graph_comfyui_refuses_raises_before_waiting(stub):
    stub.prompt_status = 400
    stub.prompt_reply = {"error": {"message": "Prompt outputs failed validation"}, "node_errors": {"1": {"errors": [{"details": "unet_name not in list"}]}}}
    client = ComfyClient(stub.url, poll_seconds=0)

    with pytest.raises(PaintingFailed, match="unet_name not in list"):
        client.paint(Workflow.load("pack-art"), images=[("ref.png", b"ref")], prompt="p", seed=1)
    assert stub.history_calls == 0


def test_a_painting_that_never_finishes_times_out(stub):
    stub.running_polls = 10**9
    client = ComfyClient(stub.url, poll_seconds=0.01, timeout_seconds=0.1)

    with pytest.raises(PaintingFailed, match="timed out"):
        client.paint(Workflow.load("pack-art"), images=[("ref.png", b"ref")], prompt="p", seed=1)


def test_an_http_error_becomes_a_failed_painting_so_a_round_goes_on(stub):
    stub.history["outputs"]["60"]["images"][0]["filename"] = "gone.png"  # /view answers 404
    client = ComfyClient(stub.url, poll_seconds=0)

    with pytest.raises(PaintingFailed, match="404"):
        client.paint(Workflow.load("pack-art"), images=[("ref.png", b"ref")], prompt="p", seed=1)
