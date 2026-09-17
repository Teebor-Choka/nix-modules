#!/usr/bin/env bash
# Unit tests for the SSH-agent relay lifecycle decision (agent-bridge-lib.sh) — no VM needed.
# Reproduces the stale-socket bug: a live relay pid pointing at a rotated-away host agent
# socket must be RESTARTED, not reused. Pure filesystem + this process's own pid; runs in the
# Nix build sandbox.
#
# Usage: agent-bridge-suite.sh <path-to-agent-bridge-lib.sh>
set -uo pipefail
lib=${1:?usage: agent-bridge-suite.sh <agent-bridge-lib.sh>}
# shellcheck source=/dev/null
. "$lib"

pass=0; fail=0
check() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then echo "✓ $1"; pass=$((pass+1))
  else echo "✗ $1 (want '$2', got '$3')"; fail=$((fail+1)); fi
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pid_file="$tmp/agent-bridge.pid"
target_file="$tmp/agent-bridge.target"
sock_a="$tmp/a.sock"
sock_b="$tmp/b.sock"

# A definitely-dead pid: spawn a child, capture its pid, reap it — the number is now free.
true & dead=$!; wait "$dead" 2>/dev/null || true
live=$$   # this test process is guaranteed alive

# 1) No relay recorded → start.
rm -f "$pid_file" "$target_file"
check "no relay recorded → start" start "$(_agent_bridge_decide "$pid_file" "$target_file" "$sock_a")"

# 2) Recorded pid is dead → start (target irrelevant).
echo "$dead" > "$pid_file"; printf '%s' "$sock_a" > "$target_file"
check "dead relay pid → start" start "$(_agent_bridge_decide "$pid_file" "$target_file" "$sock_a")"

# 3) Live pid, recorded target == current socket → reuse.
echo "$live" > "$pid_file"; printf '%s' "$sock_a" > "$target_file"
check "live relay on current socket → reuse" reuse "$(_agent_bridge_decide "$pid_file" "$target_file" "$sock_a")"

# 4) THE BUG: live pid, recorded target != current (host agent socket rotated) → restart.
echo "$live" > "$pid_file"; printf '%s' "$sock_a" > "$target_file"
check "live relay on rotated socket → restart" restart "$(_agent_bridge_decide "$pid_file" "$target_file" "$sock_b")"

# 5) target-alive helper: a live unix socket is alive; a vanished path is not.
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock_a" 2>/dev/null || true
printf '%s' "$sock_a" > "$target_file"
_agent_bridge_target_alive "$target_file" && r=yes || r=no
check "target_alive → yes for a live unix socket" yes "$r"

printf '%s' "$tmp/gone.sock" > "$target_file"
_agent_bridge_target_alive "$target_file" && r=yes || r=no
check "target_alive → no for a vanished socket" no "$r"

echo "── agent-bridge suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
