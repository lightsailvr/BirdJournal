"""Which pack the build and pin scripts act on: the one named, never one the script has by heart (#209).

Each test runs a copy of the script in a throwaway repository with its own manifest, and a stand-in `uv` that prints
what it was asked to run instead of building anything.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]


class PackScriptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "packs").mkdir()
        (self.repo / "packbuilder").mkdir()
        for name in ("build-pack.sh", "pin-pack.sh"):
            shutil.copy(SCRIPTS / name, self.repo / "scripts" / name)
        self.manifest = self.repo / "packs" / "manifest.json"
        self.write_manifest(bundled=["the-bundled-one"])
        bin_folder = Path(self.temporary.name) / "bin"
        bin_folder.mkdir()
        uv = bin_folder / "uv"
        uv.write_text('#!/bin/sh\necho "uv $*"\n')
        uv.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{bin_folder}:{os.environ['PATH']}")

    def write_manifest(self, bundled):
        packs = [{"id": "a-download", "bundled": False}] + [{"id": pack_id, "bundled": True} for pack_id in bundled]
        self.manifest.write_text(json.dumps({"packs": packs}))

    def run_script(self, name, *arguments):
        return subprocess.run(["bash", str(self.repo / "scripts" / name), *arguments],
                              text=True, capture_output=True, check=False, env=self.environment)

    def test_build_without_a_pack_id_builds_the_pack_the_manifest_marks_bundled(self):
        result = self.run_script("build-pack.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("packbuilder build packs/the-bundled-one ", result.stdout)
        self.assertIn(f"--out {self.repo}/packs/the-bundled-one ", result.stdout, "the bundled pack goes where the app ships it from")

    def test_build_with_a_pack_id_builds_that_pack_and_passes_the_builders_flags_through(self):
        result = self.run_script("build-pack.sh", "a-download", "--limit", "60")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("packbuilder build packs/a-download ", result.stdout)
        self.assertIn(f"--out {self.repo}/build/packs/a-download ", result.stdout, "a download stays out of the app")
        self.assertTrue(result.stdout.rstrip().endswith("--limit 60"), result.stdout)

    def test_build_without_a_pack_id_refuses_when_the_manifest_does_not_mark_exactly_one_pack_bundled(self):
        for bundled in ([], ["one", "another"]):
            self.write_manifest(bundled=bundled)
            result = self.run_script("build-pack.sh")
            self.assertNotEqual(result.returncode, 0, f"{bundled}: {result.stdout}")
            self.assertNotIn("packbuilder build", result.stdout)
            self.assertIn("scripts/build-pack.sh <pack id>", result.stderr)

    def test_pin_without_a_pack_id_says_how_to_call_it_and_leaves_the_manifest_alone(self):
        before = self.manifest.read_text()
        result = self.run_script("pin-pack.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("scripts/pin-pack.sh <pack id>", result.stderr)
        self.assertEqual(self.manifest.read_text(), before)

    def built_pack(self, pack_id, report):
        """A built pack as the pin script finds it: its zip, its database and its report, with a definition."""
        import sqlite3

        folder = self.repo / "build" / "packs" / pack_id
        folder.mkdir(parents=True)
        (self.repo / "build" / "packs" / f"{pack_id}.zip").write_bytes(b"a zip")
        with sqlite3.connect(folder / "pack.sqlite") as db:
            db.executescript("create table species (id text); create table photo (id text); create table sound (id text);"
                             "create table pack (region text, schema_version integer); insert into pack values ('Somewhere', 5); insert into species values ('a-bird');")
        (folder / "report.json").write_text(json.dumps(report))
        definition = self.repo / "packbuilder" / "packs" / pack_id
        definition.mkdir(parents=True)
        (definition / "pack.json").write_text(json.dumps({"name": "A Download", "version": 3}))

    def test_pin_refuses_a_build_of_some_of_a_packs_birds(self):
        """`packbuilder build --only` (#215) writes a partial pack for a trial: it must never reach the manifest."""
        self.built_pack("a-download", {"pack": "a-download", "partial": {"species": 1, "listed": 300}})
        before = self.manifest.read_text()
        result = self.run_script("pin-pack.sh", "a-download")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("1 of its 300 species", result.stderr)
        self.assertEqual(self.manifest.read_text(), before)

    def test_pin_records_a_whole_build(self):
        self.built_pack("a-download", {"pack": "a-download"})
        result = self.run_script("pin-pack.sh", "a-download")
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = next(pack for pack in json.loads(self.manifest.read_text())["packs"] if pack["id"] == "a-download")
        self.assertEqual((entry["version"], entry["species"], entry["bundled"]), (3, 1, False))


if __name__ == "__main__":
    unittest.main()
