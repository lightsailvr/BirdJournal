#!/usr/bin/env python3
"""Generate an input Info.plist without changing source or the signed product (issue #182)."""
from __future__ import annotations

import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def local_commit(repository: Path) -> str:
    """Never borrow the identity of an enclosing, unrelated repository."""
    try:
        def git(*arguments: str) -> str:
            return subprocess.check_output(
                ["git", "-C", str(repository), *arguments], text=True, stderr=subprocess.DEVNULL
            ).strip()

        if Path(git("rev-parse", "--show-toplevel")).resolve() != repository.resolve():
            return "unknown"
        commit = git("rev-parse", "--short=7", "HEAD")
        if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
            return "unknown"
        return commit + ("-dirty" if git("status", "--porcelain", "--untracked-files=normal") else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def generate(source: Path, output: Path, repository: Path) -> None:
    with source.open("rb") as handle:
        info = plistlib.load(handle)
    # Always replace, rather than retain a local key from any previous build.
    info.pop("BirdJournalBuildCommit", None)
    cloud_number = os.environ.get("CI_BUILD_NUMBER", "")
    cloud = os.environ.get("CI_XCODE_CLOUD", "").upper() == "TRUE" or bool(cloud_number)
    build = cloud_number if cloud else os.environ["CURRENT_PROJECT_VERSION"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build):
        raise ValueError("CI_BUILD_NUMBER / CURRENT_PROJECT_VERSION must be a bundle build number")
    info["CFBundleVersion"] = build
    info["CFBundleShortVersionString"] = os.environ["MARKETING_VERSION"]
    if not cloud:
        info["BirdJournalBuildCommit"] = local_commit(repository)
    data = plistlib.dumps(info, sort_keys=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Avoid making ProcessInfoPlistFile run again when nothing changed.
    if not output.exists() or output.read_bytes() != data:
        output.write_bytes(data)


if __name__ == "__main__":
    try:
        generate(*(Path(value) for value in sys.argv[1:4]))
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"error: cannot generate build identity: {error}")
