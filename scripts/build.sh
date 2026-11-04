#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/../nebula"
SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_STATUS="$(git -C "$ROOT" status --porcelain)"
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="$(cat "$ROOT/BUILD_NUMBER")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid application version" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Invalid build number" >&2; exit 1; }
CONFIGURATION="${NEBULA_GUI_BUILD_CONFIGURATION:-debug}"
case "$CONFIGURATION" in debug|release) ;; *) echo "Invalid build configuration" >&2; exit 1 ;; esac
export MACOSX_DEPLOYMENT_TARGET=13.0
export CGO_CFLAGS="${CGO_CFLAGS:-} -mmacosx-version-min=13.0"
export CGO_LDFLAGS="${CGO_LDFLAGS:-} -mmacosx-version-min=13.0"
GO_LDFLAGS="-X nebula-gui/backend/internal/client.ApplicationVersion=$VERSION -X nebula-gui/backend/internal/client.BuildNumber=$BUILD_NUMBER"
bash "$ROOT/scripts/verify-kernel.sh" "$KERNEL"
mkdir -p "$ROOT/.build/bin"
(cd "$ROOT/backend" && go build -trimpath -ldflags "$GO_LDFLAGS" -o "$ROOT/.build/bin/nebula-gui-backend" ./cmd/nebula-gui-backend)
(cd "$ROOT/backend" && go build -trimpath -ldflags "$GO_LDFLAGS" -o "$ROOT/.build/bin/nebula-gui-helper" ./cmd/nebula-gui-helper)
swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c "$CONFIGURATION"
SWIFT_BIN="$(swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c "$CONFIGURATION" --show-bin-path)"
APP="${NEBULA_GUI_APP_OUTPUT:-$ROOT/build/Nebula.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$SWIFT_BIN/NebulaGUI" "$APP/Contents/MacOS/NebulaGUI"
cp "$ROOT/.build/bin/nebula-gui-backend" "$APP/Contents/Helpers/nebula-gui-backend"
cp "$ROOT/.build/bin/nebula-gui-helper" "$APP/Contents/Helpers/nebula-gui-helper"
python3 - "$APP/Contents/Info.plist" "$VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'CFBundleName':'Nebula','CFBundleDisplayName':'Nebula','CFBundleIdentifier':'net.nebula.gui.development','CFBundleExecutable':'NebulaGUI','CFBundlePackageType':'APPL','CFBundleShortVersionString':sys.argv[2],'CFBundleVersion':sys.argv[3],'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSSupportsAutomaticTermination':False,'NSHumanReadableCopyright':'Nebula GUI development build'},f)
PY
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-backend"
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-helper"
python3 "$ROOT/scripts/build-manifest.py" "$APP" "$CONFIGURATION" "$SOURCE_REVISION" "$SOURCE_STATUS"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/verify-app.py" "$APP" > "$APP.verification.json"
echo "Development app: $APP"
echo "Ad-hoc signed locally; not Developer ID signed or notarized. No service installed."
