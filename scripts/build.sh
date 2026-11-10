#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/../nebula"
VERSION="$(cat "$ROOT/VERSION")"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$ ]] || { echo "Invalid application version" >&2; exit 1; }
APP_VERSION="${VERSION%%-*}"
CONFIGURATION="${NEBULA_GUI_BUILD_CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Invalid build configuration" >&2; exit 1 ;; esac
ARCH="${NEBULA_GUI_BUILD_ARCH:-$(uname -m)}"
case "$ARCH" in arm64) export GOARCH=arm64 ;; x86_64) export GOARCH=amd64 ;; *) echo "Invalid build architecture" >&2; exit 1 ;; esac
export GOOS=darwin MACOSX_DEPLOYMENT_TARGET=13.0 CGO_ENABLED=1
export CGO_CFLAGS="${CGO_CFLAGS:-} -arch $ARCH -mmacosx-version-min=13.0"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -arch $ARCH -mmacosx-version-min=13.0"
bash "$ROOT/scripts/verify-kernel.sh" "$KERNEL"
mkdir -p "$ROOT/.build/bin"
(cd "$ROOT/backend" && go build -trimpath -o "$ROOT/.build/bin/nebula-gui-backend" ./cmd/nebula-gui-backend)
(cd "$ROOT/backend" && go build -trimpath -o "$ROOT/.build/bin/nebula-gui-helper" ./cmd/nebula-gui-helper)
swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c "$CONFIGURATION" --triple "$ARCH-apple-macosx13.0"
SWIFT_BIN="$(swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c "$CONFIGURATION" --triple "$ARCH-apple-macosx13.0" --show-bin-path)"
APP="${NEBULA_GUI_APP_OUTPUT:-$ROOT/build/Nebula.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$SWIFT_BIN/NebulaGUI" "$APP/Contents/MacOS/NebulaGUI"
cp "$ROOT/.build/bin/nebula-gui-backend" "$APP/Contents/Helpers/nebula-gui-backend"
cp "$ROOT/.build/bin/nebula-gui-helper" "$APP/Contents/Helpers/nebula-gui-helper"
swiftc -parse-as-library "$ROOT/apps/macos/Sources/NebulaGUI/NebulaMark.swift" "$ROOT/scripts/generate-icon.swift" -o "$ROOT/.build/bin/generate-icon"
ICONSET="$ROOT/.build/Nebula.iconset"
"$ROOT/.build/bin/generate-icon" "$ICONSET"
/usr/bin/iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Ed25519 public key (Base64, raw 32 bytes) for software updates (#69); empty disables installing.
UPDATE_KEY="$(tr -d '[:space:]' < "$ROOT/scripts/update-public-key")"
[[ -z "$UPDATE_KEY" || "$UPDATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "Invalid update public key" >&2; exit 1; }
python3 - "$APP/Contents/Info.plist" "$APP_VERSION" "$VERSION" "$UPDATE_KEY" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'NebulaUpdatePublicKey':sys.argv[4],'CFBundleName':'Nebula','CFBundleDisplayName':'Nebula','CFBundleIdentifier':'net.nebula.gui.development','CFBundleExecutable':'NebulaGUI','CFBundlePackageType':'APPL','CFBundleIconFile':'AppIcon.icns','CFBundleShortVersionString':sys.argv[2],'NebulaReleaseVersion':sys.argv[3],'CFBundleVersion':'10','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSSupportsAutomaticTermination':False,'NSHumanReadableCopyright':'Nebula GUI development build'},f)
PY
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-backend"
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-helper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Development app: $APP"
echo "Ad-hoc signed locally; not Developer ID signed or notarized. No service installed."
