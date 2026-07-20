#!/usr/bin/env bash
# Behavioral regression suite for `vm run`'s console driver (modules/microvms/vm-console-run.py).
# Drives the REAL driver against fake runners on a PTY — no VM/vfkit needed — covering the bugs
# we fixed plus general command-injection behavior, so regressions surface in `nix flake check`.
#
# Usage: console-run-suite.sh <path-to-vm-console-run.py>
set -uo pipefail
driver=${1:?usage: console-run-suite.sh <vm-console-run.py>}
BASH_BIN=$(command -v bash)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work"
pass=0; fail=0
ok()   { echo "✓ $1"; pass=$((pass+1)); }
bad()  { echo "✗ $1"; fail=$((fail+1)); }

# make_runner <file> <boot_marker> <echo:0|1> <trapTERM:0|1>
#   Emulates a VM serial console: prints <boot_marker>, then reads lines; optionally echoes each
#   line back (tty-echo race) and optionally ignores SIGTERM (forces the driver's SIGKILL path);
#   executes each line so the injected base64 sentinel-script actually runs.
make_runner() {
  local f=$1 marker=$2 echo_on=$3 trap_term=$4
  {
    echo "#!$BASH_BIN"
    [ "$trap_term" = 1 ] && echo "trap '' TERM"
    printf 'echo %q\n' "$marker"
    echo 'while IFS= read -r line; do'
    [ "$echo_on" = 1 ] && echo '  printf "%s\n" "$line"'
    echo '  eval "$line" || true'
    echo 'done'
  } > "$f"
  chmod +x "$f"
}

# run_case: sets globals RC and OUT (stdout); ERR captured to a file.
run_case() {
  local runner=$1 cmd=$2
  local cmd_b64; cmd_b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')
  OUT=$(timeout 90 python3 "$driver" "$runner" "$cmd_b64" 2>"$work/err"); RC=$?
  ERR=$(cat "$work/err")
}

# ── Case 1: happy path — output captured, exit 0 (echo off, TERM respected) ──────────
make_runner r1 "Reached target Multi-User" 0 0
run_case ./r1 'echo hello-world'
{ [ "$RC" = 0 ] && grep -q 'hello-world' <<<"$OUT"; } \
  && ok "happy path: output captured, exit 0" \
  || bad "happy path (rc=$RC, out=$(tr '\n' '|' <<<"$OUT"))"

# ── Case 2: exit-code propagation (non-zero) ─────────────────────────────────────────
make_runner r2 "Reached target Multi-User" 0 0
run_case ./r2 'echo x; exit 7'
[ "$RC" = 7 ] && ok "exit code propagated (7)" || bad "exit code propagation (rc=$RC)"

# ── Case 3: stdout+stderr merged, multi-line preserved ───────────────────────────────
make_runner r3 "Reached target Multi-User" 0 0
run_case ./r3 'echo out1; echo err1 >&2; echo out2'
{ grep -q out1 <<<"$OUT" && grep -q err1 <<<"$OUT" && grep -q out2 <<<"$OUT" && [ "$RC" = 0 ]; } \
  && ok "stdout+stderr merged, multi-line" \
  || bad "stdout/stderr merge (rc=$RC, out=$(tr '\n' '|' <<<"$OUT"))"

# ── Case 4: echo race + SIGTERM-ignoring teardown (the two fixed bugs) ────────────────
#   Runner echoes the injected command AND ignores SIGTERM. base64-wrapping must keep the
#   sentinels out of the echoed line; _kill_child must escalate to SIGKILL (no hang).
make_runner r4 "Reached target Multi-User" 1 1
run_case ./r4 'echo RACE_OK; exit 3'
if [ "$RC" = 124 ]; then bad "echo/teardown: driver HUNG (teardown regression #3)"
elif ! grep -q RACE_OK <<<"$OUT"; then bad "echo/teardown: output not captured (echo race #2)"
elif grep -q 'base64 -d' <<<"$OUT"; then bad "echo/teardown: captured echoed command (sentinel desync #2)"
elif [ "$RC" != 3 ]; then bad "echo/teardown: wrong exit (rc=$RC, want 3)"
else ok "echo race handled + SIGTERM-ignoring runner reaped, exit 3"; fi

# ── Case 5: user output containing sentinel-like / base64-like text is captured verbatim ─
make_runner r5 "Reached target Multi-User" 1 0
run_case ./r5 'printf "literal __VMR_ text and base64 -d here\n"'
{ grep -q 'literal __VMR_ text and base64 -d here' <<<"$OUT" && [ "$RC" = 0 ]; } \
  && ok "sentinel-like user output captured verbatim" \
  || bad "verbatim capture of sentinel-like text (rc=$RC)"

# ── Case 6: fatal boot detected (no multi-user), reported, and does NOT hang ─────────
make_runner r6 "Kernel panic - not syncing: VFS" 0 1
run_case ./r6 'echo should-not-run'
{ [ "$RC" != 0 ] && [ "$RC" != 124 ] && grep -qi 'fatal' <<<"$ERR" && ! grep -q should-not-run <<<"$OUT"; } \
  && ok "fatal boot detected + reported, no hang" \
  || bad "fatal boot handling (rc=$RC, err=$(tr '\n' '|' <<<"$ERR"))"

echo "── console-run suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
