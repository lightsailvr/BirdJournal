"""Downloads one file from a gated Hugging Face repository into DEST/PATH and checks its SHA-256 (issue #49).

    python fetch-gated.py REPO PATH DEST SHA256

It needs `hf auth login` on the box with an account that has accepted the repository's license. On FLUX.3's release
day Hugging Face's Xet transfer stalled and plain HTTP gave about 1.5 MB/s per connection, so the file comes in 16
ranged parts (about 11 MB/s), each retried from where it stopped. A file already in place with the right hash is
kept.
"""

import hashlib
import os
import sys
import threading

import requests
from huggingface_hub import get_token, hf_hub_url

PARTS, CHUNK = 16, 1 << 20


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(1 << 24):
            digest.update(block)
    return digest.hexdigest()


def main(repo: str, path: str, dest: str, expected: str) -> None:
    out = os.path.join(dest, path)
    if os.path.exists(out) and sha256(out) == expected:
        print("ok (already here)", path, flush=True)
        return
    headers = {"Authorization": f"Bearer {get_token()}"}
    head = requests.head(hf_hub_url(repo, path), headers=headers, allow_redirects=False, timeout=60)
    if head.status_code in (401, 403):
        raise SystemExit(f"{repo}: access denied; log in with `hf auth login` and accept the license on huggingface.co/{repo}")
    url = head.headers["location"]
    size = int(requests.head(url, timeout=60).headers["content-length"])
    part = out + ".part"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(part, "wb") as f:
        f.truncate(size)
    step = -(-size // PARTS)
    failed = []

    def fetch(start: int, end: int) -> None:
        for _ in range(5):
            try:
                with requests.get(url, headers={"Range": f"bytes={start}-{end}"}, stream=True, timeout=60) as r, open(part, "r+b") as f:
                    r.raise_for_status()
                    f.seek(start)
                    for block in r.iter_content(CHUNK):
                        f.write(block)
                        start += len(block)
                return
            except requests.RequestException as error:  # resume this range from where it stopped
                print("retry", path, start, error, flush=True)
        failed.append((start, end))

    threads = [threading.Thread(target=fetch, args=(i * step, min(size, (i + 1) * step) - 1)) for i in range(PARTS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if failed:
        raise SystemExit(f"{path}: {len(failed)} part(s) failed")
    if (found := sha256(part)) != expected:
        raise SystemExit(f"{path}: SHA-256 {found}, expected {expected}")
    os.replace(part, out)
    print("ok", path, flush=True)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    main(*sys.argv[1:])
