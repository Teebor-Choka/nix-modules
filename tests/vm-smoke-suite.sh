#!/usr/bin/env bash
# vm-smoke-suite.sh — generic live smoke test for a microVM built by mkMicrovmFleet.
#
# Boots fresh ephemeral instances via `nix-vm run` and asserts the machinery contract THIS
# module owns: boot + autologin, forwarded SSH agent, outbound DNS+HTTPS, guest NAT lease,
# exit-code propagation, and ephemeral concurrency. It carries NO personal values — the consumer
# supplies them via env. Consumer-specific guest content (dotfiles, private repos, per-tool CLIs)
# is intentionally NOT tested here: wrap this suite in the consumer flake and add those checks
# there.
#
# Unlike the sandboxed suites under tests/ (console-run, nix-vm-cli), this one requires a REAL
# hypervisor + host network + a running SSH agent, so it is not a `nix flake check` derivation —
# it is meant to be run on a configured host (the flake only `bash -n`-checks it).
#
# Params (env):
#   VM           (required)  microVM name to boot (e.g. "claude")
#   EXPECT_USER  (required)  autologin username to assert (e.g. "teebor")
#   GIT_REMOTE   (optional)  ssh git remote to test forwarded-agent auth against; skipped if empty
#   NIX_VM       (optional)  path to the nix-vm helper (default: nix-vm on PATH)
#
# Usage: vm-smoke-suite.sh [serial|concurrent|all]   (default: all)
set -uo pipefail

VM=${VM:?set VM to the microVM name}
EXPECT_USER=${EXPECT_USER:?set EXPECT_USER to the expected autologin user}
GIT_REMOTE=${GIT_REMOTE:-}
NIX_VM=${NIX_VM:-nix-vm}

PASS=0
FAIL=0
pass() {
  echo "✓ PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "✗ FAIL: $1"
  FAIL=$((FAIL + 1))
}

# check <label> <guest-command> [expect_exit=0] [expect_output_substring]
check() {
  local label=$1 cmd=$2 expect_exit=${3:-0} expect_output=${4:-}
  echo "── $label"
  local out rc
  out=$("$NIX_VM" run "$VM" "$cmd" 2>/dev/null)
  rc=$?
  if [ "$rc" != "$expect_exit" ]; then
    fail "$label — expected exit $expect_exit, got $rc"
    return
  fi
  if [ -n "$expect_output" ] && ! grep -q "$expect_output" <<<"$out"; then
    fail "$label — expected output to contain '$expect_output', got: $out"
    return
  fi
  pass "$label"
}

serial_tests() {
  echo "=== Serial smoke tests for '$VM' (user=$EXPECT_USER) ==="

  check "a) echo round-trip" "echo ok" 0 "ok"
  check "b) autologin user" "whoami" 0 "$EXPECT_USER"
  # Real assertion (not just exit 0): the forwarded agent must expose ≥1 identity. Requires the
  # host SSH agent to be running and unlocked with at least one key.
  check "c) SSH agent forwarded (≥1 key)" \
    'ssh-add -l >/dev/null 2>&1 && [ "$(ssh-add -l | grep -c .)" -ge 1 ]' 0
  check "d) DNS + outbound HTTPS" \
    "getent hosts github.com >/dev/null && curl -fsS -o /dev/null https://github.com" 0
  if [ -n "$GIT_REMOTE" ]; then
    check "e) git-over-SSH via forwarded agent ($GIT_REMOTE)" \
      "git ls-remote $GIT_REMOTE HEAD >/dev/null" 0
  else
    echo "── e) git-over-SSH — skipped (GIT_REMOTE unset)"
  fi
  check "f) guest NAT lease (192.168.65.x)" \
    "ip -4 addr show eth0 | awk '/inet /{print \$2}'" 0 "192.168.65."

  echo "── g) exit-code propagation (expect 7)"
  "$NIX_VM" run "$VM" "exit 7" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = 7 ]; then
    pass "g) exit-code propagation"
  else
    fail "g) exit-code propagation — expected 7, got $rc"
  fi
}

concurrency_test() {
  echo "=== Concurrency test (two parallel vm run for '$VM') ==="
  local cmd="ip -4 addr show eth0 | awk '/inet /{print \$2}'"
  "$NIX_VM" run "$VM" "$cmd" >/dev/null 2>&1 &
  local p1=$!
  "$NIX_VM" run "$VM" "$cmd" >/dev/null 2>&1 &
  local p2=$!
  wait "$p1"
  local e1=$?
  wait "$p2"
  local e2=$?
  if [ "$e1" = 0 ] && [ "$e2" = 0 ]; then
    pass "concurrency — both instances completed"
  else
    fail "concurrency — exits: $e1 $e2"
  fi
  echo "   (verify distinct IPs manually: $NIX_VM run $VM 'ip -4 addr show eth0' & …)"
}

case "${1:-all}" in
  serial) serial_tests ;;
  concurrent) concurrency_test ;;
  all)
    serial_tests
    concurrency_test
    ;;
  *)
    echo "Usage: $0 [serial|concurrent|all]"
    exit 1
    ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
