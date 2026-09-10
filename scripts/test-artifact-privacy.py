#!/usr/bin/env python3
"""Exercise the privacy gate through real files, binary strings, and metadata."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class ArtifactPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifact = self.root / "VoxKey.app"
        self.artifact.mkdir()
        self.file = self.artifact / "payload"
        self.file.write_bytes(b"Public application content")

    def run_scan(self, target=None, **environment):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("verify-artifact-privacy.py")),
             str(target or self.artifact)],
            env={**os.environ, **environment}, capture_output=True, text=True,
        )

    def test_clean_bundle_and_internal_symlink(self):
        (self.artifact / "link").symlink_to("payload")
        self.assertEqual(self.run_scan().returncode, 0)

    def test_binary_home_paths_in_multiple_encodings(self):
        for encoding in ("utf-8", "utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                self.file.write_bytes(b"\x00\xff" + "/Users/build-example/source".encode(encoding))
                result = self.run_scan()
                self.assertEqual(result.returncode, 1)
                self.assertIn("home directory", result.stderr)
                self.assertNotIn("build-example", result.stderr)

    def test_private_denylist_does_not_echo_the_term(self):
        denylist = self.root / "private-terms.txt"
        denylist.write_text("PrivateExampleOrganization\n")
        self.file.write_bytes(b"privateexampleorganization")
        result = self.run_scan(VOXKEY_PRIVACY_DENYLIST=str(denylist))
        self.assertEqual(result.returncode, 1)
        self.assertIn("private identifier", result.stderr)
        self.assertNotIn("privateexampleorganization", result.stderr)

    def test_current_checkout_path_is_rejected(self):
        self.file.write_text(str(Path(__file__).resolve().parent.parent / "Sources"))
        self.assertEqual(self.run_scan().returncode, 1)

    def test_runtime_temporary_filename_is_allowed(self):
        # Sparkle creates an installer icon at runtime with this mkstemp template.
        self.file.write_bytes(b"/tmp/XXXXXX.png\0")
        self.assertEqual(self.run_scan().returncode, 0)

    def test_extended_attributes_are_scanned(self):
        subprocess.run(["xattr", "-w", "com.voxkey.test", "/home/build-example/source", str(self.file)], check=True)
        self.assertEqual(self.run_scan().returncode, 1)

    def test_external_symlink_is_rejected(self):
        (self.artifact / "external").symlink_to(self.root)
        self.assertEqual(self.run_scan().returncode, 1)

    def test_install_shortcut_is_allowed(self):
        (self.artifact / "Applications").symlink_to("/Applications")
        self.assertEqual(self.run_scan().returncode, 0)

    def test_compressed_container_requires_unpacking(self):
        container = self.root / "release.dmg"
        container.write_bytes(b"compressed content")
        self.assertEqual(self.run_scan(container).returncode, 2)


if __name__ == "__main__":
    unittest.main()
