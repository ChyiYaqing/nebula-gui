#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1])
configuration = sys.argv[2]
def command(arguments, cwd=root):
    return subprocess.check_output(arguments, cwd=cwd, text=True).strip()
components = {}
for name, argument in (("backend", "metadata"), ("helper", "-metadata")):
    path = app / "Contents/Helpers" / ("nebula-gui-" + name)
    components[name] = json.loads(command([str(path), argument]))
info = plistlib.loads((app/"Contents/Info.plist").read_bytes())
if info.get("CFBundleIconFile") != "AppIcon.icns":
    raise SystemExit("Unexpected app icon declaration")
icon = app/"Contents/Resources/AppIcon.icns"
if not icon.is_file() or icon.is_symlink():
    raise SystemExit("Missing regular app icon")
kernel = command(["git", "rev-parse", "HEAD"], cwd=root.parent/"nebula")
for name, value in components.items():
    if value["component"] != name or value["kernelRevision"] != kernel or value["applicationVersion"] != info["CFBundleShortVersionString"] or value["buildNumber"] != info["CFBundleVersion"]:
        raise SystemExit("component build information mismatch")
if components["backend"]["protocolVersion"] != components["helper"]["protocolVersion"] or components["backend"]["helperRelease"] != components["helper"]["helperRelease"]:
    raise SystemExit("component compatibility mismatch")
manifest = {
    "schema": 1, "distribution": "internal-adhoc", "configuration": configuration,
    "applicationVersion": info["CFBundleShortVersionString"], "buildNumber": info["CFBundleVersion"],
    "declaredMinimumSystemVersion": info["LSMinimumSystemVersion"],
    "sourceRevision": sys.argv[3],
    "sourceDirty": bool(sys.argv[4]) or bool(command(["git", "status", "--porcelain"])) or command(["git", "rev-parse", "HEAD"]) != sys.argv[3],
    "kernelRevision": kernel, "architecture": platform.machine(),
    "swift": command(["swift", "--version"]), "xcode": command(["xcodebuild", "-version"]),
    "components": components,
    "resourceHashes": {"AppIcon.icns": hashlib.sha256(icon.read_bytes()).hexdigest()},
    "helperHashes": {name: hashlib.sha256((app/"Contents/Helpers"/("nebula-gui-"+name)).read_bytes()).hexdigest() for name in components},
}
(app/"Contents/Resources/build-info.json").write_text(json.dumps(manifest, indent=2, sort_keys=True)+"\n")
