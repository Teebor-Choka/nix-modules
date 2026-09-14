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
# The 'smoke' VM declares trust.default = [ "secrets" "agent" "shares" ] + defaultMount = /tmp.
# Matches are exact-line (grep -x).
out=$(VM_DEBUG_GRANT=1 "$vm" run smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: secrets agent shares' <<<"$out"; } && ok "run smoke → default grant = secrets agent shares" || bad "default grant"

out=$(VM_DEBUG_GRANT=1 "$vm" run --isolated smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: <none>' <<<"$out"; } && ok "run --isolated → grant none (overrides default)" || bad "isolated override"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trusted smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: secrets agent shares' <<<"$out"; } && ok "run --trusted → all tokens" || bad "trusted grant"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trust secrets smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: secrets' <<<"$out"; } && ok "run --trust secrets → secrets only" || bad "explicit secrets"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trust agent smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: agent' <<<"$out"; } && ok "run --trust agent → agent only" || bad "explicit agent"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trust secrets,agent smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: secrets agent' <<<"$out"; } && ok "run --trust secrets,agent → both" || bad "explicit both"

out=$(VM_DEBUG_GRANT=1 "$vm" up --isolated smoke 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: <none>' <<<"$out"; } && ok "up --isolated → grant none" || bad "up isolated"

# Unknown trust token → exit 2 with a clear message (no VM build attempted).
out=$("$vm" run --trust bogus smoke true 2>&1); rc=$?
{ [ "$rc" = 2 ] && grep -qi "unknown trust token: 'bogus'" <<<"$out"; } && ok "--trust bogus → exit 2" || bad "unknown token"

# Command tokens after the name are not swallowed by the trust parser (dashes stay in the command).
out=$(VM_DEBUG_GRANT=1 "$vm" run --trusted smoke echo --isolated hi 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'grant: secrets agent shares' <<<"$out"; } && ok "trust flag before name only; cmd dashes preserved" || bad "cmd dash handling"

# ── Default mount via the `shares` token (smoke.defaultMount = /tmp) ────────────
out=$(VM_DEBUG_GRANT=1 "$vm" run smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'mount: /tmp' <<<"$out"; } && ok "shares granted → defaultMount applied" || bad "default mount applied"

out=$(VM_DEBUG_GRANT=1 "$vm" run --isolated smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'mount: <none>' <<<"$out"; } && ok "--isolated → defaultMount withheld" || bad "default mount isolated"

out=$(VM_DEBUG_GRANT=1 "$vm" run --trust secrets smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx 'mount: <none>' <<<"$out"; } && ok "no shares token → defaultMount withheld" || bad "default mount no-shares"

# ── Ad-hoc launch inputs: --env / --mount ──────────────────────────────────────
out=$(VM_DEBUG_GRANT=1 "$vm" run --env FOO=bar smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'env: export FOO=bar;' <<<"$out"; } && ok "--env FOO=bar → export in env prefix" || bad "env export"

out=$(VM_DEBUG_GRANT=1 "$vm" run --env A=1 --env B=2 smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -q 'env: export A=1; export B=2;' <<<"$out"; } && ok "--env repeatable → ordered exports" || bad "env repeatable"

out=$("$vm" run --env 1bad=x smoke true 2>&1); rc=$?
{ [ "$rc" = 2 ] && grep -qi 'invalid variable name' <<<"$out"; } && ok "--env invalid name → exit 2" || bad "env invalid name"

out=$("$vm" run --env NOEQ smoke true 2>&1); rc=$?
{ [ "$rc" = 2 ] && grep -qi 'expects KEY=VALUE' <<<"$out"; } && ok "--env without = → exit 2" || bad "env no equals"

md=$(mktemp -d)
out=$(VM_DEBUG_GRANT=1 "$vm" run --mount "$md" smoke true 2>&1); rc=$?
{ [ "$rc" = 0 ] && grep -qx "mount: $md" <<<"$out"; } && ok "--mount <dir> → resolved abs dir" || bad "mount dir"
rmdir "$md"

out=$("$vm" run --mount /no/such/dir/xyz smoke true 2>&1); rc=$?
{ [ "$rc" = 2 ] && grep -qi 'not a directory' <<<"$out"; } && ok "--mount missing dir → exit 2" || bad "mount missing"

out=$("$vm" up --env X=1 smoke 2>&1); rc=$?
{ [ "$rc" = 2 ] && grep -qi "only on 'vm run'" <<<"$out"; } && ok "up --env → rejected (run only)" || bad "up env reject"

echo "── nix-vm CLI suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
