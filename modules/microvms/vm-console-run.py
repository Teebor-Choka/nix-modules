#!/usr/bin/env python3
"""vm-console-run.py: PTY console driver for `vm run`.

Usage: vm-console-run.py <runner> <b64cmd>
  runner  – path to the (MAC-patched) microvm-run script; invoked with cwd = instance dir
  b64cmd  – base64-encoded (single line, no whitespace) shell command to run in the VM;
            stdout+stderr merged, streamed live to our stdout

Exit code: the exit code of the command run in the VM, or non-zero on failure.

Design notes:
  - pty.fork() puts the runner on the PTY slave so vfkit's virtio-serial,stdio sees a TTY.
  - Boot phase: scan console for multi-user.target (or fatal markers), with a timeout.
  - Inject phase:
      1. Send "stty -echo\\n" and wait 1 s so the VM's tty driver disables terminal echo.
      2. Disable the host PTY's slave echo via termios so our injected command text does not
         appear in the master's output (prevents the begin-sentinel from matching its own echo).
      3. Send the sentinel-wrapped command: printf BEGIN; decode+bash 2>&1; printf END$?; poweroff
  - Capture phase: stream bytes between the unique sentinels to stdout, strip \\r\\n artifacts,
    extract the exit code from the end sentinel.
  - Teardown: SIGTERM the child pid (targets only this instance, unlike pkill), waitpid.
"""

import os
import re
import select
import secrets
import signal
import sys
import termios
import time
import pty

BOOT_TIMEOUT = 360   # seconds to wait for multi-user.target
RUN_TIMEOUT  = 3600  # seconds budget for the command itself

READY_RE = re.compile(
    rb'Reached target .*[Mm]ulti-[Uu]ser|login:\s*$', re.MULTILINE)
FATAL_RE = re.compile(
    rb'Kernel panic|Emergency Mode|Dependency failed for|'
    rb'cannot build|build of .* failed|operation not supported by device',
    re.IGNORECASE)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} <runner> <b64cmd>")

    runner = sys.argv[1]
    b64cmd = sys.argv[2]
    nonce     = secrets.token_hex(8)
    begin_tag = f"__VMR_B_{nonce}__"
    end_tag   = f"__VMR_E_{nonce}__"

    child_pid, master_fd = pty.fork()
    if child_pid == 0:
        # Child: exec the runner. Its stdin/stdout/stderr are the PTY slave.
        os.execv(runner, [runner])
        os._exit(127)  # unreachable unless execv fails

    # ─── Parent: drive the VM console ─────────────────────────────────────────

    def _write(data: str) -> None:
        try:
            os.write(master_fd, data.encode())
        except OSError:
            pass

    def _child_alive() -> bool:
        try:
            return os.waitpid(child_pid, os.WNOHANG)[0] == 0
        except ChildProcessError:
            return False

    def _kill_child() -> None:
        try:
            os.kill(child_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(child_pid, 0)
        except ChildProcessError:
            pass

    buf       = bytearray()
    phase     = "boot"
    deadline  = time.monotonic() + BOOT_TIMEOUT
    exit_code = 1

    try:
        while True:
            if phase == "done":
                break
            if time.monotonic() > deadline:
                print(
                    f"\n[vm-run] timed out in phase '{phase}'",
                    file=sys.stderr,
                )
                break

            try:
                r, _, _ = select.select([master_fd], [], [], 0.5)
            except (OSError, ValueError):
                break

            if r:
                try:
                    chunk = os.read(master_fd, 8192)
                except OSError:
                    break
                if not chunk:
                    break
                buf.extend(chunk)
            elif not _child_alive():
                break

            # ── boot: watch for multi-user.target (or fatal) ─────────────────
            if phase == "boot":
                snap = bytes(buf)
                if FATAL_RE.search(snap):
                    print("\n[vm-run] fatal boot error:", file=sys.stderr)
                    for ln in snap.split(b'\n')[-6:]:
                        print(" ", ln.decode(errors='replace'), file=sys.stderr)
                    break
                if READY_RE.search(snap):
                    # Step 1: disable VM-side terminal echo
                    time.sleep(0.5)
                    _write("stty -echo\n")
                    time.sleep(1.0)   # give the VM's tty driver time to process stty
                    # Step 2: disable host PTY slave echo so our command text does not
                    # appear in the master's output stream (prevents sentinel false-match)
                    try:
                        attrs = termios.tcgetattr(master_fd)
                        attrs[3] &= ~termios.ECHO
                        termios.tcsetattr(master_fd, termios.TCSANOW, attrs)
                    except termios.error:
                        pass
                    buf.clear()
                    # Step 3: send the sentinel-wrapped command as a single shell line.
                    # Using printf '%s\n' avoids echo-specific escape expansion.
                    # The { ... } 2>&1 group captures both stdout and stderr of the command.
                    # _vmr_rc captures bash's exit code independently of pipefail settings.
                    _write(
                        f"printf '{begin_tag}\\n';"
                        f" {{ printf '%s\\n' '{b64cmd}' | base64 -d | bash; }} 2>&1;"
                        f" _vmr_rc=$?; printf '{end_tag}%d\\n' $_vmr_rc; poweroff\n"
                    )
                    phase    = "inject"
                    deadline = time.monotonic() + RUN_TIMEOUT

            # ── inject: wait for the begin sentinel ──────────────────────────
            elif phase == "inject":
                idx = bytes(buf).find(begin_tag.encode())
                if idx != -1:
                    after = bytes(buf)[idx + len(begin_tag):]
                    after = after.lstrip(b"\r\n")
                    buf   = bytearray(after)
                    phase = "capture"

            # ── capture: stream output until the end sentinel ─────────────────
            elif phase == "capture":
                snap    = bytes(buf)
                end_enc = end_tag.encode()
                idx     = snap.find(end_enc)
                if idx != -1:
                    # Flush everything before the end sentinel, normalising line endings
                    out = snap[:idx].replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                    sys.stdout.buffer.write(out)
                    sys.stdout.buffer.flush()
                    # Parse the exit code that immediately follows the sentinel
                    rest = snap[idx + len(end_enc):]
                    m    = re.match(rb"(\d+)", rest)
                    if m:
                        exit_code = int(m.group(1))
                    phase = "done"
                else:
                    # Stream the safe prefix; hold back len(end_enc) bytes for partial matches
                    safe = max(0, len(buf) - len(end_enc))
                    if safe > 0:
                        out = bytes(buf[:safe]).replace(b"\r\n", b"\n").replace(b"\r", b"\n")
                        sys.stdout.buffer.write(out)
                        sys.stdout.buffer.flush()
                        buf = bytearray(buf[safe:])

    finally:
        _kill_child()
        try:
            os.close(master_fd)
        except OSError:
            pass

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
