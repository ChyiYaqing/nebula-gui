#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/test-kernel.sh"
bash "$ROOT/scripts/build.sh"
export NEBULA_GUI_TEST_BACKEND="$ROOT/.build/bin/nebula-gui-backend"
(cd "$ROOT/backend" && go test -race -count=1 -v ./...)
swift test --package-path "$ROOT/apps/macos" --scratch-path "$ROOT/.build/swift" -c debug

bash "$ROOT/scripts/test-termination.sh"
