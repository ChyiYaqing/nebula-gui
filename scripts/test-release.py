#!/usr/bin/env python3
"""Negative checks against a real, freshly packaged Universal App."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
VERSION = (ROOT / "VERSION").read_text().strip()
SPEC = importlib.util.spec_from_file_location("verify_release", ROOT / "scripts/verify-release.py")
VERIFY = importlib.util.module_from_spec(SPEC)
sys.dont_write_bytecode = True
SPEC.loader.exec_module(VERIFY)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / ".build/release")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Nebula.app"
        archive = ROOT / f"build/Release/v{VERSION}/Nebula-v{VERSION}-macos-universal.zip"
        subprocess.run(["ditto", "-x", "-k", str(archive), self.temp.name], check=True)

    def inspect(self, version=VERSION, architectures=("arm64", "x86_64")):
        return VERIFY.inspect(self.app, version, architectures)

    def test_wrong_version(self):
        with self.assertRaisesRegex(ValueError, "version mismatch"):
            self.inspect(version="999.0.0")

    def test_wrong_architecture(self):
        with self.assertRaisesRegex(ValueError, "architecture mismatch"):
            self.inspect(architectures=("arm64",))

    def test_newer_deployment_target(self):
        path = self.app / VERIFY.PAYLOADS[2]
        modified = Path(self.temp.name) / "newer-helper"
        subprocess.run(["xcrun", "vtool", "-arch", "x86_64", "-set-build-version", "macos",
                        "14.0", "14.0", "-replace", "-output", str(modified), str(path)], check=True)
        modified.replace(path)
        with self.assertRaisesRegex(ValueError, "requires a newer macOS"):
            self.inspect()

    def test_missing_helper(self):
        (self.app / VERIFY.PAYLOADS[2]).unlink()
        with self.assertRaisesRegex(ValueError, "missing app payload"):
            self.inspect()

    def test_modified_signed_resource(self):
        with (self.app / "Contents/Resources/AppIcon.icns").open("ab") as stream:
            stream.write(b"modified")
        with self.assertRaises(subprocess.CalledProcessError):
            self.inspect()

    def test_symlink_payload(self):
        path = self.app / VERIFY.PAYLOADS[2]
        path.unlink()
        path.symlink_to("/usr/bin/true")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.inspect()

    def test_tag_mismatch_before_build(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/package-release.sh"), "v999.0.0"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release tag must equal", result.stderr)


if __name__ == "__main__":
    unittest.main()
