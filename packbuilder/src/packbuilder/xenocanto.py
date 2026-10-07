"""xeno-canto (API v3) as a sound source, polite by construction.

xeno-canto's answer to our bulk-download request (issue #41): downloading is fine, "but don't try to hit the rate
limit. If you make too many requests (per second, hour), we have to block you for a while to keep the site available
to others." They publish no figure; third-party clients cite about 1,000 requests an hour. So every request, an API
search, a file download, each redirect hop and each retry, goes through one `Pacer` at one request at a time and at
least `DEFAULT_INTERVAL` seconds apart (at most 900 an hour), never in parallel, and a lock on the cache keeps a second build from making requests
beside it; a run stops after `max_requests`; the first 429, 503 or 403 stops the
run instead of retrying; and every answer and file is cached on disk, so a rerun resumes where the last one stopped and
a rebuild asks for nothing it already has. Each species costs one search (the first page of up to 500 recordings, a
second worldwide search only when the pack's country has no usable song or call) and a download per clip tried.

The API key comes from the `XENO_CANTO_API_KEY` environment variable (`api_key_from_environment`, read by the CLI and
passed in) and is never written to the cache or the log.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import logging
import os
import threading
from pathlib import Path
from urllib.parse import urljoin

import requests
from requests.adapters import HTTPAdapter
from urllib3.util import Retry

from packbuilder.definition import SpeciesEntry
from packbuilder.http import Clock, Pacer
from packbuilder.licenses import normalize_audio_license
from packbuilder.sounds import CALL, SONG, SoundCandidate

log = logging.getLogger("packbuilder")

API = "https://xeno-canto.org/api/3/recordings"
USER_AGENT = "BirdJournal packbuilder (https://github.com/lightsailvr/BirdJournal; reference clips for a personal bird-ID app)"
KEY_VARIABLE = "XENO_CANTO_API_KEY"
PER_PAGE = 500
DEFAULT_INTERVAL = 4.0
MIN_INTERVAL = 2.0
"""Below this a long run could pass 1,000 requests in an hour; the pacer refuses it."""
DEFAULT_MAX_REQUESTS = 1500
STOP_STATUSES = frozenset({403, 429, 503})
"""xeno-canto is blocking or shedding us: stop and let a person rerun later."""


class RateLimited(RuntimeError):
    """xeno-canto answered 429, 503 or 403. The run stops; the cache keeps everything fetched so far."""


class RequestBudgetExceeded(RuntimeError):
    """The run made `max_requests` requests. Rerun to continue from the cache."""


class MissingAPIKey(RuntimeError):
    pass


class XenoCantoError(RuntimeError):
    """A failed request, its message stripped of the API key (requests puts the whole URL, key included, in its errors)."""


class XenoCantoBusy(RuntimeError):
    """Another build holds the xeno-canto lock: two pacers side by side would double the rate."""


def api_key_from_environment() -> str | None:
    return os.environ.get(KEY_VARIABLE) or None


def xeno_canto_pacer(interval: float = DEFAULT_INTERVAL, clock=Clock) -> Pacer:
    """The pacer for xeno-canto: `interval` seconds between requests, never under `MIN_INTERVAL`."""
    return Pacer(interval, clock=clock, minimum=MIN_INTERVAL)


ATTEMPTS = 3
"""Tries per request for a dropped connection or a 500/502/504; each try is paced and counted."""
RETRY_BACKOFF = 10.0
"""Seconds added before the second try, doubled before the third."""
RETRY_STATUSES = frozenset({500, 502, 504})
REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})
MAX_REDIRECTS = 3


def polite_session() -> requests.Session:
    """A session that never retries or redirects by itself: those requests would go out unpaced and uncounted, so `_get`
    does both through the pacer (and passes `allow_redirects=False`)."""
    session = requests.Session()
    session.mount("https://", HTTPAdapter(max_retries=Retry(total=0, redirect=0, raise_on_status=False)))
    return session


class XenoCantoClient:
    def __init__(self, cache_dir: Path, api_key: str | None = None, session=None, pacer: Pacer | None = None, max_requests: int = DEFAULT_MAX_REQUESTS):
        self.cache_dir = Path(cache_dir)
        self.api_key = api_key or None
        self.session = session or polite_session()
        self.pacer = pacer or xeno_canto_pacer()
        self.max_requests = max_requests
        self.requests_made = 0
        self._stopped: str | None = None
        self._lock = threading.Lock()
        self._process_lock = None

    def search(self, query: str) -> list[dict]:
        """The first page of recordings matching `query` (xeno-canto's search tags), from the cache when asked before."""
        cache_file = self.cache_dir / "api" / f"{hashlib.sha256(query.encode()).hexdigest()[:24]}.json"
        if cache_file.exists():
            return json.loads(cache_file.read_text())["response"].get("recordings", [])
        if not self.api_key:
            raise MissingAPIKey(f"set {KEY_VARIABLE} (your key is on https://xeno-canto.org/account), or build with --no-sounds")
        try:
            response = self._get(API, params={"query": query, "key": self.api_key, "per_page": PER_PAGE})
            response.raise_for_status()
            payload = response.json()
        except (requests.RequestException, ValueError) as error:
            raise XenoCantoError(self._redact(str(error))) from None
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps({"query": query, "response": payload}))
        log.info("  xeno-canto: %s recordings for %s (request %d)", payload.get("numRecordings"), query, self.requests_made)
        return payload.get("recordings", [])

    def download(self, url: str, target: Path) -> Path:
        """The file at `url` in `target`, downloaded once."""
        if target.exists():
            return target
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_suffix(f"{target.suffix}.{os.getpid()}.download")
        with self._get(url, stream=True) as response:
            response.raise_for_status()
            with partial.open("wb") as handle:
                for chunk in response.iter_content(1 << 20):
                    handle.write(chunk)
        partial.replace(target)
        return target

    def _redact(self, text: str) -> str:
        return text.replace(self.api_key, "<key>") if self.api_key else text

    def close(self) -> None:
        """Releases the cross-process lock (it is also released when the process ends)."""
        if self._process_lock is not None:
            self._process_lock.close()
            self._process_lock = None

    def _hold_process_lock(self) -> None:
        """One client per cache across processes, taken on the first network request, held for the run."""
        if self._process_lock is not None:
            return
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        handle = (self.cache_dir / ".lock").open("w")
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            raise XenoCantoBusy("another pack build is using xeno-canto; build packs one after another so the request pace holds") from None
        self._process_lock = handle

    def _get(self, url: str, params: dict | None = None, stream: bool = False):
        """One request through the pacer and the budget. A redirect is followed hop by hop, each hop paced and counted
        (up to `MAX_REDIRECTS`); a dropped connection or a server error is tried again up to `ATTEMPTS` times in all,
        each try paced and counted, with `RETRY_BACKOFF` more seconds before each retry."""
        with self._lock:
            self._hold_process_lock()
            attempt = hops = 0
            while True:
                try:
                    response = self._send(url, params, stream)
                except (requests.ConnectionError, requests.Timeout):
                    attempt += 1
                    if attempt == ATTEMPTS:
                        raise
                    self.pacer.clock.sleep(RETRY_BACKOFF * 2 ** (attempt - 1))
                    continue
                if response.status_code in REDIRECT_STATUSES and response.headers.get("Location") and hops < MAX_REDIRECTS:
                    hops += 1
                    response.close()
                    url, params = urljoin(url, response.headers["Location"]), None
                    continue
                if response.status_code in RETRY_STATUSES and attempt + 1 < ATTEMPTS:
                    attempt += 1
                    response.close()
                    self.pacer.clock.sleep(RETRY_BACKOFF * 2 ** (attempt - 1))
                    continue
                return response

    def _send(self, url: str, params: dict | None, stream: bool):
        if self._stopped:
            raise RateLimited(self._stopped)
        if self.requests_made >= self.max_requests:
            raise RequestBudgetExceeded(f"made {self.requests_made} xeno-canto requests this run (the cap); rerun to continue from the cache")
        self.pacer.wait()
        self.requests_made += 1
        response = self.session.get(url, params=params, headers={"User-Agent": USER_AGENT}, timeout=120, stream=stream, allow_redirects=False)
        if response.status_code in STOP_STATUSES:
            retry_after = response.headers.get("Retry-After")
            self._stopped = (
                f"xeno-canto answered {response.status_code} after {self.requests_made} requests"
                f"{f' (Retry-After: {retry_after})' if retry_after else ''}; stopped. Wait before rerunning; the cache keeps what was fetched."
            )
            raise RateLimited(self._stopped)
        return response


def kind_of(type_field: str) -> str | None:
    """song or call from xeno-canto's free-text sound type, None when it is both, neither, or a sound that would
    mislead as a reference (subsong, a juvenile's begging call)."""
    tokens = [t.strip().lower() for t in (type_field or "").split(",") if t.strip()]
    if any("subsong" in t or "begging" in t for t in tokens):
        return None
    song = any(t.endswith("song") for t in tokens)
    call = any(t.endswith("call") for t in tokens)
    if song == call:
        return None
    return SONG if song else CALL


def parse_recording(data: dict) -> SoundCandidate | None:
    """A candidate from one API recording, or None for one the pack cannot carry or should not: a no-derivatives or
    unknown license, no recordist, a juvenile, a bird answering playback."""
    license = normalize_audio_license(data.get("lic"))
    recordist = (data.get("rec") or "").strip()
    number = str(data.get("id") or "").strip()
    if license is None or not recordist or not number or not data.get("file"):
        return None
    if (data.get("stage") or "").lower() in {"juvenile", "nestling"} or (data.get("playback-used") or "").lower() == "yes":
        return None
    url = data.get("url") or f"https://xeno-canto.org/{number}"
    file_name = data.get("file-name") or ""
    return SoundCandidate(
        id=f"xc-{number}", source="xeno-canto", catalogue=f"XC{number}", kind=kind_of(data.get("type") or ""),
        file_url=_https(data["file"]), extension=file_name.rsplit(".", 1)[-1].lower() if "." in file_name else "mp3",
        recordist=recordist, license=license, source_url=_https(url), quality=data.get("q") if data.get("q") in {"A", "B", "C", "D", "E"} else None,
        length_seconds=_seconds(data.get("length")), recorded=data.get("date") or None, country=data.get("cnt") or None,
        background_species=len([s for s in data.get("also") or [] if s]),
    )


def _https(url: str) -> str:
    return f"https:{url}" if url.startswith("//") else url


def _seconds(length: str | None) -> float | None:
    """"1:05" or "1:02:03" in seconds."""
    if not length:
        return None
    try:
        total = 0.0
        for part in length.split(":"):
            total = total * 60 + float(part)
        return total
    except ValueError:
        return None


class XenoCantoSoundSource:
    name = "xeno-canto"

    def __init__(self, client: XenoCantoClient, country: str | None = "United States", names: dict[str, str] | None = None):
        self.client = client
        self.country = country
        self.names = names or {}

    def candidates_for(self, entry: SpeciesEntry) -> list[SoundCandidate]:
        name = self.names.get(entry.scientific_name, entry.scientific_name)
        candidates = self._usable(self.client.search(f'sp:"{name}" cnt:"{self.country}"')) if self.country else []
        if not any(c.kind for c in candidates):
            candidates += self._usable(self.client.search(f'sp:"{name}"'))
        return candidates

    @staticmethod
    def _usable(recordings: list[dict]) -> list[SoundCandidate]:
        return [c for c in map(parse_recording, recordings) if c is not None]

    def fetch(self, candidate: SoundCandidate) -> Path | None:
        target = self.client.cache_dir / "files" / f"{candidate.id}.{candidate.extension}"
        try:
            return self.client.download(candidate.file_url, target)
        except requests.HTTPError as error:
            log.warning("  %s unavailable: %s", candidate.id, error)
            return None
        except (requests.ConnectionError, requests.Timeout) as error:
            log.warning("  %s unreachable after %d tries: %s", candidate.id, ATTEMPTS, error)
            return None
