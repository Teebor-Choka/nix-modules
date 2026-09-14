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

# ── Launch-time trust resolution (VM_DEBUG_GRANT prints the grant and exits before any build) ──
# The 'smoke' VM declares trust.default = [ "secrets" ].
out=$(VM_DEBUG_GRANT=1 "$vm" run smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'grant: secrets' <<<"$out"; } && ok "run smoke → default grant = secrets" || bad "default grant"

out=$(VM_DEBUG_GRANT=1 "$vm" run --isolated smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'grant: <none>' <<<"$out"; } && ok "run --isolated → grant none (overrides default)" || bad "isolated override"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trusted smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'grant: secrets' <<<"$out"; } && ok "run --trusted → all tokens" || bad "trusted grant"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trust secrets smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'grant: secrets' <<<"$out"; } && ok "run --trust secrets → secrets" || bad "explicit grant"

out=$(VM_DEBUG_GRANT=1 "$vm" up --isolated smoke 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'grant: <none>' <<<"$out"; } && ok "up --isolated → grant none" || bad "up isolated"

# Unknown trust token → exit 2 with a clear message (no VM build attempted).
out=$("$vm" run --trust bogus smoke true 2>&1); rc=$?
{ [ "$rc" = 2 ] && grep -qi "unknown trust token: 'bogus'" <<<"$out"; } && ok "--trust bogus → exit 2" || bad "unknown token"

# Command tokens after the name are not swallowed by the trust parser (dashes stay in the command).
out=$(VM_DEBUG_GRANT=1 "$vm" run --trusted smoke echo --isolated hi 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'grant: secrets' <<<"$out"; } && ok "trust flag before name only; cmd dashes preserved" || bad "cmd dash handling"

echo "── nix-vm CLI suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
