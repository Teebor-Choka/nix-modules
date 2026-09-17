# agent-bridge-lib.sh — pure decision helpers for the SSH-agent relay lifecycle.
#
# Factored out of the `nix-vm` script (modules/microvms/default.nix) so the staleness
# logic is unit-testable without a running hypervisor — see tests/agent-bridge-suite.sh.
# Inlined into nix-vm at build time via `builtins.readFile`; sourced directly by the test.
# Function definitions only — no side effects at source time.

# _agent_bridge_decide <pid_file> <target_file> <current_sock>
#   Decide what to do about the shared SSH-agent relay given its recorded state and the host
#   agent socket this launch would bridge to. Prints exactly one of:
#     start    no live relay recorded — spawn one.
#     reuse    a live relay already bridges the current socket — leave it be.
#     restart  a live relay exists but targets a DIFFERENT socket. This is the stale-socket
#              bug: the macOS launchd agent socket rotates across login sessions, so a relay
#              from an earlier session keeps holding the port while dialing a vanished socket.
#              A live pid alone is NOT proof the relay is usable — the target must match too.
_agent_bridge_decide() {
  local pid_file=${1:-} target_file=${2:-} current=${3:-}
  local pid recorded
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo start
    return 0
  fi
  recorded=$(cat "$target_file" 2>/dev/null || true)
  if [ "$recorded" = "$current" ]; then
    echo reuse
  else
    echo restart
  fi
}

# _agent_bridge_target_alive <target_file>
#   True (0) when the socket the relay was last started against still exists. `vm doctor`
#   uses this to catch a relay left dialing a vanished socket: the bound TCP port still
#   LISTENs, so a port probe alone reports it healthy while the guest can reach nothing.
_agent_bridge_target_alive() {
  local target
  target=$(cat "${1:-}" 2>/dev/null || true)
  [ -n "$target" ] && [ -S "$target" ]
}
