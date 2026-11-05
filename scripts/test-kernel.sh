#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nebula-kernel-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone --quiet --shared "$ROOT/../nebula" "$WORK/kernel"
verify() { bash "$ROOT/scripts/verify-kernel.sh" "$WORK/kernel"; }
reject() { if verify > /dev/null 2>&1; then echo "FAIL: $1 accepted" >&2; exit 1; fi; echo "PASS reject: $1"; }
verify
printf 'documentation\n' > "$WORK/kernel/local-notes.md"
verify
printf 'package nebula\n' > "$WORK/kernel/unreviewed.go"
reject 'untracked source'
rm "$WORK/kernel/unreviewed.go"
printf 'extra compiler input\n' > "$WORK/kernel/unreviewed.f90"
reject 'untracked Fortran source'
rm "$WORK/kernel/unreviewed.f90"
printf 'ignored.go\n' >> "$WORK/kernel/.git/info/exclude"
printf 'package nebula\n' > "$WORK/kernel/ignored.go"
reject 'ignored Go source'
rm "$WORK/kernel/ignored.go"
printf '\n// changed\n' >> "$WORK/kernel/go.mod"
reject 'modified tracked source'
git -C "$WORK/kernel" restore go.mod
git -C "$WORK/kernel" -c user.name=Test -c user.email=test@example.invalid commit --quiet --allow-empty -m 'different revision'
reject 'different revision'
ln -s "$WORK/kernel" "$WORK/link"
if bash "$ROOT/scripts/prepare-kernel.sh" "$WORK/link" > /dev/null 2>&1; then echo 'FAIL: symlink accepted' >&2; exit 1; fi
echo 'PASS reject: symlink destination'
