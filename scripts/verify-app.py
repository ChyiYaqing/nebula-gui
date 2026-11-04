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
info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
require(info["CFBundleExecutable"] == "NebulaGUI", "Unexpected app executable")
manifest = json.loads((app/"Contents/Resources/build-info.json").read_text())
require(manifest["components"]["backend"]["protocolVersion"] == manifest["components"]["helper"]["protocolVersion"] == 1, "Unsupported component protocol")
require(manifest["components"]["backend"]["helperRelease"] == manifest["components"]["helper"]["helperRelease"], "Helper release mismatch")
require(manifest["schema"] == 1 and manifest["distribution"] == "internal-adhoc", "Unsupported build manifest")
require(manifest["applicationVersion"] == info["CFBundleShortVersionString"] and manifest["buildNumber"] == info["CFBundleVersion"], "App version mismatch")
require(manifest["declaredMinimumSystemVersion"] == info["LSMinimumSystemVersion"], "Minimum system version mismatch")
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
report = {"schema": 1, "distribution": "internal-adhoc", "applicationVersion": manifest["applicationVersion"],
          "buildNumber": manifest["buildNumber"], "sourceRevision": manifest["sourceRevision"],
          "sourceDirty": manifest["sourceDirty"], "configuration": manifest["configuration"], "binaries": {}}
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
