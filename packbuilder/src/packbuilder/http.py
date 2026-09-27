"""One `requests` session for every fetch the builder makes, retrying dropped connections and 5xx answers.

A 40-species build makes a few thousand requests to iNaturalist, its Open Data bucket and Wikipedia; one
`RemoteDisconnected` in the middle used to end the build (issue #13). GET is idempotent, so a handful of retries
with backoff is safe; 429 is included because the iNaturalist API rate-limits.
"""

from __future__ import annotations

import requests
from requests.adapters import HTTPAdapter
from urllib3.util import Retry

_session: requests.Session | None = None


def session() -> requests.Session:
    global _session
    if _session is None:
        retry = Retry(
            total=6, connect=6, read=6, status=6, backoff_factor=1.5, status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset({"GET"}), raise_on_status=False,
        )
        adapter = HTTPAdapter(max_retries=retry)
        created = requests.Session()
        created.mount("https://", adapter)
        created.mount("http://", adapter)
        _session = created
    return _session
