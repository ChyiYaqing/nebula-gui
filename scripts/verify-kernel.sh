#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="$(cat "$ROOT/scripts/kernel-revision")"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid kernel pin" >&2; exit 1; }
KERNEL="${1:-$ROOT/../nebula}"
[ ! -L "$KERNEL" ] || { echo "Kernel destination must not be a symlink" >&2; exit 1; }
[ "$(git -C "$KERNEL" rev-parse --show-toplevel)" = "$(cd "$KERNEL" && pwd -P)" ] || { echo "Not a kernel checkout root" >&2; exit 1; }
[ "$(git -C "$KERNEL" rev-parse HEAD)" = "$EXPECTED" ] || { echo "Kernel revision differs from pin" >&2; exit 1; }
[ -z "$(git -C "$KERNEL" status --porcelain --untracked-files=no)" ] || { echo "Kernel tracked files changed" >&2; exit 1; }
# Local documentation is harmless; even ignored extra compiler inputs are not.
[ -z "$(git -C "$KERNEL" ls-files --others -- '*.go' '*.mod' '*.sum' '*.s' '*.S' '*.c' '*.h' '*.cc' '*.cpp' '*.cxx' '*.hh' '*.hpp' '*.hxx' '*.m' '*.mm' '*.f' '*.F' '*.for' '*.f90' '*.sx' '*.swig' '*.swigcxx' '*.syso')" ] || { echo "Kernel has untracked compiler inputs" >&2; exit 1; }
echo "Verified kernel $EXPECTED"
