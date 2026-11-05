#!/usr/bin/env python3
"""Read-only, allowlisted context for manual macOS acceptance. No config or socket RPC."""
import collections
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

COMPONENTS = {"NebulaGUI": "gui", "nebula-gui-backend": "backend", "nebula-gui-helper": "helper"}
PATHS = {
    "helper": "/Library/PrivilegedHelperTools/net.nebula.gui/nebula-gui-helper",
    "service": "/Library/LaunchDaemons/net.nebula.gui.helper.plist",
    "socket": "/private/var/run/nebula-gui/helper.sock",
}


def processes(text):
    result = {name: [] for name in COMPONENTS.values()}
    for line in text.splitlines():
        fields = line.split(None, 2)
        if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        component = COMPONENTS.get(Path(fields[2]).name)
        if component:
            result[component].append({"pid": int(fields[0]), "uid": int(fields[1])})
    return result


def route_counts(text):
    counts = collections.Counter()
    interface_column = None
    for line in text.splitlines():
        fields = line.split()
        if "Netif" in fields:
            interface_column = fields.index("Netif")
        elif interface_column is not None and len(fields) > interface_column:
            interface = fields[interface_column]
            if re.fullmatch(r"utun[0-9]+", interface):
                counts[interface] += 1
    return dict(sorted(counts.items()))


def metadata(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"exists": False}
    except OSError:
        return {"error": "metadata_unavailable"}
    result = {"exists": True, "uid": info.st_uid, "mode": oct(stat.S_IMODE(info.st_mode)),
              "symlink": stat.S_ISLNK(info.st_mode), "regular": stat.S_ISREG(info.st_mode)}
    if result["regular"]:
        try:
            # Fixed installed component paths only; never reads profile storage.
            with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as source:
                opened = os.fstat(source.fileno())
                if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    result["error"] = "file_changed"
                    return result
                digest = hashlib.sha256()
                for block in iter(lambda: source.read(65536), b""):
                    digest.update(block)
            result["sha256"] = digest.hexdigest()
        except OSError:
            result["error"] = "hash_unavailable"
    return result


def snapshot():
    failures = []
    def read(label, arguments):
        try:
            return subprocess.run(arguments, text=True, capture_output=True, check=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            failures.append(label)
            return ""
    system = read("system", ["/usr/bin/sw_vers"])
    fields = dict(line.split(":", 1) for line in system.splitlines() if ":" in line)
    result = {
        "schema": 1,
        "kind": "read_only_system_context",
        "observedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "system": {key: fields.get(key, "").strip() for key in ("ProductVersion", "BuildVersion")},
        "architecture": os.uname().machine,
        "processes": processes(read("processes", ["/bin/ps", "-ww", "-axo", "pid=,uid=,comm="])),
        "allUtunRouteCounts": {
            "ipv4": route_counts(read("routes_ipv4", ["/usr/sbin/netstat", "-rn", "-f", "inet"])),
            "ipv6": route_counts(read("routes_ipv6", ["/usr/sbin/netstat", "-rn", "-f", "inet6"])),
        },
        "installed": {name: metadata(path) for name, path in PATHS.items()},
        "unavailable": failures,
    }
    return result


if __name__ == "__main__":
    print(json.dumps(snapshot(), indent=2, sort_keys=True))
