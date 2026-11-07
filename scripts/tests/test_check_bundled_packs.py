"""The build guard rejects stale packs without touching real downloaded artifacts."""

from contextlib import closing
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-bundled-packs.py"


class BundledPackCheckTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.packs = Path(self.temporary.name) / "packs with spaces"
        self.folder = self.packs / "us-ca-la"
        self.folder.mkdir(parents=True)
        (self.packs / "manifest.json").write_text(json.dumps({"packs": [
            {"id": "us-ca-la", "version": 12, "sha256": "pinned-checksum", "bundled": True},
            {"id": "not-bundled", "version": 9, "sha256": "unused", "bundled": False},
        ]}))
        (self.folder / ".unpacked-sha256").write_text("pinned-checksum\n")
        with closing(sqlite3.connect(self.folder / "pack.sqlite")) as connection, connection:
            connection.execute("CREATE TABLE pack (id TEXT, version INTEGER)")
            connection.execute("INSERT INTO pack VALUES ('us-ca-la', 12)")

    def run_check(self, succeeds):
        result = subprocess.run([sys.executable, str(SCRIPT), "--packs-dir", str(self.packs)],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0 if succeeds else 1, result.stderr)
        if not succeeds:
            self.assertIn("scripts/download-pack.sh", result.stderr)
        return result

    def test_matching_bundle_passes_and_unbundled_packs_are_not_required(self):
        self.run_check(True)

    def test_stale_marker_fails_with_the_repair_command(self):
        (self.folder / ".unpacked-sha256").write_text("old-checksum\n")
        self.assertIn("us-ca-la", self.run_check(False).stderr)

    def test_missing_marker_fails(self):
        (self.folder / ".unpacked-sha256").unlink()
        self.run_check(False)

    def test_missing_database_fails_even_with_matching_marker(self):
        (self.folder / "pack.sqlite").unlink()
        self.run_check(False)

    def test_stale_database_fails_even_with_matching_marker(self):
        with closing(sqlite3.connect(self.folder / "pack.sqlite")) as connection, connection:
            connection.execute("UPDATE pack SET version = 11")
        self.run_check(False)

    def test_invalid_database_fails(self):
        (self.folder / "pack.sqlite").write_text("not SQLite")
        self.run_check(False)


if __name__ == "__main__":
    unittest.main()
