#!/usr/bin/env bash
# Unit tests for the sandy box-registry helpers (sandy-lib.sh) — no VM needed. Pure filesystem +
# this process's own pid, against a scratch SANDY_HOME. Runs in the Nix build sandbox.
#
# Usage: sandy-suite.sh <path-to-sandy-lib.sh>
set -uo pipefail
lib=${1:?usage: sandy-suite.sh <sandy-lib.sh>}
# shellcheck source=/dev/null
. "$lib"

pass=0; fail=0
check() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then echo "✓ $1"; pass=$((pass+1))
  else echo "✗ $1 (want '$2', got '$3')"; fail=$((fail+1)); fi
}
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

export SANDY_HOME; SANDY_HOME=$(mktemp -d)
trap 'rm -rf "$SANDY_HOME"' EXIT

# 1) short id is 8 lowercase hex.
sid=$(_sandy_gen_shortid)
[[ "$sid" =~ ^[0-9a-f]{8}$ ]] && ok "gen_shortid → 8 hex" || bad "gen_shortid ($sid)"

# 2) name is five words joined by '-', each drawn from SANDY_WORDS.
name=$(_sandy_gen_name)
IFS=- read -r -a parts <<<"$name"
check "gen_name → 5 words" 5 "${#parts[@]}"
inpool=1
for w in "${parts[@]}"; do
  found=0; for p in "${SANDY_WORDS[@]}"; do [ "$p" = "$w" ] && { found=1; break; }; done
  [ "$found" = 1 ] || inpool=0
done
check "gen_name words are all from the pool" 1 "$inpool"

# 3) write_box + field round-trip.
_sandy_write_box abcd1234 otter-maple-brave-fern-slate claude /st/microvm/claude/run.9.ff 4242 vfkit 21001 2026-09-17T12:00:00Z tty-s001
f="$SANDY_HOME/boxes/abcd1234.json"
[ -f "$f" ] && ok "write_box created the record" || bad "write_box file"
check "field short_id"     abcd1234                       "$(_sandy_field "$f" short_id)"
check "field id_name"      otter-maple-brave-fern-slate   "$(_sandy_field "$f" id_name)"
check "field vm_name"      claude                         "$(_sandy_field "$f" vm_name)"
check "field inst_dir"     /st/microvm/claude/run.9.ff    "$(_sandy_field "$f" inst_dir)"
check "field pid"          4242                           "$(_sandy_field "$f" pid)"
check "field hypervisor"   vfkit                          "$(_sandy_field "$f" hypervisor)"
check "field rvport"       21001                          "$(_sandy_field "$f" rvport)"

# 4) resolve by short id and by name; unknown fails.
check "resolve by short_id" "$f" "$(_sandy_resolve abcd1234)"
check "resolve by id_name"  "$f" "$(_sandy_resolve otter-maple-brave-fern-slate)"
_sandy_resolve nope-nope 2>/dev/null && bad "resolve unknown should fail" || ok "resolve unknown → fail"

# 5) prune: dead-pid box dropped, live-pid ($$) box kept.
true & dead=$!; wait "$dead" 2>/dev/null || true   # capture a child pid, reap it → free number
_sandy_write_box deadbeef gone-gone-gone-gone-gone claude /st/x "$dead" vfkit "" 2026-09-17T12:00:00Z t
_sandy_write_box livelive here-here-here-here-here claude /st/y "$$"   vfkit "" 2026-09-17T12:00:00Z t
_sandy_prune
[ ! -f "$SANDY_HOME/boxes/deadbeef.json" ] && ok "prune drops dead-pid box" || bad "prune dead"
[ -f "$SANDY_HOME/boxes/livelive.json" ]   && ok "prune keeps live-pid box" || bad "prune live"

# 6) rvport derivation: deterministic, in range, and matches a hand-computed value.
r1=$(_sandy_rvport_for_mac 02:ab:cd:11:22:33)
r2=$(_sandy_rvport_for_mac 02:AB:CD:11:22:33)   # case-insensitive
check "rvport deterministic (case-insensitive)" "$r1" "$r2"
want=$(( 21000 + (16#112233 % 2000) ))
check "rvport matches formula" "$want" "$r1"
[ "$r1" -ge 21000 ] && [ "$r1" -lt 23000 ] && ok "rvport in range" || bad "rvport range ($r1)"
# distinct MACs differ (last-3-octets differ)
r3=$(_sandy_rvport_for_mac 02:00:00:44:55:66)
[ "$r1" != "$r3" ] && ok "distinct MACs → distinct rvports" || bad "rvport collision on distinct MACs"

# 7) rvport-in-use: true for a live box holding the port, false when excluded or dead.
_sandy_write_box aaaa1111 a-a-a-a-a claude /st/a "$$"   vfkit 21500 t t
_sandy_write_box bbbb2222 b-b-b-b-b claude /st/b "$dead" vfkit 21600 t t
_sandy_rvport_in_use 21500 && ok "rvport_in_use → true for live holder" || bad "rvport_in_use live"
_sandy_rvport_in_use 21500 "$SANDY_HOME/boxes/aaaa1111.json" && bad "rvport_in_use should exclude self" || ok "rvport_in_use excludes self"
_sandy_rvport_in_use 21600 && bad "rvport_in_use should ignore dead box" || ok "rvport_in_use ignores dead holder"
_sandy_rvport_in_use 29999 && bad "rvport_in_use unused port" || ok "rvport_in_use → false for free port"

# 8) guest_alive: true only for a live vfkit/qemu whose argv carries the instance dir; false when
#    absent, and false for a non-hypervisor process even if its argv contains the dir (specificity).
if command -v pgrep >/dev/null 2>&1; then
  gi="$SANDY_HOME/i-live";  mkdir -p "$gi"
  gh="$SANDY_HOME/i-other"; mkdir -p "$gh"
  # Fake long-lived processes whose argv carries the inst dir. Scripts named after the real
  # binaries, run via `bash <script> <arg>` so the argv is unambiguous (nixpkgs coreutils is a
  # multicall binary, so `exec -a` would misdispatch). One looks like a hypervisor, one does not.
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$SANDY_HOME/vfkit"; chmod +x "$SANDY_HOME/vfkit"
  printf '#!/usr/bin/env bash\nsleep 300\n' > "$SANDY_HOME/socat"; chmod +x "$SANDY_HOME/socat"
  bash "$SANDY_HOME/vfkit" "--restful-uri" "unix://$gi/x.sock" & gpid=$!
  bash "$SANDY_HOME/socat" "$gh/agent.sock"                     & hpid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "vfkit.*$gi" >/dev/null 2>&1 && break; sleep 0.1; done
  _sandy_guest_alive "$gi"              && ok "guest_alive → true for live vfkit"          || bad "guest_alive missed a live vfkit"
  _sandy_guest_alive "$SANDY_HOME/nope" && bad "guest_alive false-positive on absent inst" || ok "guest_alive → false when no guest"
  _sandy_guest_alive "$gh"              && bad "guest_alive matched a non-hypervisor"       || ok "guest_alive → false for non-hypervisor with dir in argv"
  pkill -P "$gpid,$hpid" 2>/dev/null || true; kill "$gpid" "$hpid" 2>/dev/null || true
  wait "$gpid" "$hpid" 2>/dev/null || true
else
  ok "guest_alive tests skipped (no pgrep in sandbox)"
fi

# 9) reap_box guards teardown on a LIVE guest — the core regression: a stray INT/TERM must not
#    orphan a running box or wipe its /home. Stub _sandy_guest_alive so the guard is deterministic
#    (independent of real processes); this section runs last so no restore is needed.
mk_inst() { mkdir -p "$1"; : > "$1/home.img"; }

_sandy_guest_alive() { return 0; }   # pretend the guest is still running
_sandy_write_box livebox0 a-b-c-d-e claude "$SANDY_HOME/i-alive" 4242 vfkit 21001 t t
mk_inst "$SANDY_HOME/i-alive"
_sandy_reap_box "$SANDY_HOME/boxes/livebox0.json" "$SANDY_HOME/i-alive" 0
[ -f "$SANDY_HOME/boxes/livebox0.json" ] && ok "reap keeps record while guest alive"  || bad "reap deleted a live box (orphan!)"
[ -d "$SANDY_HOME/i-alive" ]             && ok "reap keeps inst dir while guest alive" || bad "reap wiped a live guest's dir"

_sandy_guest_alive() { return 1; }   # guest gone
_sandy_write_box ephbox00 a-b-c-d-e claude "$SANDY_HOME/i-eph" 4242 vfkit 21001 t t
mk_inst "$SANDY_HOME/i-eph"
_sandy_reap_box "$SANDY_HOME/boxes/ephbox00.json" "$SANDY_HOME/i-eph" 0
[ ! -f "$SANDY_HOME/boxes/ephbox00.json" ] && ok "reap drops record when guest gone"        || bad "reap kept a dead box"
[ ! -d "$SANDY_HOME/i-eph" ]               && ok "reap wipes ephemeral inst dir when gone"  || bad "reap left an ephemeral dir"

_sandy_write_box perbox00 a-b-c-d-e claude "$SANDY_HOME/i-persist" 4242 vfkit 21001 t t
mk_inst "$SANDY_HOME/i-persist"
_sandy_reap_box "$SANDY_HOME/boxes/perbox00.json" "$SANDY_HOME/i-persist" 1
[ ! -f "$SANDY_HOME/boxes/perbox00.json" ] && ok "reap drops record (persistent)"       || bad "reap kept a dead box (persistent)"
[ -d "$SANDY_HOME/i-persist" ]             && ok "reap preserves persistent inst dir"   || bad "reap wiped a persistent dir"

echo "── sandy suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
