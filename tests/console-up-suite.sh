#!/usr/bin/env bash
# Behavioral regression suite for `vm up`'s interactive console driver
# (modules/microvms/vm-console-up.py). Drives the REAL driver against fake runners on a PTY — no
# VM/vfkit needed — proving the properties that make Ctrl-C safe inside a sandbox:
#   1. the runner's exit code propagates through the driver,
#   2. Ctrl-C typed at our terminal reaches the guest as byte 0x03 and does NOT kill the driver
#      (the whole point: a stray SIGINT would tear the sandbox down),
#   3. our stdin hitting EOF does not kill a still-running guest.
#
# Usage: console-up-suite.sh <path-to-vm-console-up.py>
set -uo pipefail
driver=${1:?usage: console-up-suite.sh <vm-console-up.py>}
case $driver in /*) ;; *) driver="$PWD/$driver" ;; esac  # absolute: we cd into a scratch dir below
BASH_BIN=$(command -v bash)
PY=$(command -v python3)
# `timeout` guards against a hung driver in CI; it may be absent on a bare dev box, so make it optional.
TIMEOUT=$(command -v timeout || true)
to() { if [ -n "$TIMEOUT" ]; then "$TIMEOUT" 60 "$@"; else "$@"; fi; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; cd "$work"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# ── 1) exit-code propagation + stdout bridging (stdin not a tty) ──────────────
cat > r-exit <<EOF
#!$BASH_BIN
echo BOOTED
exit 7
EOF
chmod +x r-exit
to "$PY" "$driver" ./r-exit </dev/null >out1 2>err1; rc=$?
[ "$rc" = 7 ]        && ok "exit code propagates (7)"       || bad "exit code propagates (got $rc)"
grep -q BOOTED out1  && ok "runner stdout is bridged"       || bad "runner stdout not bridged"

# ── 2) Ctrl-C is forwarded to the guest as a byte, not a signal (needs a PTY) ──
# The fake runner models vfkit: it does NOT touch its own tty (vfkit doesn't either). It relies on
# the driver having put the PTY *slave* in raw mode; if the driver failed to, the slave's cooked
# line discipline would turn the forwarded ^C into SIGINT for the runner (regression), which the
# INT trap catches. On success ^C arrives as a raw 0x03 byte, read here with `od`. Two markers close
# the race between the runner starting and the ^C send.
cat > r-ctrlc <<EOF
#!$BASH_BIN
trap 'printf "GOT:SIGINT\r\n"; exit 42' INT
echo READY
printf 'ARMED\r\n'
b=\$(od -An -N1 -tx1 | tr -d ' \r\n')
printf 'GOT:%s\r\n' "\$b"
exit 0
EOF
chmod +x r-ctrlc

to "$PY" - "$driver" ./r-ctrlc >out2 2>err2 <<'PY'
import os, pty, select, sys, time
driver, runner = sys.argv[1], sys.argv[2]
pid, master = pty.fork()
if pid == 0:
    os.execv(sys.executable, [sys.executable, driver, runner])
    os._exit(127)
buf = b""
def pump(until_marker=None, budget=8.0):
    global buf
    end = time.monotonic() + budget
    while time.monotonic() < end:
        try:
            r, _, _ = select.select([master], [], [], 0.2)
        except OSError:
            return False
        if r:
            try:
                d = os.read(master, 4096)
            except OSError:
                return False
            if not d:
                return False  # EOF: driver exited
            buf += d
            if until_marker and until_marker in buf:
                return True
    return False
pump(b"ARMED")                 # wait until the fake guest has armed its raw tty
os.write(master, b"\x03")      # type Ctrl-C at "our terminal"
pump()                          # drain until the driver exits (slave closed)
_, status = os.waitpid(pid, 0)
try:
    os.close(master)
except OSError:
    pass
sys.stdout.buffer.write(buf)
sys.stdout.buffer.flush()
signaled = os.WIFSIGNALED(status)
code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
sys.stderr.write(f"VERDICT signaled={int(signaled)} code={code}\n")
PY
grep -q "GOT:03" out2 && ok "Ctrl-C reaches the guest as byte 0x03" \
  || bad "Ctrl-C not forwarded (out: $(tr -d '\000' <out2 | tr '\r\n' '  '))"
grep -q "GOT:SIGINT" out2 \
  && bad "slave left cooked → ^C signalled the runner (the vfkit-killing regression)" \
  || ok "^C did not raise a signal in the runner (slave is raw)"
grep -q "VERDICT signaled=0 code=0" err2 && ok "driver + runner exit cleanly on Ctrl-C" \
  || bad "unclean exit on Ctrl-C ($(grep VERDICT err2 || echo 'no verdict'))"

# ── 3) our stdin EOF must not kill a still-running guest ──────────────────────
cat > r-eof <<EOF
#!$BASH_BIN
echo READY
sleep 0.5
echo LATE
exit 4
EOF
chmod +x r-eof
to "$PY" "$driver" ./r-eof </dev/null >out3 2>err3; rc=$?
[ "$rc" = 4 ]      && ok "runner runs to completion after stdin EOF (exit 4)" || bad "stdin EOF handling (rc=$rc)"
grep -q LATE out3  && ok "post-EOF guest output still bridged"                || bad "post-EOF output missing"

echo "── console-up suite: $pass passed, $fail failed ──"
[ "$fail" = 0 ]
