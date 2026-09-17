# sandy-lib.sh — pure helpers for the `sandy` orchestration layer (box identity + registry).
#
# `sandy` is the orchestrator that tracks running sandboxes ("boxes"). Each running box gets a
# unique identity (a five-word name + an 8-hex short id) and a record under ~/.config/.sandy/boxes/.
# These helpers are side-effect-free w.r.t. VM state and depend only on the filesystem + `kill -0`,
# so they are unit-tested without a hypervisor (see tests/sandy-suite.sh). Inlined into nix-vm at
# build time via `builtins.readFile`; sourced directly by the test. Function/array definitions only.
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
