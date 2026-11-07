#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "Invalid application version" >&2; exit 1; }
TAG="${1:-v$VERSION}"
[ "$TAG" = "v$VERSION" ] || { echo "Release tag must equal v$VERSION" >&2; exit 1; }
OUTPUT="$ROOT/build/Release/$TAG"
[ ! -e "$OUTPUT" ] || { echo "Release output already exists: $OUTPUT" >&2; exit 1; }
mkdir -p "$ROOT/.build/release" "$OUTPUT"
STAGING="$(mktemp -d "$ROOT/.build/release/package.XXXXXX")"
MOUNT="$STAGING/mount"
trap 'if mount | grep -Fq " on $MOUNT ("; then hdiutil detach "$MOUNT"; fi; rm -rf "$STAGING"' EXIT
for ARCH in arm64 x86_64; do
  APP="$STAGING/$ARCH/Nebula.app"
  NEBULA_GUI_BUILD_CONFIGURATION=release NEBULA_GUI_BUILD_ARCH="$ARCH" \
    NEBULA_GUI_APP_OUTPUT="$APP" bash "$ROOT/scripts/build.sh"
  python3 "$ROOT/scripts/verify-release.py" "$APP" "$VERSION" "$ARCH" > "$STAGING/$ARCH.json"
done
mkdir "$STAGING/image"
APP="$STAGING/image/Nebula.app"
ditto "$STAGING/arm64/Nebula.app" "$APP"
for PAYLOAD in Contents/MacOS/NebulaGUI Contents/Helpers/nebula-gui-backend Contents/Helpers/nebula-gui-helper; do
  lipo -create "$STAGING/arm64/Nebula.app/$PAYLOAD" "$STAGING/x86_64/Nebula.app/$PAYLOAD" -output "$APP/$PAYLOAD"
done
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-backend"
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-helper"
codesign --force --sign - "$APP"
python3 "$ROOT/scripts/verify-release.py" "$APP" "$VERSION" arm64 x86_64 > "$STAGING/universal.json"
NAME="Nebula-$TAG-macos-universal"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$NAME.zip"
ln -s /Applications "$STAGING/image/Applications"
hdiutil create -volname "Nebula $TAG" -srcfolder "$STAGING/image" -format UDZO -ov "$OUTPUT/$NAME.dmg"
ditto -x -k "$OUTPUT/$NAME.zip" "$STAGING/unpacked"
python3 "$ROOT/scripts/verify-release.py" "$STAGING/unpacked/Nebula.app" "$VERSION" arm64 x86_64 > "$STAGING/zip.json"
cmp "$STAGING/universal.json" "$STAGING/zip.json"
mkdir "$MOUNT"
hdiutil attach "$OUTPUT/$NAME.dmg" -readonly -nobrowse -mountpoint "$MOUNT"
python3 "$ROOT/scripts/verify-release.py" "$MOUNT/Nebula.app" "$VERSION" arm64 x86_64 > "$STAGING/dmg.json"
cmp "$STAGING/universal.json" "$STAGING/dmg.json"
hdiutil detach "$MOUNT"
python3 - "$ROOT" "$STAGING" "$OUTPUT" "$VERSION" <<'PY'
import json, pathlib, subprocess, sys
root, staging, output = map(pathlib.Path, sys.argv[1:4])
def command(*args):
    return subprocess.check_output(args, cwd=root, text=True).strip()
manifest = {
    "schema": 1, "version": sys.argv[4], "distribution": "internal-adhoc",
    "configuration": "release", "sourceRevision": command("git", "rev-parse", "HEAD"),
    "sourceDirty": bool(command("git", "status", "--porcelain")),
    "kernelRevision": (root / "scripts/kernel-revision").read_text().strip(),
    "toolchains": {"go": command("go", "-C", str(root / "backend"), "version"),
                   "swift": command("swift", "--version"), "xcode": command("xcodebuild", "-version"),
                   "macOS": command("sw_vers", "-productVersion")},
    "app": json.loads((staging / "universal.json").read_text()),
}
(output / "build-info.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
cat > "$OUTPUT/release-notes.md" <<EOF
Nebula GUI $TAG — internal validation build

Universal macOS App (arm64 + x86_64), release optimization, declared minimum macOS 13.0.
Ad-hoc signed; NOT Developer ID signed or notarized. Intel/Apple Silicon and minimum OS installation acceptance is incomplete; see docs/RELEASE.md and Issues #8 / #4.
This draft is not an approved public Beta. Do not bypass Gatekeeper or SIP. System component installation requires separate user authorization in the GUI.

Source: $(git -C "$ROOT" rev-parse HEAD)
Kernel: $(cat "$ROOT/scripts/kernel-revision")
EOF
(cd "$OUTPUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" build-info.json release-notes.md > SHA256SUMS)
echo "Verified release assets: $OUTPUT"
