#!/usr/bin/env python3
"""vm-console-up.py: interactive PTY console for `vm up`.

Usage: vm-console-up.py <runner>
  runner – path to the (MAC-patched) microvm-run script; invoked with cwd = instance dir

Runs the runner (vfkit) on a PTY slave so vfkit's virtio-serial,stdio sees a real TTY, and
bridges that PTY to our own stdio. When our stdin is a TTY we put it in RAW mode, so Ctrl-C,
Ctrl-Z and Ctrl-\\ reach the guest shell as bytes over the serial console instead of signalling
THIS launcher — which would tear the whole sandbox down. The guest's initial window size is
copied from our terminal and SIGWINCH is propagated so resizing works. The terminal is always
restored on exit, whether the guest powered off, the runner failed, or it was killed.

Exit code: the runner's exit status (128+signal if the runner was killed by a signal).

This replaces the old `python -c pty.spawn` re-exec: pty.fork() here provides the guest TTY on
every launch (interactive or not), so vfkit no longer needs the caller to already own a PTY.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import tty


def _copy_winsize(dst_fd: int) -> None:
    """Mirror our terminal's window size onto the child PTY (best effort)."""
    try:
        packed = fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, b"\0" * 8)
    except OSError:
        packed = struct.pack("HHHH", 24, 80, 0, 0)  # sane default when stdin isn't a tty
    try:
        fcntl.ioctl(dst_fd, termios.TIOCSWINSZ, packed)
    except OSError:
        pass


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <runner>")
    runner = sys.argv[1]

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    stdin_is_tty = os.isatty(stdin_fd)

    pid, master_fd = pty.fork()
    if pid == 0:
        # Child: the runner's stdio is the PTY slave.
        os.execv(runner, [runner])
        os._exit(127)  # unreachable unless execv fails

    _copy_winsize(master_fd)
    signal.signal(signal.SIGWINCH, lambda *_: _copy_winsize(master_fd))

    saved = None
    if stdin_is_tty:
        try:
            saved = termios.tcgetattr(stdin_fd)
            tty.setraw(stdin_fd)  # -isig: ^C/^Z/^\ become bytes, forwarded to the guest
        except termios.error:
            saved = None

    stdin_open = True
    try:
        while True:
            watch = [master_fd]
            if stdin_open:
                watch.append(stdin_fd)
            try:
                readable, _, _ = select.select(watch, [], [])
            except InterruptedError:
                continue  # a SIGWINCH interrupted the wait; re-arm
            except OSError:
                break

            if master_fd in readable:
                try:
                    data = os.read(master_fd, 65536)
                except OSError:
                    break
                if not data:
                    break  # guest closed the console → runner exiting
                os.write(stdout_fd, data)

            if stdin_open and stdin_fd in readable:
                try:
                    data = os.read(stdin_fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    stdin_open = False  # our stdin hit EOF; keep the guest running
                else:
                    os.write(master_fd, data)
    finally:
        if saved is not None:
            try:
                termios.tcsetattr(stdin_fd, termios.TCSADRAIN, saved)
            except termios.error:
                pass
        try:
            os.close(master_fd)
        except OSError:
            pass

    _, status = os.waitpid(pid, 0)
    if os.WIFSIGNALED(status):
        sys.exit(128 + os.WTERMSIG(status))
    sys.exit(os.WEXITSTATUS(status))


if __name__ == "__main__":
    main()
