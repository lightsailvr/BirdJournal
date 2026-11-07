"""Build identity integration tests: python3 -m unittest discover -s scripts/tests -p test_build_info.py."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/generate-build-info.py"


class BuildInfoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.repository = self.folder / "repository"
        self.repository.mkdir()
        self.source = self.folder / "source.plist"
        self.output = self.folder / "derived/Info.plist"
        self.source.write_bytes(plistlib.dumps({"Keep": "$(PRODUCT_BUNDLE_IDENTIFIER)"}))
        self.git("init", "-q")
        (self.repository / "app.swift").write_text("first\n")
        self.git("add", "app.swift")
        self.git("-c", "user.name=Build Test", "-c", "user.email=build@example.invalid", "commit", "-qm", "baseline")
        self.environment = dict(os.environ)
        for key in ["CI_XCODE_CLOUD", "CI_BUILD_NUMBER"]:
            self.environment.pop(key, None)
        self.environment.update(MARKETING_VERSION="0.1.0", CURRENT_PROJECT_VERSION="1")

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.repository), *arguments], text=True).strip()

    def generate(self, repository=None, **environment):
        result = subprocess.run(
            ["python3", str(SCRIPT), str(self.source), str(self.output), str(repository or self.repository)],
            env=self.environment | environment, text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return plistlib.loads(self.output.read_bytes())

    def test_clean_local_build_and_unchanged_output(self):
        info = self.generate()
        self.assertEqual(info["BirdJournalBuildCommit"], self.git("rev-parse", "--short=7", "HEAD"))
        self.assertEqual((info["CFBundleShortVersionString"], info["CFBundleVersion"]), ("0.1.0", "1"))
        self.assertEqual(info["Keep"], "$(PRODUCT_BUNDLE_IDENTIFIER)")
        stamp = self.output.stat().st_mtime_ns
        self.generate()
        self.assertEqual(self.output.stat().st_mtime_ns, stamp)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_dirty_unstaged_staged_and_untracked_source(self):
        (self.repository / "app.swift").write_text("changed\n")
        self.assertTrue(self.generate()["BirdJournalBuildCommit"].endswith("-dirty"))
        self.git("add", "app.swift")
        self.assertTrue(self.generate()["BirdJournalBuildCommit"].endswith("-dirty"))
        self.git("reset", "--hard", "-q", "HEAD")
        (self.repository / "new.swift").write_text("new\n")
        self.assertTrue(self.generate()["BirdJournalBuildCommit"].endswith("-dirty"))

    def test_cloud_build_removes_local_identity_and_uses_shared_number(self):
        self.generate()
        for source in [{"App": True}, {"NSExtension": {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}}]:
            self.source.write_bytes(plistlib.dumps(source | {"BirdJournalBuildCommit": "stale-local"}))
            info = self.generate(CI_XCODE_CLOUD="TRUE", CI_BUILD_NUMBER="42")
            self.assertNotIn("BirdJournalBuildCommit", info)
            self.assertEqual(info["CFBundleVersion"], "42")
            self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
            for key, value in source.items():
                self.assertEqual(info[key], value)

    def test_cloud_without_number_fails_instead_of_publishing_local_number(self):
        result = subprocess.run(
            ["python3", str(SCRIPT), str(self.source), str(self.output), str(self.repository)],
            env=self.environment | {"CI_XCODE_CLOUD": "TRUE"}, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_missing_or_enclosing_repository_is_unknown(self):
        self.assertEqual(self.generate(repository=self.folder)["BirdJournalBuildCommit"], "unknown")
        subfolder = self.repository / "not-a-repository"
        subfolder.mkdir()
        self.assertEqual(self.generate(repository=subfolder)["BirdJournalBuildCommit"], "unknown")

    def test_app_widget_and_test_targets_inherit_the_one_version_file(self):
        project = json.loads(subprocess.check_output(
            ["plutil", "-convert", "json", "-o", "-", str(ROOT / "BirdJournal/BirdJournal.xcodeproj/project.pbxproj")]
        ))["objects"]
        configurations = [value for value in project.values() if value.get("isa") == "XCBuildConfiguration"]
        version_files = []
        for configuration in configurations:
            self.assertNotIn("MARKETING_VERSION", configuration["buildSettings"])
            self.assertNotIn("CURRENT_PROJECT_VERSION", configuration["buildSettings"])
            if reference := configuration.get("baseConfigurationReference"):
                version_files.append(project[reference]["path"])
        self.assertEqual(version_files, ["Version.xcconfig", "Version.xcconfig"])
        generated = [value for value in configurations if "BIRDJOURNAL_SOURCE_INFOPLIST" in value["buildSettings"]]
        self.assertEqual(len(generated), 4)
        for configuration in generated:
            self.assertEqual(configuration["buildSettings"]["INFOPLIST_FILE"], "$(DERIVED_FILE_DIR)/BuildIdentity-Info.plist")


if __name__ == "__main__":
    unittest.main()
