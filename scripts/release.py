#!/usr/bin/env python3
"""Strikes a release: dev into main, with the "What's new" card's notes written first.

A release is one merge of `dev` into `main` (Xcode Cloud builds main for the beta channel). The app shows the newest entry
of `BirdJournal/BirdJournal/WhatsNew/whats-new.json` on a card the first time it is opened after the update, so a release
is not struck without an entry for its version. The steps, in order (docs/agents/release.md has the whole procedure and
how the notes should read):

  scripts/release.py changes            what merged into dev since the last release: the raw material for the notes
  (write the new entry at the top of whats-new.json, for the next version)
  scripts/release.py prepare 0.2.0      checks the entry, dates it today, bumps MARKETING_VERSION, commits "Release 0.2.0"
  scripts/release.py strike             pushes that commit to dev, opens the dev -> main pull request and merges it

  scripts/release.py check              the notes' rules alone; `preview` prints the newest entry as the card lays it out

`prepare` changes nothing outside this checkout. `strike` is the step that publishes: it asks for the version to be typed
before it pushes (`--yes` for a run the maintainer has already approved, `--dry-run` to see what it would do, `--no-merge`
to leave the pull request open).
"""
from __future__ import annotations

import argparse
import datetime
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import textwrap

NOTES = "BirdJournal/BirdJournal/WhatsNew/whats-new.json"
XCCONFIG = "BirdJournal/Version.xcconfig"
VERSION_LINE = re.compile(r"^MARKETING_VERSION = (\S+)$", re.MULTILINE)
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")

# The card is a small printed thing: a handful of changes, each short enough to read at a glance.
MAX_ITEMS = 6
LIMITS = {"headline": 48, "title": 40, "detail": 170, "try": 120, "note": 140}
# Words for the people who build the app, not the people who use it. The product is Featherguild; BirdJournal is its repo.
INTERNAL = re.compile(r"#[0-9]+|https?://|\b(?:BirdJournal|SwiftUI|XCUITest|pull request|refactor\w*|TODO)\b|\bPR\b", re.IGNORECASE)


class ReleaseError(Exception):
    pass


def git(root: Path, *arguments: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(root), *arguments], text=True, capture_output=True)
    if check and result.returncode != 0:
        raise ReleaseError(f"git {' '.join(arguments)} failed:\n{result.stderr.strip()}")
    # Not the start: a status line begins with a space.
    return result.stdout.rstrip("\n")


def gh(root: Path, *arguments: str) -> str:
    if not shutil.which("gh"):
        raise ReleaseError("the GitHub CLI (gh) is needed for this step")
    result = subprocess.run(["gh", *arguments], cwd=root, text=True, capture_output=True)
    if result.returncode != 0:
        raise ReleaseError(f"gh {' '.join(arguments[:3])} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def semver(version: str) -> tuple[int, ...]:
    if not SEMVER.fullmatch(version):
        raise ReleaseError(f'"{version}" is not a version like 0.2.0')
    return tuple(int(part) for part in version.split("."))


def marketing_version(text: str) -> str:
    match = VERSION_LINE.search(text)
    if not match:
        raise ReleaseError(f"no MARKETING_VERSION line in {XCCONFIG}")
    return match.group(1)


def load_notes(root: Path) -> dict:
    try:
        return json.loads((root / NOTES).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"{NOTES} can't be read: {error}") from error


def check_notes(notes: dict, app_version: str | None = None) -> list[str]:
    """Everything wrong with the notes, in words that say how to fix it. `app_version`: what the newest entry must be for."""
    problems: list[str] = []
    releases = notes.get("releases") if isinstance(notes, dict) else None
    if not isinstance(releases, list) or not releases:
        return ['the notes need a "releases" list with at least one entry, newest first']
    versions: list[tuple[int, ...]] = []
    for release in releases:
        name = f'release {release.get("version", "?")}' if isinstance(release, dict) else "a release"
        if not isinstance(release, dict):
            problems.append("every release is an object")
            continue
        unknown = set(release) - {"version", "date", "headline", "items", "note"}
        if unknown:
            problems.append(f"{name}: unknown keys {sorted(unknown)}")
        try:
            versions.append(semver(str(release.get("version", ""))))
        except ReleaseError as error:
            problems.append(f"{name}: {error}")
        try:
            datetime.date.fromisoformat(str(release.get("date", "")))
        except ValueError:
            problems.append(f'{name}: "date" is the day it was struck, like 2026-11-07')
        items = release.get("items")
        if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
            problems.append(f"{name}: between 1 and {MAX_ITEMS} items; three to five reads best")
            items = items if isinstance(items, list) else []
        copy = [("headline", release.get("headline"), False), ("note", release.get("note"), False)]
        for number, item in enumerate(items, start=1):
            if not isinstance(item, dict) or set(item) - {"title", "detail", "try"}:
                problems.append(f'{name}, item {number}: an item has "title", "detail" and optionally "try"')
                continue
            copy += [(f"item {number} title", item.get("title"), True), (f"item {number} detail", item.get("detail"), True), (f"item {number} try", item.get("try"), False)]
        titles = [item.get("title") for item in items if isinstance(item, dict)]
        if len(set(titles)) != len(titles):
            problems.append(f"{name}: two items share a title")
        for label, text, required in copy:
            kind = label.split()[-1]
            if text is None:
                if required:
                    problems.append(f"{name}, {label}: missing")
                continue
            if not isinstance(text, str) or not text.strip() or text != text.strip():
                problems.append(f"{name}, {label}: a line of text, with no space at either end")
                continue
            if len(text) > LIMITS[kind]:
                problems.append(f"{name}, {label}: {len(text)} characters, and the card has room for {LIMITS[kind]}")
            if "'" in text or '"' in text:
                problems.append(f"{name}, {label}: typographic quotes (’ “ ”), as the rest of the app has them")
            found = INTERNAL.search(text)
            if found:
                problems.append(f'{name}, {label}: "{found.group(0)}" is for the people who build the app; say what the birder sees')
            if kind in ("title", "headline") and text.endswith("."):
                problems.append(f"{name}, {label}: a heading, so no full stop")
            if kind in ("detail", "try", "note") and text[-1] not in ".!?":
                problems.append(f"{name}, {label}: a sentence, so it ends like one")
    if len(versions) == len(releases):
        if versions != sorted(versions, reverse=True) or len(set(versions)) != len(versions):
            problems.append("releases go newest first, one entry per version")
        newest = releases[0].get("version")
        if app_version is not None and newest != app_version:
            problems.append(f"the newest entry is for {newest} and the app is {app_version}: the card only shows notes for the version it's built as")
    return problems


def preview(release: dict) -> str:
    """The newest entry, laid out as the card has it."""
    width = 52
    lines = [f'{"FIELD NOTES":<{width - 16}}{"VERSION " + release["version"]:>16}', "", "What’s new".center(width)]
    if release.get("headline"):
        lines.append(release["headline"].center(width))
    lines.append("─" * width)
    for number, item in enumerate(release["items"], start=1):
        lines.append(f"{number}  {item['title']}")
        lines += textwrap.wrap(item["detail"], width - 3, initial_indent="   ", subsequent_indent="   ")
        if item.get("try"):
            lines += textwrap.wrap(f"Try it: {item['try']}", width - 3, initial_indent="   ", subsequent_indent="   ")
        lines.append("")
    if release.get("note"):
        lines.append("─" * width)
        lines += textwrap.wrap(release["note"], width)
        lines.append("")
    lines.append("[ Got it ]".center(width))
    return "\n".join(lines)


def pull_request_body(release: dict, count: int) -> str:
    lines = [f"Release {release['version']}: {count} change{'s' if count != 1 else ''} from `dev`.", "", "## What’s new", ""]
    if release.get("headline"):
        lines += [f"*{release['headline']}*", ""]
    for item in release["items"]:
        lines.append(f"- **{item['title']}.** {item['detail']}" + (f" *Try it: {item['try']}*" if item.get("try") else ""))
    if release.get("note"):
        lines += ["", release["note"]]
    return "\n".join(lines) + "\n"


def fetch(root: Path) -> None:
    git(root, "fetch", "--quiet", "origin")


def command_check(root: Path, _: argparse.Namespace) -> None:
    problems = check_notes(load_notes(root), marketing_version((root / XCCONFIG).read_text()))
    if problems:
        raise ReleaseError("the notes need another pass:\n" + "\n".join(f"  - {problem}" for problem in problems))
    print(f"ok       {NOTES}")


def command_preview(root: Path, _: argparse.Namespace) -> None:
    print(preview(load_notes(root)["releases"][0]))


def command_changes(root: Path, arguments: argparse.Namespace) -> None:
    fetch(root)
    base, head = "origin/main", arguments.head
    log = git(root, "log", "--first-parent", "--reverse", "--format=%h%x1f%s%x1f%b%x1e", f"{base}..{head}")
    # By hand, not `strip()`: to Python the separators are white space.
    entries = [entry.strip("\n").split("\x1f") for entry in log.split("\x1e") if entry.strip("\n")]
    current = marketing_version(git(root, "show", f"{base}:{XCCONFIG}"))
    struck = git(root, "log", "-1", "--format=%cs", base)
    out = [f"# Changes on dev since {current} was struck ({struck})", ""]
    use_gh = bool(shutil.which("gh"))
    for commit, subject, body in entries:
        if re.fullmatch(r"Release [0-9.]+", subject):
            continue
        number = re.search(r"Merge pull request #([0-9]+)|\(#([0-9]+)\)$", subject)
        title, text = subject, body.strip()
        if number:
            pull = number.group(1) or number.group(2)
            if use_gh:
                try:
                    details = json.loads(gh(root, "pr", "view", pull, "--json", "title,body"))
                    title, text = f"#{pull} {details['title']}", details["body"].strip()
                except (ReleaseError, json.JSONDecodeError, KeyError):
                    title = f"#{pull} {text.splitlines()[0] if text else subject}"
            else:
                title = f"#{pull} {text.splitlines()[0] if text else subject}"
        out += [f"## {title}", f"`{commit}`", ""]
        if text:
            out += [text[:1500] + (" […]" if len(text) > 1500 else ""), ""]
    if len(out) == 2:
        out += ["Nothing has merged into dev since the last release.", ""]
    report = "\n".join(out)
    target = root / "build/release/changes.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(report, encoding="utf-8")
    print(report)
    print(f"(also in {target.relative_to(root)}; the app is at {current})", file=sys.stderr)


def require_clean(root: Path, allowed: set[str] = frozenset()) -> None:
    changed = {line[3:] for line in git(root, "status", "--porcelain", "--untracked-files=no").splitlines()}
    if changed - allowed:
        raise ReleaseError("commit or put away the other changes first:\n" + "\n".join(f"  {path}" for path in sorted(changed - allowed)))


def command_prepare(root: Path, arguments: argparse.Namespace) -> None:
    version = arguments.version
    xcconfig = (root / XCCONFIG).read_text()
    current = marketing_version(xcconfig)
    if semver(version) <= semver(current):
        raise ReleaseError(f"{version} isn't after {current}, the version the app is at")
    require_clean(root, {NOTES, XCCONFIG})
    fetch(root)
    if git(root, "rev-parse", "HEAD") != git(root, "rev-parse", "origin/dev"):
        raise ReleaseError("prepare a release from dev as GitHub has it: check out origin/dev (a branch or a worktree at it), with the new notes entry as the only change")
    notes = load_notes(root)
    newest = notes.get("releases", [{}])[0]
    if newest.get("version") != version:
        raise ReleaseError(f"write the entry for {version} at the top of {NOTES} first (docs/agents/release.md says how it should read); the newest is for {newest.get('version')}")
    newest["date"] = arguments.date or datetime.date.today().isoformat()
    problems = check_notes(notes, version)
    if problems:
        raise ReleaseError("the notes need another pass:\n" + "\n".join(f"  - {problem}" for problem in problems))
    (root / NOTES).write_text(json.dumps(notes, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (root / XCCONFIG).write_text(VERSION_LINE.sub(f"MARKETING_VERSION = {version}", xcconfig))
    git(root, "add", NOTES, XCCONFIG)
    git(root, "commit", "--quiet", "-m", f"Release {version}")
    print(preview(newest))
    print(f"\nCommitted \"Release {version}\" here; nothing is pushed. Once the maintainer has read the card above: scripts/release.py strike")


def command_strike(root: Path, arguments: argparse.Namespace) -> None:
    require_clean(root)
    fetch(root)
    version = marketing_version((root / XCCONFIG).read_text())
    released = marketing_version(git(root, "show", f"origin/main:{XCCONFIG}"))
    if semver(version) <= semver(released):
        raise ReleaseError(f"main is already at {released}: run scripts/release.py prepare <version> first")
    notes = load_notes(root)
    problems = check_notes(notes, version)
    if problems:
        raise ReleaseError("the notes need another pass:\n" + "\n".join(f"  - {problem}" for problem in problems))
    ahead = git(root, "log", "--format=%s", "origin/dev..HEAD").splitlines()
    behind = git(root, "rev-list", "--count", "HEAD..origin/dev")
    if behind != "0":
        raise ReleaseError("dev has moved on since the release was prepared: rebase the release commit onto origin/dev, and see whether the notes should mention what's new there (scripts/release.py changes --head HEAD)")
    if ahead not in ([], [f"Release {version}"]):
        raise ReleaseError("only the release commit may be ahead of dev here:\n" + "\n".join(f"  {subject}" for subject in ahead))
    merge = subprocess.run(["git", "-C", str(root), "merge-tree", "--write-tree", "origin/main", "HEAD"], text=True, capture_output=True)
    if merge.returncode != 0:
        raise ReleaseError("dev doesn't merge into main cleanly; merge main into dev by hand first:\n" + merge.stdout.strip())
    count = int(git(root, "rev-list", "--count", "--first-parent", "origin/main..HEAD"))
    release = notes["releases"][0]
    print(preview(release))
    print(f"\nRelease {version}: {count} change{'s' if count != 1 else ''} on dev since {released}.")
    steps = ([f"push \"Release {version}\" to dev"] if ahead else []) + ["open the dev -> main pull request"] + ([] if arguments.no_merge else ["merge it: Xcode Cloud builds main for the beta channel"])
    if arguments.dry_run:
        print("Dry run. It would " + ", ".join(steps) + ".")
        return
    if not arguments.yes:
        if not sys.stdin.isatty():
            raise ReleaseError("this publishes; pass --yes once the maintainer has said to strike the release")
        if input(f"This will {', '.join(steps)}. Type {version} to go on: ").strip() != version:
            raise ReleaseError("not struck")
    if ahead:
        git(root, "push", "--quiet", "origin", "HEAD:refs/heads/dev")
    body = pull_request_body(release, count)
    existing = json.loads(gh(root, "pr", "list", "--base", "main", "--head", "dev", "--state", "open", "--json", "number") or "[]")
    if existing:
        number = str(existing[0]["number"])
        gh(root, "pr", "edit", number, "--title", f"Release {version}", "--body", body)
    else:
        url = gh(root, "pr", "create", "--base", "main", "--head", "dev", "--title", f"Release {version}", "--body", body)
        number = url.rstrip("/").rsplit("/", 1)[-1]
    if arguments.no_merge:
        print(f"Pull request #{number} is open; merging it with a merge commit strikes the release.")
        return
    gh(root, "pr", "merge", number, "--merge")
    print(f"Struck {version}: pull request #{number} merged into main. Xcode Cloud takes it from there; pull main where it's checked out.")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command", required=True)
    changes = commands.add_parser("changes", help="what merged into dev since the last release")
    changes.add_argument("--head", default="origin/dev", help="list up to here instead of origin/dev")
    changes.set_defaults(run=command_changes)
    commands.add_parser("check", help="check the notes against their rules and the app's version").set_defaults(run=command_check)
    commands.add_parser("preview", help="print the newest entry as the card lays it out").set_defaults(run=command_preview)
    prepare = commands.add_parser("prepare", help="check the notes for a version, bump the app to it and commit")
    prepare.add_argument("version")
    prepare.add_argument("--date", help="the day it is struck (today)")
    prepare.set_defaults(run=command_prepare)
    strike = commands.add_parser("strike", help="push the release commit, open the dev -> main pull request and merge it")
    strike.add_argument("--yes", action="store_true", help="don't ask: the maintainer has said to strike it")
    strike.add_argument("--dry-run", action="store_true", help="check everything and say what would happen")
    strike.add_argument("--no-merge", action="store_true", help="leave the pull request open")
    strike.set_defaults(run=command_strike)
    arguments = parser.parse_args(argv)
    try:
        arguments.run(arguments.root.resolve(), arguments)
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
