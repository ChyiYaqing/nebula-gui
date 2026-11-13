#!/bin/bash
# Local end-to-end test: the built App and backend drive the INSTALLED root component
# and bring up a real tunnel with a temporary identity in an isolated data directory.
# Never part of CI or test.sh. Uses no sudo and installs nothing.
# Exit codes: 0 passed, 1 failed, 2 precondition missing (see the SKIP line).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${NEBULA_GUI_E2E_APP:-$ROOT/build/E2E/Nebula.app}"
SECONDS_CONNECTED="${NEBULA_GUI_E2E_SECONDS:-15}"
AX="$ROOT/.build/bin/nebula-e2e-ax"

if [[ -z "${NEBULA_GUI_E2E_APP:-}" ]]; then NEBULA_GUI_APP_OUTPUT="$APP" bash "$ROOT/scripts/build.sh" >/dev/null 2>&1; fi
mkdir -p "$ROOT/.build/bin"
swiftc -O -o "$AX" "$ROOT/tools/e2e/AXDriver.swift"

# macOS resolves /tmp to /private/tmp; the store must be reached by its real path.
WORK="$(cd "$(mktemp -d /private/tmp/nebula-e2e.XXXXXX)" && pwd -P)"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then "$AX" "$APP_PID" quit 20 >/dev/null 2>&1 || kill "$APP_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"   # Holds the temporary private key.
}
trap cleanup EXIT
tunnels() { ifconfig -l | tr ' ' '\n' | grep -c '^utun' || true; }
step() { printf '%s\n' "-- $*"; }

step "generating a temporary identity"
(cd "$ROOT/backend" && NEBULA_GUI_FIXTURE_DIR="$WORK/identity" go test -count=1 -run TestExportDevelopmentFixture ./internal/client >/dev/null)
mkdir -m 700 "$WORK/store"
BEFORE="$(tunnels)"

step "backend: import, connect, poll for ${SECONDS_CONNECTED}s, rebind, disconnect"
python3 "$ROOT/tools/e2e/backend_e2e.py" "$APP/Contents/Helpers/nebula-gui-backend" "$WORK/store" "$WORK/identity/config.yaml" "$SECONDS_CONNECTED"
[[ "$(tunnels)" == "$BEFORE" ]] || { echo "FAIL backend left a tunnel interface behind"; exit 1; }

step "app: launch on the isolated store"
open -n "$APP" --args --data-dir "$WORK/store"
for _ in $(seq 1 50); do
  APP_PID="$(pgrep -f "NebulaGUI --data-dir $WORK/store" | head -1 || true)"
  [[ -n "$APP_PID" ]] && break
  /bin/sleep 0.2
done
[[ -n "$APP_PID" ]] || { echo "FAIL the App did not start"; exit 1; }
ax() {
  local code=0
  "$AX" "$APP_PID" "$@" || code=$?
  if [[ $code -eq 3 ]]; then echo "SKIP grant Accessibility permission to this terminal in System Settings, then rerun"; exit 2; fi
  [[ $code -eq 0 ]] || { echo "FAIL app: $*"; exit 1; }
}
ax wait "连接网络" 15
ax wait "未连接" 5

step "app: connect"
ax click "连接网络"
ax wait "隧道已启动" 15
[[ "$(tunnels)" -gt "$BEFORE" ]] || { echo "FAIL no tunnel interface appeared"; exit 1; }

step "app: nodes, logs, configuration, overview"
ax click "节点";  ax wait "本机已知节点" 5
ax click "日志";  ax wait "Nebula 内核日志" 5
ax click "配置";  ax wait "网络身份" 5
ax click "概览";  ax wait "这台 Mac" 5
ax wait "隧道已启动" 5
ax absent "无法确认"

step "app: disconnect, reconnect, quit while connected"
ax click "断开连接"
ax wait "未连接" 15
[[ "$(tunnels)" == "$BEFORE" ]] || { echo "FAIL the tunnel interface survived disconnect"; exit 1; }
ax click "连接网络"
ax wait "隧道已启动" 15
ax quit 20
APP_PID=""
[[ "$(tunnels)" == "$BEFORE" ]] || { echo "FAIL the tunnel interface survived quit"; exit 1; }
if pgrep -f "nebula-gui-backend serve --store $WORK/store" >/dev/null; then echo "FAIL the backend outlived the App"; exit 1; fi

echo "PASS end-to-end: backend and App against the installed connection component"
