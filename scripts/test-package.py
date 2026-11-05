#!/usr/bin/env python3
"""Negative checks on copies of a trusted locally built app; no installation."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parent.parent
app=Path(sys.argv[1]).resolve()
verify=[sys.executable, str(root/"scripts/verify-app.py")]
subprocess.run(verify+[str(app)], check=True, stdout=subprocess.DEVNULL)
with tempfile.TemporaryDirectory(prefix="nebula-package-tests-") as temporary:
    copy=Path(temporary)/"Nebula.app"
    shutil.copytree(app, copy, symlinks=True)
    info_path=copy/"Contents/Info.plist"
    manifest_path=copy/"Contents/Resources/build-info.json"
    icon_path=copy/"Contents/Resources/AppIcon.icns"
    original_info=info_path.read_bytes(); original_manifest=manifest_path.read_bytes()
    original_icon=icon_path.read_bytes()
    def reset():
        info_path.write_bytes(original_info); manifest_path.write_bytes(original_manifest)
        icon_path.write_bytes(original_icon)
    def reject(reason):
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(copy)], check=True, capture_output=True)
        result=subprocess.run(verify+[str(copy)], text=True, capture_output=True)
        if result.returncode == 0 or reason not in result.stdout+result.stderr:
            raise SystemExit("Negative package check did not reject: "+reason)
        print("PASS reject: "+reason)
    info=plistlib.loads(original_info); info["CFBundleVersion"]="99999"
    info_path.write_bytes(plistlib.dumps(info)); reject("App version mismatch")
    reset(); manifest=json.loads(original_manifest)
    manifest["components"]["helper"]["protocolVersion"] += 1
    manifest_path.write_text(json.dumps(manifest)); reject("Unsupported component protocol")
    reset(); info=plistlib.loads(original_info); manifest=json.loads(original_manifest)
    info["LSMinimumSystemVersion"]="10.0"; manifest["declaredMinimumSystemVersion"]="10.0"
    info_path.write_bytes(plistlib.dumps(info)); manifest_path.write_text(json.dumps(manifest))
    reject("Payload requires a newer macOS")
    reset(); manifest=json.loads(original_manifest); manifest["architecture"]="invalid-architecture"
    manifest_path.write_text(json.dumps(manifest)); reject("Payload architecture mismatch")
    reset(); info=plistlib.loads(original_info); info["CFBundleIconFile"]="Other.icns"
    info_path.write_bytes(plistlib.dumps(info)); reject("Unexpected app icon declaration")
    reset(); icon_path.write_bytes(original_icon+b"changed")
    reject("App icon hash mismatch")
    reset(); icon_path.unlink()
    reject("Unexpected app contents or missing payload")
    reset(); extra=copy/"Contents/Resources/unexpected.txt"; extra.write_text("unexpected")
    reject("Unexpected app contents or missing payload")
    extra.unlink(); reset(); extra.mkdir()
    reject("Unexpected app contents or missing payload")
    extra.rmdir(); reset(); extra.symlink_to("AppIcon.icns")
    reject("Unexpected symbolic link in app")
