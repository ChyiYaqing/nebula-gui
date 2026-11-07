#!/usr/bin/env python3
"""Inspect trusted build output without starting the GUI or privileged helper."""
import hashlib
from pathlib import Path
import plistlib
import re
import subprocess
import sys

PAYLOADS = (
    "Contents/MacOS/NebulaGUI",
    "Contents/Helpers/nebula-gui-backend",
    "Contents/Helpers/nebula-gui-helper",
)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect(app, version, architectures):
    app = Path(app)
    expected = set(PAYLOADS) | {
        "Contents/Info.plist", "Contents/Resources/AppIcon.icns",
        "Contents/_CodeSignature/CodeResources",
    }
    files = set()
    for path in app.rglob("*"):
        require(not path.is_symlink(), "Unexpected symlink in app")
        if not path.is_dir():
            require(path.is_file(), "Unexpected non-regular payload")
            files.add(path.relative_to(app).as_posix())
    require(files == expected, "Unexpected or missing app payload")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleShortVersionString"] == version.partition("-")[0], "App version mismatch")
    require(info["NebulaReleaseVersion"] == version, "App release version mismatch")
    require(info["CFBundleExecutable"] == "NebulaGUI", "Unexpected executable")
    require(info["LSMinimumSystemVersion"] == "13.0", "Unexpected deployment target")
    binaries = {}
    for name in PAYLOADS:
        path = str(app / name)
        require(set(command("/usr/bin/lipo", "-archs", path).split()) == set(architectures),
                "Payload architecture mismatch: " + name)
        minimums = {}
        for arch in architectures:
            output = command("/usr/bin/xcrun", "vtool", "-arch", arch, "-show-build", path)
            minimum = re.search(r"\bminos\s+([0-9.]+)", output)
            require(minimum is not None, "Missing deployment target: " + name)
            parts = tuple((list(map(int, minimum[1].split("."))) + [0, 0])[:3])
            require(parts <= (13, 0, 0), "Payload requires a newer macOS: " + name)
            minimums[arch] = minimum[1]
        require((app / name).stat().st_mode & 0o111, "Payload is not executable: " + name)
        binaries[name] = {"architectures": sorted(architectures), "minimumSystemVersions": minimums}
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return {
        "binaries": binaries,
        "files": {name: hashlib.sha256((app / name).read_bytes()).hexdigest()
                  for name in sorted(files)},
    }


if __name__ == "__main__":
    import json
    print(json.dumps(inspect(sys.argv[1], sys.argv[2], sys.argv[3:]), indent=2, sort_keys=True))
