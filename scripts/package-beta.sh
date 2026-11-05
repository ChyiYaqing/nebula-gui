#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || { echo "Commit or isolate work before packaging a candidate." >&2; exit 1; }
VERSION="$(cat "$ROOT/VERSION")"
BUILD_NUMBER="$(cat "$ROOT/BUILD_NUMBER")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
mkdir -p "$ROOT/build/Beta"
OUTPUT="$(mktemp -d "$ROOT/build/Beta/Nebula-$VERSION.$BUILD_NUMBER.XXXXXX")"
export NEBULA_GUI_BUILD_CONFIGURATION=release
export NEBULA_GUI_APP_OUTPUT="$OUTPUT/Nebula.app"
bash "$ROOT/scripts/build.sh"
python3 "$ROOT/scripts/verify-app.py" "$NEBULA_GUI_APP_OUTPUT" > "$OUTPUT/verification.json"
python3 - "$OUTPUT/verification.json" <<'CLEAN'
import json,sys
value=json.load(open(sys.argv[1]))
if value["sourceDirty"] is not False or value["configuration"] != "release":
    raise SystemExit("Candidate must come from clean release source")
CLEAN
ZIP="$OUTPUT/Nebula-$VERSION-build$BUILD_NUMBER-$(uname -m)-internal.zip"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr "$NEBULA_GUI_APP_OUTPUT" "$ZIP"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nebula-archive-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
/usr/bin/ditto -x -k "$ZIP" "$WORK"
python3 "$ROOT/scripts/verify-app.py" "$WORK/Nebula.app" > "$OUTPUT/archive-verification.json"
cmp "$OUTPUT/verification.json" "$OUTPUT/archive-verification.json"
python3 - "$ZIP" <<'VERIFY'
import hashlib
from pathlib import Path
import sys
path=Path(sys.argv[1])
path.with_suffix(path.suffix+'.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n')
VERIFY
printf '%s\n' 'Internal ad-hoc build only. Not Developer ID signed or notarized. Not a public release.' > "$OUTPUT/INTERNAL-BUILD.txt"
echo "Internal candidate: $OUTPUT"
