"""Argument checks of `telar-runtime traffic redirect`, which runs under sudo; tests/redirect_arguments_test.py runs them."""
import os
from pathlib import Path
import socket
import subprocess
import tempfile


def check_arguments(runtime):
    with tempfile.TemporaryDirectory(prefix="telar-redirect-", dir="/tmp") as directory:
        root = Path(directory)
        listeners = []

        def endpoint(name):
            # The redirect endpoint an owned runtime binds, private to its user.
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(root / f"{name}.redirect"))
            os.chmod(root / f"{name}.redirect", 0o600)
            listeners.append(listener)
            return str(root / name)

        def redirect(*arguments):
            return subprocess.run([str(runtime), "traffic", "redirect", *arguments], capture_output=True, text=True, timeout=15)

        try:
            plain = endpoint("runtime.sock")
            # A socket path whose endpoint exists, so only the newline refuses it.
            broken = endpoint("runtime\n.sock")
            process = str(os.getpid())

            baseline = redirect("--socket", plain, "--target", "127.0.0.1:8080", "--process", process, "--dry-run")
            assert baseline.returncode == 0 and "127.0.0.1" in baseline.stdout, baseline.stderr
            refused = {
                "newline in the socket": ("--socket", broken, "--target", "127.0.0.1:8080", "--dry-run"),
                "duplicate target": ("--socket", plain, "--target", "127.0.0.1:8080", "--target", "127.0.0.1:8080", "--dry-run"),
                "duplicate process": ("--socket", plain, "--target", "127.0.0.1:8080", "--process", process, "--process", process, "--dry-run"),
                "missing value": ("--dry-run", "--socket", plain, "--target"),
            }
            for name, arguments in refused.items():
                result = redirect(*arguments)
                assert result.returncode == 1 and result.stdout == "", f"{name}: {result.returncode} {result.stdout!r}"
        finally:
            for listener in listeners:
                listener.close()
