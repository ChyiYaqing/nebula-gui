#!/usr/bin/env python3
"""Verify a trusted local build; does not install or contact the running helper."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
def command(arguments):
    return subprocess.check_output(arguments, text=True).strip()
def require(condition, message):
    if not condition: raise SystemExit(message)
def version(value):
    return tuple((list(map(int, value.split(".")))+[0,0,0])[:3])
expected_files = {
    "Contents/Info.plist", "Contents/MacOS/NebulaGUI",
    "Contents/Helpers/nebula-gui-backend", "Contents/Helpers/nebula-gui-helper",
    "Contents/Resources/build-info.json", "Contents/Resources/AppIcon.icns",
    "Contents/_CodeSignature/CodeResources",
}
expected_directories = {"Contents", "Contents/MacOS", "Contents/Helpers", "Contents/Resources", "Contents/_CodeSignature"}
files, directories = set(), set()
for path in app.rglob("*"):
    require(not path.is_symlink(), "Unexpected symbolic link in app")
    relative = path.relative_to(app).as_posix()
    if path.is_dir():
        directories.add(relative)
    else:
        require(path.is_file(), "Unexpected non-regular payload")
        files.add(relative)
require(files == expected_files and directories == expected_directories, "Unexpected app contents or missing payload")
info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
require(info["CFBundleExecutable"] == "NebulaGUI", "Unexpected app executable")
require(info.get("CFBundleIconFile") == "AppIcon.icns", "Unexpected app icon declaration")
manifest = json.loads((app/"Contents/Resources/build-info.json").read_text())
icon_digest = hashlib.sha256((app/"Contents/Resources/AppIcon.icns").read_bytes()).hexdigest()
require(manifest.get("resourceHashes") == {"AppIcon.icns": icon_digest}, "App icon hash mismatch")
require(manifest["components"]["backend"]["protocolVersion"] == manifest["components"]["helper"]["protocolVersion"] == 1, "Unsupported component protocol")
require(manifest["components"]["backend"]["helperRelease"] == manifest["components"]["helper"]["helperRelease"], "Helper release mismatch")
require(manifest["schema"] == 1 and manifest["distribution"] == "internal-adhoc", "Unsupported build manifest")
require(manifest["applicationVersion"] == info["CFBundleShortVersionString"] and manifest["buildNumber"] == info["CFBundleVersion"], "App version mismatch")
require(manifest["declaredMinimumSystemVersion"] == info["LSMinimumSystemVersion"], "Minimum system version mismatch")
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
report = {"schema": 1, "distribution": "internal-adhoc", "applicationVersion": manifest["applicationVersion"],
          "buildNumber": manifest["buildNumber"], "sourceRevision": manifest["sourceRevision"],
          "sourceDirty": manifest["sourceDirty"], "configuration": manifest["configuration"], "binaries": {},
          "resources": {name: hashlib.sha256((app/name).read_bytes()).hexdigest()
                        for name in sorted(expected_files) if name not in {
                            "Contents/MacOS/NebulaGUI", "Contents/Helpers/nebula-gui-backend", "Contents/Helpers/nebula-gui-helper"}}}
for name, path, argument in (("gui", app/"Contents/MacOS/NebulaGUI", None),
                             ("backend", app/"Contents/Helpers/nebula-gui-backend", "metadata"),
                             ("helper", app/"Contents/Helpers/nebula-gui-helper", "-metadata")):
    require(path.is_file() and not path.is_symlink(), "Missing regular payload")
    architectures = command(["/usr/bin/lipo", "-archs", str(path)]).split()
    require(architectures == [manifest["architecture"]], "Payload architecture mismatch")
    minimum = re.search(r"\bminos\s+([0-9.]+)", command(["/usr/bin/xcrun", "vtool", "-show-build", str(path)]))
    require(minimum is not None and version(minimum[1]) <= version(info["LSMinimumSystemVersion"]), "Payload requires a newer macOS than Info.plist declares")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if argument:
        metadata = json.loads(command([str(path), argument]))
        require(metadata["applicationVersion"] == manifest["applicationVersion"] and metadata["buildNumber"] == manifest["buildNumber"], "Component application version mismatch")
        require(metadata == manifest["components"][name], "Embedded component metadata mismatch")
        require(metadata["kernelRevision"] == manifest["kernelRevision"] and digest == manifest["helperHashes"][name], "Embedded kernel or payload hash mismatch")
    report["binaries"][name] = {"architectures": architectures, "minimumSystemVersion": minimum[1], "sha256": digest}
print(json.dumps(report, indent=2, sort_keys=True))
