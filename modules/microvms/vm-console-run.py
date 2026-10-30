#!/usr/bin/env python3
"""vm-console-run.py: PTY console driver for `vm run`.

Usage: vm-console-run.py <runner> <b64cmd>
  runner  – path to the (MAC-patched) microvm-run script; invoked with cwd = instance dir
  b64cmd  – base64-encoded (single line, no whitespace) shell command to run in the VM;
            stdout+stderr merged, streamed live to our stdout

Environment (all optional):
  VM_RUN_TIMEOUT    wall-clock budget in seconds for boot + command (default 600). On expiry the
                    VM is killed and the driver exits 124.
  VM_CONSOLE_LOG    file that receives every raw console byte as it arrives (mode 0600), so a
                    stuck boot or command stays visible. The path is printed at start.
  VM_HEARTBEAT      seconds between "[vm-run] heartbeat" lines on stderr (default 30; 0 = off).

Exit code: the exit code of the command run in the VM, 124 on timeout, or other non-zero on failure.

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

import base64
import os
import re
import select
import secrets
import signal
import sys
import termios
import time
import pty

CURSOR_QUERY = b"\x1b[6n"
BOOT_TIMEOUT = 360   # seconds to wait for multi-user.target
RUN_TIMEOUT  = 600   # default wall-clock budget (boot + command); override with VM_RUN_TIMEOUT
HEARTBEAT    = 30    # default seconds between heartbeat lines; override with VM_HEARTBEAT
EXIT_TIMEOUT = 124   # same code as timeout(1)

READY_RE = re.compile(
    rb'Reached target .*[Mm]ulti-[Uu]ser|login:\s*$', re.MULTILINE)
FATAL_RE = re.compile(
    rb'Kernel panic|Emergency Mode|Dependency failed for|'
    rb'cannot build|build of .* failed|operation not supported by device',
    re.IGNORECASE)


def _env_num(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        val = int(raw)
    except ValueError:
        sys.exit(f"[vm-run] {name} must be a non-negative integer, got '{raw}'")
    if val < 0:
        sys.exit(f"[vm-run] {name} must be a non-negative integer, got '{raw}'")
    return val


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} <runner> <b64cmd>")

    runner = sys.argv[1]
    b64cmd = sys.argv[2]
    nonce     = secrets.token_hex(8)
    begin_tag = f"__VMR_B_{nonce}__"
    end_tag   = f"__VMR_E_{nonce}__"

    run_timeout = _env_num("VM_RUN_TIMEOUT", RUN_TIMEOUT)
    if run_timeout == 0:
        sys.exit("[vm-run] VM_RUN_TIMEOUT must be > 0")
    heartbeat = _env_num("VM_HEARTBEAT", HEARTBEAT)
    start = time.monotonic()
    hard_deadline = start + run_timeout
    log_path = os.environ.get("VM_CONSOLE_LOG", "")
    log_fd = -1
    if log_path:
        try:
            log_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        except OSError as e:
            print(f"[vm-run] cannot open console log {log_path}: {e}", file=sys.stderr)
            log_path = ""
    print(
        f"[vm-run] timeout {run_timeout}s; console log: {log_path or '<none>'}",
        file=sys.stderr, flush=True,
    )

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
        # Don't rely on the guest's own `poweroff` (it may lack rights / hang) and never
        # block indefinitely on waitpid: SIGTERM, poll briefly, then escalate to SIGKILL.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(child_pid, sig)
            except ProcessLookupError:
                return
            for _ in range(30):  # up to ~3 s per signal
                try:
                    if os.waitpid(child_pid, os.WNOHANG)[0] != 0:
                        return
                except ChildProcessError:
                    return
                time.sleep(0.1)

    buf       = bytearray()
    phase     = "boot"
    deadline  = min(start + BOOT_TIMEOUT, hard_deadline)
    exit_code = 1
    timed_out = False
    total_bytes = 0
    next_beat = start + heartbeat if heartbeat else float("inf")

    try:
        while True:
            if phase == "done":
                break
            now = time.monotonic()
            if now > deadline:
                timed_out = True
                exit_code = EXIT_TIMEOUT
                print(
                    f"\n[vm-run] TIMEOUT after {int(now - start)}s in phase '{phase}'"
                    f" (budget {run_timeout}s); killing the VM."
                    + (f" Console log: {log_path}" if log_path else ""),
                    file=sys.stderr,
                )
                break
            if now >= next_beat:
                print(
                    f"[vm-run] heartbeat: phase={phase} elapsed={int(now - start)}s"
                    f" console_bytes={total_bytes}",
                    file=sys.stderr, flush=True,
                )
                next_beat = now + heartbeat

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
                total_bytes += len(chunk)
                if log_fd >= 0:
                    try:
                        os.write(log_fd, chunk)
                    except OSError:
                        pass
                # A guest shell may probe the console size with a cursor-position query (ESC[6n)
                # and block until it gets a reply, swallowing the injected command. Answer it.
                if CURSOR_QUERY in chunk:
                    _write("\x1b[24;80R")
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
                    # Skipped on macOS: there, clearing ECHO on the master stalls the slave's
                    # input and the injected command never runs. The base64 wrapping already keeps
                    # the sentinels out of any echo, so nothing depends on this step.
                    if sys.platform != "darwin":
                        try:
                            attrs = termios.tcgetattr(master_fd)
                            attrs[3] &= ~termios.ECHO
                            termios.tcsetattr(master_fd, termios.TCSANOW, attrs)
                        except termios.error:
                            pass
                    buf.clear()
                    # Step 3: send the command. The whole sentinel-wrapped script is base64-encoded
                    # so the line we type contains NO sentinel literals — base64's alphabet has no
                    # '_', so the tags can never appear in the (possibly echoed) command line, only
                    # in the decoded script's real output. This makes capture immune to the stty
                    # -echo race above (which the VM tty can win, echoing our command back).
                    inner = (
                        f"printf '{begin_tag}\\n';"
                        f" {{ printf '%s\\n' '{b64cmd}' | base64 -d | bash; }} 2>&1;"
                        f" _vmr_rc=$?; printf '{end_tag}%d\\n' \"$_vmr_rc\"; poweroff\n"
                    )
                    blob = base64.b64encode(inner.encode()).decode()
                    _write(f"printf '%s' '{blob}' | base64 -d | bash\n")
                    print("[vm-run] boot ready → command injected", file=sys.stderr)
                    phase    = "inject"
                    deadline = hard_deadline

            # ── inject: wait for the begin sentinel ──────────────────────────
            elif phase == "inject":
                idx = bytes(buf).find(begin_tag.encode())
                if idx != -1:
                    after = bytes(buf)[idx + len(begin_tag):]
                    after = after.lstrip(b"\r\n")
                    buf   = bytearray(after)
                    print("[vm-run] begin sentinel seen → capturing", file=sys.stderr)
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
                    print(f"[vm-run] end sentinel seen → exit {exit_code}", file=sys.stderr)
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
        if log_fd >= 0:
            os.close(log_fd)
        try:
            os.close(master_fd)
        except OSError:
            pass

    print(
        f"[vm-run] exit={exit_code} elapsed={int(time.monotonic() - start)}s"
        + (" (timeout)" if timed_out else "")
        + (f" log={log_path}" if log_path else ""),
        file=sys.stderr,
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
