#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="$(cat "$ROOT/scripts/kernel-revision")"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid kernel pin" >&2; exit 1; }
KERNEL="${1:-$ROOT/../nebula}"
if [ -L "$KERNEL" ]; then echo "Kernel destination must not be a symlink" >&2; exit 1; fi
if [ ! -e "$KERNEL" ]; then
  mkdir -p "$(dirname "$KERNEL")"
  mkdir "$KERNEL"
  git -C "$KERNEL" init -q
  git -C "$KERNEL" remote add origin https://github.com/ChyiYaqing/nebula.git
  GIT_TERMINAL_PROMPT=0 git -C "$KERNEL" fetch --no-tags --depth=1 origin "$EXPECTED"
  git -C "$KERNEL" checkout --detach FETCH_HEAD
fi
# Never fetch into, switch, reset or clean an existing developer checkout.
bash "$ROOT/scripts/verify-kernel.sh" "$KERNEL"
