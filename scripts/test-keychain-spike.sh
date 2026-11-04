#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nebula-keychain-spike.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library "$ROOT/scripts/keychain-spike.swift" -o "$WORK/keychain-spike"
codesign --force --sign - --identifier net.nebula.gui.keychain-spike "$WORK/keychain-spike"
"$WORK/keychain-spike"
