#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("snapshot", Path(__file__).with_name("acceptance-snapshot.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SnapshotTests(unittest.TestCase):
    def test_process_allowlist_omits_paths_and_unrelated_commands(self):
        value = module.processes("100 501 /private/test user/Nebula.app/Contents/MacOS/NebulaGUI\n101 0 /Library/nebula-gui-helper\n102 501 /secret/192.0.2.10/private.key\n")
        self.assertEqual(value["gui"], [{"pid": 100, "uid": 501}])
        self.assertEqual(value["helper"], [{"pid": 101, "uid": 0}])
        self.assertNotIn("secret", json.dumps(value))
        self.assertNotIn("Nebula.app", json.dumps(value))
    def test_route_counts_never_export_addresses(self):
        value = module.route_counts("Destination Gateway Flags Netif Expire\n192.0.2.10 192.0.2.1 UG utun7\n198.51.100.2 link#3 UH utun7 3\ndefault 203.0.113.1 UG en0\n")
        self.assertEqual(value, {"utun7": 2})
        self.assertNotIn("192.0.2", json.dumps(value))
    def test_metadata_refuses_replacement_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "component"; target.write_text("component")
            secret = Path(directory) / "private"; secret.write_text("private test data")
            original_open = module.os.open
            def replace(path, flags):
                target.unlink(); target.symlink_to(secret)
                return original_open(path, flags)
            with mock.patch.object(module.os, "open", side_effect=replace):
                value = module.metadata(target)
            self.assertEqual(value["error"], "hash_unavailable")
            self.assertNotIn("sha256", value)
    def test_metadata_does_not_follow_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target"; target.write_text("private test data")
            link = Path(directory) / "link"; link.symlink_to(target)
            value = module.metadata(link)
            self.assertTrue(value["symlink"])
            self.assertNotIn("sha256", value)
            self.assertNotIn("private test data", json.dumps(value))
            self.assertEqual(module.metadata(Path(directory)/"absent"), {"exists": False})

if __name__ == "__main__":
    unittest.main()
