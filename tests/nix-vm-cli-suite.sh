#!/usr/bin/env bash
# Black-box regression tests for the `vm` helper (nix-vm) command dispatch — no VM needed.
# Exercises the paths that don't require a running guest: usage, unknown command, `list`,
# `doctor` skipping a not-running VM, and the `builder` macOS-only gate (on Linux).
#
# Usage: nix-vm-cli-suite.sh <path-to-nix-vm>
set -uo pipefail
vm=${1:?usage: nix-vm-cli-suite.sh <nix-vm>}
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1 (rc=$rc, out=$(tr '\n' '|' <<<"$out"))"; fail=$((fail+1)); }

out=$("$vm" 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'Usage:' <<<"$out" && grep -q 'doctor' <<<"$out" && grep -q 'builder' <<<"$out"; } \
  && ok "no-args → usage listing doctor + builder" || bad "no-args usage"

out=$("$vm" --help 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'Usage:' <<<"$out"; } && ok "--help → usage" || bad "--help"

out=$("$vm" bogus-cmd 2>&1); rc=$?
{ [ "$rc" = 1 ] && grep -qi 'unknown command' <<<"$out"; } && ok "unknown command → exit 1" || bad "unknown command"

out=$("$vm" list 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'smoke' <<<"$out"; } && ok "list → shows defined VM 'smoke'" || bad "list"

out=$("$vm" doctor smoke 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qi 'not running' <<<"$out"; } && ok "doctor <name> → skips not-running VM" || bad "doctor skip"

out=$("$vm" doctor 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qi 'not running' <<<"$out"; } && ok "doctor (all) → skips not-running" || bad "doctor all"

# On Linux the vfkit builder helper is not installed → `vm builder` must fail clearly, not crash.
out=$("$vm" builder status 2>&1); rc=$?
{ [ "$rc" = 1 ] && grep -qi 'macOS-only' <<<"$out"; } && ok "builder → macOS-only error on Linux" || bad "builder gate"

echo "── nix-vm CLI suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
