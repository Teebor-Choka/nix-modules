# sandy-lib.sh — pure helpers for the `sandy` orchestration layer (box identity + registry).
#
# `sandy` is the orchestrator that tracks running sandboxes ("boxes"). Each running box gets a
# unique identity (a five-word name + an 8-hex short id) and a record under ~/.config/.sandy/boxes/.
# These helpers depend only on the filesystem, `kill -0`, and `pgrep` (guest liveness), so they are
# unit-tested without a hypervisor (see tests/sandy-suite.sh). Most are side-effect-free w.r.t. VM
# state; `_sandy_reap_box` is the teardown path and mutates local instance state. Inlined into nix-vm
# at build time via `builtins.readFile`; sourced directly by the test. Function/array definitions only.
#
# Records are flat JSON (one field per line) so they can be read without jq: `_sandy_field` extracts
# a value with sed. Values must not contain `"` or `,` — box fields (ids, vm names, store paths,
# ports, ISO timestamps, tty/pid) never do.

# Word pool for the human-friendly box name. Kept short, unambiguous, lowercase; ~128 words →
# 128^5 ≈ 3.4e10 combinations, and name collisions are resolved by regenerating against the registry.
SANDY_WORDS=(
  amber arc ash aspen azure basil bay beacon birch bloom blue bold branch brave brook cedar chai
  charm cider clay cliff cloud clover coal cobalt comet copper coral cove crisp crow dawn deft delta
  dew drift dusk ember fable fawn fern flint flare fox frost glade gold grove hazel heron hollow ivy
  jade jasper jet kelp lark lawn leaf lemon lily lime lunar maple marsh mint mist moss moth north
  oak ochre onyx opal otter pearl pebble pine plum quartz quick quill rain raven reed ridge river
  rowan rune rust sage sand shale shore silk slate snow spark spruce steel stone storm swift teal
  thorn tide topaz twig vale vine violet willow wren zephyr
)

# Root of the sandy state tree. Overridable (SANDY_HOME) so tests point it at a scratch dir.
_sandy_home()      { printf '%s' "${SANDY_HOME:-$HOME/.config/.sandy}"; }
_sandy_boxes_dir() { printf '%s/boxes' "$(_sandy_home)"; }

# _sandy_gen_shortid → 8 lowercase hex chars.
_sandy_gen_shortid() { od -An -N4 -tx1 /dev/urandom | tr -d ' \n'; }

# Reverse-tunnel port range on the shared host tunnel sshd. Each box's `ssh -R <rvport>:localhost:22`
# lands on a port in [SANDY_RVBASE, SANDY_RVBASE+SANDY_RVRANGE). host and guest MUST derive the same
# rvport from the same NIC MAC — hence one shared formula, used by both sides.
SANDY_RVBASE=21000
SANDY_RVRANGE=2000

# _sandy_rvport_for_mac <mac> → the deterministic rvport for a NIC MAC (e.g. 02:ab:cd:11:22:33).
# The host derives it from the MAC it assigns/reads; the guest derives it from /sys/.../address.
# Collisions among concurrent instances are resolved host-side (regenerate the MAC).
_sandy_rvport_for_mac() {
  local hex
  hex=$(printf '%s' "$1" | tr -d ':' | tr 'A-F' 'a-f')
  hex=${hex: -6}                                   # last 3 octets → 24 bits of entropy
  printf '%d' $(( SANDY_RVBASE + (16#$hex % SANDY_RVRANGE) ))
}

# _sandy_gen_name → five words joined by '-' (e.g. twinkly is not in the pool; e.g. "otter-maple-…").
_sandy_gen_name() {
  local n=${#SANDY_WORDS[@]} out="" i idx
  for i in 1 2 3 4 5; do
    idx=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % n ))
    out="${out:+$out-}${SANDY_WORDS[$idx]}"
  done
  printf '%s' "$out"
}

# _sandy_field <box-file> <key> → prints the field's value (unquoted), empty if absent.
_sandy_field() {
  grep -m1 "\"$2\":" "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*"[^"]*":[[:space:]]*"?([^",]*)"?,?[[:space:]]*$/\1/'
}

# _sandy_write_box <short_id> <id_name> <vm_name> <inst_dir> <pid> <hypervisor> <rvport> <created> <owner_session>
#   Writes ~/.config/.sandy/boxes/<short_id>.json. `rvport` may be empty (filled once a tunnel exists).
_sandy_write_box() {
  local dir; dir=$(_sandy_boxes_dir)
  mkdir -p "$dir"
  cat > "$dir/$1.json" <<EOF
{
  "short_id": "$1",
  "id_name": "$2",
  "vm_name": "$3",
  "inst_dir": "$4",
  "pid": $5,
  "hypervisor": "$6",
  "rvport": "$7",
  "created": "$8",
  "owner_session": "$9"
}
EOF
}

# _sandy_box_alive <box-file> → true when the owning process is still running.
_sandy_box_alive() {
  local pid; pid=$(_sandy_field "$1" pid)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _sandy_prune → drop records whose owning process is gone (crash/SIGKILL backstop).
_sandy_prune() {
  local f
  for f in "$(_sandy_boxes_dir)"/*.json; do
    [ -e "$f" ] || continue
    _sandy_box_alive "$f" || rm -f "$f"
  done
}

# _sandy_rvport_in_use <rvport> [exclude_file] → true if a LIVE box already holds this rvport
# (ignoring `exclude_file`). Used host-side to bump an ephemeral MAC until its derived port is free.
_sandy_rvport_in_use() {
  local want=$1 excl=${2:-} f
  for f in "$(_sandy_boxes_dir)"/*.json; do
    [ -e "$f" ] || continue
    [ "$f" = "$excl" ] && continue
    [ "$(_sandy_field "$f" rvport)" = "$want" ] || continue
    _sandy_box_alive "$f" && return 0
  done
  return 1
}

# _sandy_resolve <short_id|id_name> → prints the matching box file path, or returns 1.
_sandy_resolve() {
  local dir; dir=$(_sandy_boxes_dir)
  if [ -f "$dir/$1.json" ]; then printf '%s' "$dir/$1.json"; return 0; fi
  local f
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    [ "$(_sandy_field "$f" id_name)" = "$1" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# _sandy_guest_alive <inst_dir> → true if a hypervisor (vfkit/qemu) for THIS instance is still
# running: its argv carries the instance dir (vfkit's --restful-uri, qemu's relative volume paths).
# Gates teardown (see _sandy_reap_box). No pgrep on PATH → treated as not-alive, so teardown still
# runs (matches the pre-guard behaviour). The inst dir is per-launch unique, so this never matches a
# sibling instance of the same VM.
_sandy_guest_alive() {
  local inst=$1
  [ -n "$inst" ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -f "(vfkit|qemu).*$inst" >/dev/null 2>&1
}

# _sandy_reap_box <box_file> <inst_dir> [persistent] → tear down a box: kill its per-instance helper
# pids, drop transient files + the sandy record, and (ephemeral only) wipe the instance dir. A
# NO-OP while the guest is still running, so a stray INT/TERM to the launcher can't orphan a live
# box (delete its record → invisible to `vm list`, unattachable) or rm -rf a live guest's /home. On
# real teardown the hypervisor has already exited and this proceeds. Called from the _vm_prepare trap.
_sandy_reap_box() {
  local box=$1 inst=$2 persistent=${3:-0} pf
  [ -n "$inst" ] || return 0
  _sandy_guest_alive "$inst" && return 0
  for pf in "$inst"/*.pid; do
    [ -e "$pf" ] || continue
    kill "$(cat "$pf")" 2>/dev/null || true
  done
  rm -f "$inst"/*.pid "$inst"/*.sock "$inst"/instance.lock
  rm -f "$box"
  [ "$persistent" = 1 ] || rm -rf "$inst"
}
