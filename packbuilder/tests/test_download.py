"""`download.fetch`: a download whose body breaks off is asked for again, so one stalled photo never ends a build (#58)."""

import pytest
import requests

from packbuilder import download


class Response:
    def __init__(self, chunks):
        self.chunks = chunks

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        pass

    def iter_content(self, size):
        for chunk in self.chunks:
            if isinstance(chunk, Exception):
                raise chunk
            yield chunk


class Session:
    def __init__(self, responses):
        self.responses, self.requests = list(responses), 0

    def get(self, url, **kwargs):
        self.requests += 1
        return self.responses.pop(0)


def test_a_body_that_breaks_off_is_fetched_again_and_no_partial_file_is_kept(tmp_path, monkeypatch):
    stalled = Response([b"half", requests.ConnectionError("Read timed out.")])
    session = Session([stalled, Response([b"whole ", b"photo"])])
    monkeypatch.setattr(download, "session", lambda: session)
    monkeypatch.setattr(download, "BODY_PAUSE", 0)

    path = download.fetch("https://example.invalid/photo.jpg", tmp_path / "photo.jpg")

    assert path.read_bytes() == b"whole photo" and session.requests == 2
    assert [p.name for p in tmp_path.iterdir()] == ["photo.jpg"]


def test_a_download_that_keeps_breaking_off_fails_after_its_attempts(tmp_path, monkeypatch):
    session = Session([Response([requests.ConnectionError("Read timed out.")]) for _ in range(download.BODY_ATTEMPTS)])
    monkeypatch.setattr(download, "session", lambda: session)
    monkeypatch.setattr(download, "BODY_PAUSE", 0)

    with pytest.raises(requests.ConnectionError):
        download.fetch("https://example.invalid/photo.jpg", tmp_path / "photo.jpg")

    assert session.requests == download.BODY_ATTEMPTS and list(tmp_path.iterdir()) == []
