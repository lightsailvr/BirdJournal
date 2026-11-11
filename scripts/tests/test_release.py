"""Release script tests, on a throwaway repository with a bare "GitHub" and a stand-in gh:
python3 -m unittest discover -s scripts/tests -p test_release.py."""
import copy
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/release.py"
sys.path.insert(0, str(ROOT / "scripts"))
import release  # noqa: E402

# Records what it was asked and answers as GitHub would: no open pull request, then the one it "created".
FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list") echo "${GH_OPEN_PRS:-[]}" ;;
  "pr create") echo "https://github.com/lightsailvr/BirdJournal/pull/200" ;;
  "pr view") echo '{"title": "Guilds for everyone", "body": "Turns the account on."}' ;;
esac
"""


def entry(version, **changes):
    base = {
        "version": version,
        "date": "2026-11-07",
        "headline": "Guilds open their doors",
        "items": [
            {"title": "Guilds are open", "detail": "Sign in to start a Guild with friends.", "try": "Start a Guild and invite a tester."},
            {"title": "A quicker start", "detail": "The app opens faster."},
        ],
        "note": "Seen something odd? Take a screenshot.",
    }
    return base | changes


class NotesRulesTests(unittest.TestCase):
    def problems(self, *releases, app_version=None):
        return release.check_notes({"releases": list(releases)}, app_version)

    def test_the_repository_notes_pass_and_match_the_app(self):
        notes = json.loads((ROOT / release.NOTES).read_text(encoding="utf-8"))
        version = release.marketing_version((ROOT / release.XCCONFIG).read_text())
        self.assertEqual(release.check_notes(notes, version), [])

    def test_a_good_entry_passes(self):
        self.assertEqual(self.problems(entry("0.2.0"), entry("0.1.0"), app_version="0.2.0"), [])

    def test_the_newest_entry_is_for_the_app_version(self):
        self.assertIn("the newest entry is for 0.1.0 and the app is 0.2.0", " ".join(self.problems(entry("0.1.0"), app_version="0.2.0")))

    def test_releases_go_newest_first_once_each(self):
        self.assertIn("newest first", " ".join(self.problems(entry("0.1.0"), entry("0.2.0"))))
        self.assertIn("newest first", " ".join(self.problems(entry("0.2.0"), entry("0.2.0"))))

    def test_copy_is_for_birders(self):
        def with_detail(text):
            changed = copy.deepcopy(entry("0.2.0"))
            changed["items"][0]["detail"] = text
            return " ".join(self.problems(changed))

        self.assertIn("#184", with_detail("Guilds are on (#184)."))
        self.assertIn("for the people who build the app", with_detail("A refactor of the SwiftUI views."))
        self.assertIn("BirdJournal", with_detail("BirdJournal opens faster."))
        self.assertIn("typographic quotes", with_detail("Your friends' finds."))
        self.assertIn("ends like one", with_detail("The app opens faster"))
        self.assertIn("room for 170", with_detail("Long " * 40 + "detail."))
        self.assertEqual(with_detail("Your friends’ finds, as they happen."), "")

    def test_headings_and_counts(self):
        self.assertIn("no full stop", " ".join(self.problems(entry("0.2.0", headline="Guilds open."))))
        self.assertIn("between 1 and 6", " ".join(self.problems(entry("0.2.0", items=[]))))
        many = [{"title": f"Change {n}", "detail": "It changed."} for n in range(7)]
        self.assertIn("between 1 and 6", " ".join(self.problems(entry("0.2.0", items=many))))
        twice = [{"title": "Same", "detail": "It changed."}] * 2
        self.assertIn("share a title", " ".join(self.problems(entry("0.2.0", items=twice))))
        self.assertIn("2026-11-07", " ".join(self.problems(entry("0.2.0", date="November 7"))))
        self.assertIn("unknown keys", " ".join(self.problems(entry("0.2.0", symbol="star"))))

    def test_optional_lines_can_be_left_out(self):
        bare = {"version": "0.2.0", "date": "2026-11-07", "items": [{"title": "One thing", "detail": "It changed."}]}
        self.assertEqual(self.problems(bare), [])

    def test_the_preview_reads_like_the_card(self):
        text = release.preview(entry("0.2.0"))
        self.assertIn("VERSION 0.2.0", text)
        self.assertIn("1  Guilds are open", text)
        self.assertIn("Try it: Start a Guild and invite a tester.", text)
        self.assertNotIn("Try it: None", text)


class ReleaseFlowTests(unittest.TestCase):
    """A bare repository stands in for GitHub: main at the last release, dev two changes ahead."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        folder = Path(self.temporary.name).resolve()
        self.origin = folder / "origin.git"
        self.repository = folder / "checkout"
        self.gh_log = folder / "gh.log"
        tools = folder / "bin"
        tools.mkdir()
        fake = tools / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.environment = dict(os.environ) | {
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}", "GH_LOG": str(self.gh_log),
            "GIT_AUTHOR_NAME": "Release Test", "GIT_AUTHOR_EMAIL": "release@example.invalid",
            "GIT_COMMITTER_NAME": "Release Test", "GIT_COMMITTER_EMAIL": "release@example.invalid",
        }
        subprocess.check_call(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)])
        subprocess.check_call(["git", "init", "-q", "-b", "main", str(self.repository)])
        self.git("remote", "add", "origin", str(self.origin))
        self.write(release.XCCONFIG, "// Bump the marketing version when striking a release from dev to main.\nMARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = $(CI_BUILD_NUMBER:default=1)\n")
        self.write_notes(entry("0.1.0"))
        self.commit("First beta")
        self.git("push", "-q", "origin", "main")
        self.git("checkout", "-q", "-b", "dev")
        self.write("app.swift", "guilds\n")
        self.commit("Merge pull request #184 from lightsailvr/feature/guilds\n\nTurn on the account")
        self.write("app.swift", "guilds\nspeed\n")
        self.commit("A faster start (#183)")
        self.git("push", "-q", "origin", "dev")
        self.git("checkout", "-q", "--detach", "origin/dev")

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments], text=True, env=self.environment).strip()

    def write(self, path, text):
        target = self.repository / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def write_notes(self, *releases):
        self.write(release.NOTES, json.dumps({"releases": list(releases)}, indent=2, ensure_ascii=False) + "\n")

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)

    def run_script(self, *arguments, stdin=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.repository), *arguments],
            env=self.environment, text=True, capture_output=True, input=stdin,
        )

    def gh_calls(self):
        return self.gh_log.read_text().splitlines() if self.gh_log.exists() else []

    def prepare(self):
        self.write_notes(entry("0.2.0", date="2026-01-01", note="It’s here."), entry("0.1.0"))
        result = self.run_script("prepare", "0.2.0", "--date", "2026-11-11")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_changes_lists_what_merged_since_main(self):
        result = self.run_script("changes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("since 0.1.0 was struck", result.stdout)
        # The pull requests by their titles on GitHub; both kinds of merge are found.
        self.assertIn("## #184 Guilds for everyone", result.stdout)
        self.assertIn("## #183 Guilds for everyone", result.stdout)
        self.assertIn("Turns the account on.", result.stdout)
        self.assertEqual((self.repository / "build/release/changes.md").read_text() + "\n", result.stdout)

    def test_changes_without_gh_falls_back_to_the_commits(self):
        self.environment["PATH"] = "/usr/bin:/bin"
        result = self.run_script("changes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("## #184 Turn on the account", result.stdout)
        self.assertIn("## #183 A faster start (#183)", result.stdout)

    def test_prepare_needs_the_entry_first(self):
        result = self.run_script("prepare", "0.2.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("write the entry for 0.2.0", result.stderr)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_prepare_refuses_bad_notes_an_old_version_and_other_changes(self):
        self.write_notes(entry("0.2.0", headline="Fixes #12"), entry("0.1.0"))
        result = self.run_script("prepare", "0.2.0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("#12", result.stderr)
        self.assertIn("MARKETING_VERSION = 0.1.0", (self.repository / release.XCCONFIG).read_text())
        self.assertIn("isn't after", self.run_script("prepare", "0.1.0").stderr)
        self.write_notes(entry("0.2.0"), entry("0.1.0"))
        self.write("app.swift", "something else\n")
        self.assertIn("app.swift", self.run_script("prepare", "0.2.0").stderr)

    def test_prepare_wants_dev_as_github_has_it(self):
        self.git("checkout", "-q", "--detach", "origin/main")
        self.write_notes(entry("0.2.0"), entry("0.1.0"))
        self.assertIn("check out origin/dev", self.run_script("prepare", "0.2.0").stderr)

    def test_prepare_dates_bumps_and_commits_without_pushing(self):
        result = self.prepare()
        self.assertIn("VERSION 0.2.0", result.stdout)
        self.assertEqual(self.git("log", "-1", "--format=%s"), "Release 0.2.0")
        self.assertEqual(self.git("show", "--name-only", "--format=", "HEAD").splitlines(), sorted([release.NOTES, release.XCCONFIG]))
        text = (self.repository / release.XCCONFIG).read_text()
        self.assertIn("MARKETING_VERSION = 0.2.0\n", text)
        self.assertIn("CURRENT_PROJECT_VERSION = $(CI_BUILD_NUMBER:default=1)", text)
        notes = json.loads((self.repository / release.NOTES).read_text(encoding="utf-8"))
        self.assertEqual(notes["releases"][0]["date"], "2026-11-11")
        # Rewritten as it was written: the apostrophes stay apostrophes.
        self.assertIn("It’s here.", (self.repository / release.NOTES).read_text(encoding="utf-8"))
        self.assertEqual(self.git("rev-list", "--count", "origin/dev..HEAD"), "1")
        self.assertEqual(self.gh_calls(), [])

    def test_strike_needs_a_prepared_release(self):
        result = self.run_script("strike", "--yes")
        self.assertEqual(result.returncode, 1)
        self.assertIn("run scripts/release.py prepare", result.stderr)

    def test_strike_dry_run_and_unanswered_publish_nothing(self):
        self.prepare()
        dry = self.run_script("strike", "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertIn("3 changes on dev since 0.1.0", dry.stdout)
        self.assertIn("Dry run", dry.stdout)
        # Not a terminal and no --yes: it doesn't publish on its own say-so.
        unanswered = self.run_script("strike")
        self.assertEqual(unanswered.returncode, 1)
        self.assertIn("--yes", unanswered.stderr)
        self.assertEqual(self.git("rev-list", "--count", "origin/dev..HEAD"), "1")
        self.assertEqual(self.gh_calls(), [])

    def test_strike_pushes_dev_and_opens_and_merges_the_pull_request(self):
        self.prepare()
        result = self.run_script("strike", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.git("fetch", "-q", "origin")
        self.assertEqual(self.git("log", "-1", "--format=%s", "origin/dev"), "Release 0.2.0")
        calls = self.gh_calls()
        self.assertTrue(calls[0].startswith("pr list --base main --head dev --state open"))
        self.assertTrue(calls[1].startswith("pr create --base main --head dev --title Release 0.2.0 --body Release 0.2.0: 3 changes"), calls[1])
        self.assertIn("**Guilds are open.** Sign in to start a Guild with friends. *Try it: Start a Guild and invite a tester.*", self.gh_log.read_text())
        self.assertEqual(calls[-1], "pr merge 200 --merge")
        self.assertIn("Struck 0.2.0", result.stdout)

    def test_strike_reuses_an_open_pull_request_and_can_leave_it_open(self):
        self.prepare()
        self.environment["GH_OPEN_PRS"] = '[{"number": 199}]'
        result = self.run_script("strike", "--yes", "--no-merge")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.gh_calls()
        self.assertTrue(calls[1].startswith("pr edit 199 --title Release 0.2.0"))
        self.assertFalse(any(call.startswith("pr merge") or call.startswith("pr create") for call in calls))

    def test_strike_stops_when_dev_moved_or_would_conflict(self):
        self.prepare()
        release_commit = self.git("rev-parse", "HEAD")
        # Someone merges into dev after the release was prepared.
        self.git("checkout", "-q", "--detach", "origin/dev")
        self.write("late.swift", "late\n")
        self.commit("A late change (#190)")
        self.git("push", "-q", "origin", "HEAD:dev")
        self.git("checkout", "-q", "--detach", release_commit)
        moved = self.run_script("strike", "--yes")
        self.assertEqual(moved.returncode, 1)
        self.assertIn("dev has moved on", moved.stderr)

        # And main gains a change of its own that dev's can't merge with.
        self.git("checkout", "-q", "--detach", "origin/main")
        self.write("app.swift", "hotfix\n")
        self.commit("A hotfix on main")
        self.git("push", "-q", "origin", "HEAD:main")
        self.git("checkout", "-q", "--detach", "origin/dev")
        self.write_notes(entry("0.2.0"), entry("0.1.0"))
        self.assertEqual(self.run_script("prepare", "0.2.0").returncode, 0)
        conflict = self.run_script("strike", "--yes")
        self.assertEqual(conflict.returncode, 1)
        self.assertIn("doesn't merge into main cleanly", conflict.stderr)
        self.assertEqual(self.gh_calls(), [])


if __name__ == "__main__":
    unittest.main()
