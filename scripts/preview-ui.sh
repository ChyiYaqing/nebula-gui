#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c debug
SWIFT_BIN="$(swift build --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c debug --show-bin-path)"
SOURCES=()
for source in "$ROOT"/apps/macos/Sources/NebulaGUI/*.swift; do
  case "$source" in
    */NebulaApp.swift|*/AuthorizationRunner.swift|*/CertificateNotifications.swift) ;;
    *) SOURCES+=("$source") ;;
  esac
done
if [[ -f "$SWIFT_BIN/NebulaClient.o" ]]; then
  OBJECTS=("$SWIFT_BIN/NebulaClient.o")
else
  OBJECTS=("$SWIFT_BIN"/NebulaClient.build/*.o)
fi
mkdir -p "$ROOT/.build/bin"
swiftc -parse-as-library -whole-module-optimization -target "$(uname -m)-apple-macosx13.0" -I "$SWIFT_BIN" -I "$SWIFT_BIN/Modules" \
  "${SOURCES[@]}" "$ROOT/tools/ui-preview/Preview.swift" "$ROOT/tools/ui-preview/PreviewSystemActions.swift" "${OBJECTS[@]}" \
  -o "$ROOT/.build/bin/nebula-ui-preview"
if [[ "${1:-}" != "--build-only" ]]; then "$ROOT/.build/bin/nebula-ui-preview" "$@"; fi
