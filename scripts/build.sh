#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL="$ROOT/../nebula"
bash "$ROOT/scripts/verify-kernel.sh" "$KERNEL"
mkdir -p "$ROOT/.build/bin"
(cd "$ROOT/backend" && go build -trimpath -o "$ROOT/.build/bin/nebula-gui-backend" ./cmd/nebula-gui-backend)
(cd "$ROOT/backend" && go build -trimpath -o "$ROOT/.build/bin/nebula-gui-helper" ./cmd/nebula-gui-helper)
swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c debug
SWIFT_BIN="$(swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c debug --show-bin-path)"
APP="${NEBULA_GUI_APP_OUTPUT:-$ROOT/build/Nebula.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$SWIFT_BIN/NebulaGUI" "$APP/Contents/MacOS/NebulaGUI"
cp "$ROOT/.build/bin/nebula-gui-backend" "$APP/Contents/Helpers/nebula-gui-backend"
cp "$ROOT/.build/bin/nebula-gui-helper" "$APP/Contents/Helpers/nebula-gui-helper"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
 plistlib.dump({'CFBundleName':'Nebula','CFBundleDisplayName':'Nebula','CFBundleIdentifier':'net.nebula.gui.development','CFBundleExecutable':'NebulaGUI','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.3.1','CFBundleVersion':'4','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSSupportsAutomaticTermination':False,'NSHumanReadableCopyright':'Nebula GUI development build'},f)
PY
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-backend"
codesign --force --sign - "$APP/Contents/Helpers/nebula-gui-helper"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Development app: $APP"
echo "Ad-hoc signed locally; not Developer ID signed or notarized. No service installed."
