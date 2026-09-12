#!/usr/bin/env python3
"""A Linux desktop machine under QEMU for testing Telar on any host.

Usage: tools/vm/vm.py up|start|stop|status|shell|exec|sync|build|test|run|screenshot
"""
import hashlib
import http.server
import json
import os
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NAME = os.environ.get("TELAR_VM_NAME", "telar-vm")
STATE = Path(os.environ.get("TELAR_VM_STATE", Path.home() / ".cache/telar-vm")) / NAME
FEDORA = "43"
FEDORA_BUILD = "1.6"
MIRROR = "https://dl.fedoraproject.org/pub/fedora/linux/releases"
DISK_SIZE = os.environ.get("TELAR_VM_DISK", "40G")
MEMORY = os.environ.get("TELAR_VM_MEMORY", "8G")
CPUS = os.environ.get("TELAR_VM_CPUS", "4")
SSH_PORT = int(os.environ.get("TELAR_VM_SSH_PORT", "2223"))
USER = "telar"
GUEST_SRC = "src/telar"


def guest_arch():
    machine = platform.machine().lower()
    return "aarch64" if machine in ("arm64", "aarch64") else "x86_64"


def accelerator():
    if sys.platform == "darwin":
        return "hvf"
    if Path("/dev/kvm").exists():
        return "kvm"
    return "tcg"


def qemu_binary():
    binary = shutil.which(f"qemu-system-{guest_arch()}")
    if binary is None:
        raise RuntimeError(f"qemu-system-{guest_arch()} is not installed")
    return binary


def firmware_dir():
    share = Path(qemu_binary()).resolve().parent.parent / "share/qemu"
    if share.is_dir():
        return share
    for candidate in ("/usr/share/qemu", "/usr/share/edk2/aarch64", "/usr/share/OVMF"):
        if Path(candidate).is_dir():
            return Path(candidate)
    raise RuntimeError("QEMU firmware directory not found")


def image_name():
    return f"Fedora-Cloud-Base-Generic-{FEDORA}-{FEDORA_BUILD}.{guest_arch()}.qcow2"


def image_url(name):
    return f"{MIRROR}/{FEDORA}/Cloud/{guest_arch()}/images/{name}"


def download(url, target):
    # curl honours the host's proxy settings, where urllib trips over them.
    subprocess.run(
        ["curl", "--fail", "--location", "--retry", "3", "--progress-bar", "--output", str(target), url],
        check=True,
    )


def fetch_base_image():
    base = STATE / image_name()
    if base.exists():
        return base
    STATE.mkdir(parents=True, exist_ok=True)
    checksum_file = STATE / "CHECKSUM"
    download(image_url(f"Fedora-Cloud-{FEDORA}-{FEDORA_BUILD}-{guest_arch()}-CHECKSUM"), checksum_file)
    checksums = checksum_file.read_text()
    expected = None
    for line in checksums.splitlines():
        if line.startswith(f"SHA256 ({image_name()}) = "):
            expected = line.rsplit(" ", 1)[1]
    if expected is None:
        raise RuntimeError("image checksum not published")
    partial = base.with_suffix(".partial")
    download(image_url(image_name()), partial)
    digest = hashlib.sha256()
    with partial.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        partial.unlink()
        raise RuntimeError("image checksum mismatch")
    partial.rename(base)
    return base


def ssh_key():
    key = STATE / "id_ed25519"
    if not key.exists():
        STATE.mkdir(parents=True, exist_ok=True)
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", NAME, "-f", str(key)], check=True)
    return key


def cloud_config():
    public_key = ssh_key().with_suffix(".pub").read_text().strip()
    return f"""#cloud-config
hostname: {NAME}
users:
  - name: {USER}
    groups: [wheel, video, input, render]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - {public_key}
ssh_pwauth: false
growpart:
  mode: auto
  devices: ['/']
"""


class SeedHandler(http.server.BaseHTTPRequestHandler):
    """Serves the NoCloud seed cloud-init fetches from the host on first boot."""

    files = {}

    def do_GET(self):
        body = self.files.get(self.path.rsplit("/", 1)[-1])
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def serve_seed():
    SeedHandler.files = {
        "meta-data": f"instance-id: {NAME}\nlocal-hostname: {NAME}\n".encode(),
        "user-data": cloud_config().encode(),
        "vendor-data": b"",
    }
    server = http.server.HTTPServer(("127.0.0.1", 0), SeedHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def create_disk(base):
    disk = STATE / "disk.qcow2"
    if disk.exists():
        return disk
    subprocess.run(
        ["qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", str(base), str(disk), DISK_SIZE],
        check=True,
    )
    return disk


def firmware_args():
    firmware = firmware_dir()
    if guest_arch() == "aarch64":
        code = firmware / "edk2-aarch64-code.fd"
        vars_template = firmware / "edk2-arm-vars.fd"
    else:
        code = firmware / "edk2-x86_64-code.fd"
        vars_template = firmware / "edk2-i386-vars.fd"
    variables = STATE / "efi-vars.fd"
    if not variables.exists():
        shutil.copyfile(vars_template, variables)
    return [
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={variables}",
    ]


def machine_args():
    accel = accelerator()
    if guest_arch() == "aarch64":
        return ["-machine", f"virt,accel={accel}", "-cpu", "host" if accel != "tcg" else "max"]
    return ["-machine", f"q35,accel={accel}", "-cpu", "host" if accel != "tcg" else "max"]


def display_args(display):
    if not display:
        return ["-display", "none"]
    # zoom-to-fit scales the guest's framebuffer to the window, so a resized
    # window on a HiDPI screen shows the desktop larger than 1:1.
    backend = "cocoa" if sys.platform == "darwin" else "gtk"
    return ["-display", f"{backend},show-cursor=on,zoom-to-fit=on"]


def pid_path():
    return STATE / "qemu.pid"


def running_pid():
    try:
        pid = int(pid_path().read_text())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid


def launch(display, seed_port=None):
    pid = running_pid()
    if pid:
        print(f"{NAME} is already running (pid {pid}); stop it first to change the display")
        return
    disk = create_disk(fetch_base_image())
    command = [
        qemu_binary(),
        *machine_args(),
        "-smp", CPUS,
        "-m", MEMORY,
        *firmware_args(),
        "-drive", f"file={disk},if=virtio,format=qcow2,discard=unmap",
        "-device", "virtio-net-pci,netdev=net0",
        "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22",
        "-device", "virtio-gpu-pci",
        "-device", "virtio-keyboard-pci",
        "-device", "virtio-tablet-pci",
        "-device", "virtio-rng-pci",
        *display_args(display),
        "-qmp", f"unix:{STATE / 'qmp.sock'},server,nowait",
        "-serial", f"file:{STATE / 'serial.log'}",
        "-monitor", "none",
    ]
    if seed_port is not None:
        command += ["-smbios", f"type=1,serial=ds=nocloud;s=http://10.0.2.2:{seed_port}/"]
    log = (STATE / "qemu.log").open("ab")
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    pid_path().write_text(str(process.pid))
    time.sleep(1)
    if process.poll() is not None:
        raise RuntimeError(f"QEMU exited immediately; see {STATE / 'qemu.log'}")


def ssh_command(*args, **kwargs):
    # ssh joins the remote words with spaces; quote each so scripts survive.
    remote = " ".join(shlex.quote(str(arg)) for arg in args)
    return [
        "ssh",
        "-p", str(SSH_PORT),
        "-i", str(ssh_key()),
        "-o", "IdentitiesOnly=yes",
        "-o", f"UserKnownHostsFile={STATE / 'known_hosts'}",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=5",
        "-o", "ServerAliveInterval=15",
        "-o", "LogLevel=ERROR",
        *(["-t"] if kwargs.get("tty") else []),
        f"{USER}@127.0.0.1",
        *([remote] if remote else []),
    ]


def wait_for_ssh(timeout=600):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if subprocess.run(ssh_command("true"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return
        if running_pid() is None:
            raise RuntimeError(f"QEMU stopped while booting; see {STATE / 'serial.log'}")
        time.sleep(3)
    raise RuntimeError("the machine did not accept SSH in time")


def require_running():
    if running_pid() is None:
        raise RuntimeError(f"{NAME} is not running; start it with tools/vm/vm.py start")


def guest(script, *args, tty=False, stdin=None):
    require_running()
    subprocess.run(ssh_command("bash", "-c", script, "telar-vm", *args, tty=tty), check=True, stdin=stdin)


def sync():
    require_running()
    # Copy the working tree, including uncommitted changes, but no ignored files.
    # A staging directory lets rsync remove stale sources without deleting caches.
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT
    ).split(b"\0")
    script = f'''set -euo pipefail
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
tar -xf - -C "$stage"
mkdir -p "$HOME/{GUEST_SRC}"
rsync -a --delete --exclude=/.zig-cache/ --exclude=/zig-out/ --exclude=/.zig-out/ --exclude=/zig-pkg/ \\
    "$stage/" "$HOME/{GUEST_SRC}/"
'''
    with subprocess.Popen(ssh_command("bash", "-c", script), stdin=subprocess.PIPE) as process:
        try:
            with tarfile.open(fileobj=process.stdin, mode="w|", dereference=False) as archive:
                for raw in sorted(set(names)):
                    if not raw:
                        continue
                    name = os.fsdecode(raw)
                    path = ROOT / name
                    if path.is_file() or path.is_symlink():
                        archive.add(path, arcname=name, recursive=False)
        finally:
            process.stdin.close()
        if process.wait():
            raise RuntimeError("Working tree sync failed")


def build(*args):
    guest(f'export PATH="$HOME/.local/bin:$PATH"; cd "$HOME/{GUEST_SRC}" && exec zig build -j{CPUS} "$@"', *args)


def gui_smoke(screenshot_path):
    """Builds, opens the native client on the machine's desktop, captures it and closes it."""
    sync()
    build()
    guest(f'''set -euo pipefail
cd "$HOME/{GUEST_SRC}"
mkdir -p -m 700 .zig-out/dev
export WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="/run/user/$(id -u)"
export TELAR_SOCKET="$PWD/.zig-out/dev/runtime.sock" TELAR_HISTORY="$PWD/.zig-out/dev/history.db"
./zig-out/bin/telar gui --login-shell --no-config > .zig-out/dev/gui-smoke.log 2>&1 &
gui=$!
sleep 8
if ! kill -0 "$gui" 2> /dev/null; then
    echo "telar gui exited early:" >&2
    cat .zig-out/dev/gui-smoke.log >&2
    exit 1
fi
echo "$gui" > .zig-out/dev/gui-smoke.pid
# --login-shell execs twice in place, so the window keeps the pid we started.
tr "\\0" "\\n" < "/proc/$gui/environ" | grep -q "^TELAR_LOGIN_SHELL=1$" || {{
    echo "telar gui did not come through the login shell" >&2
    exit 1
}}
''')
    try:
        screenshot(screenshot_path)
    finally:
        guest(f'''cd "$HOME/{GUEST_SRC}"
kill "$(cat .zig-out/dev/gui-smoke.pid 2> /dev/null)" 2> /dev/null || true
# The bracket keeps this shell, whose command line holds the pattern, out of the match.
pkill -f "[t]elar gui" 2> /dev/null || true
TELAR_SOCKET="$PWD/.zig-out/dev/runtime.sock" ./zig-out/bin/telar server stop > /dev/null
''')


def qmp(command, **arguments):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(str(STATE / "qmp.sock"))
        stream = connection.makefile("rw", encoding="utf-8")
        stream.readline()
        for message in ({"execute": "qmp_capabilities"}, {"execute": command, "arguments": arguments}):
            stream.write(json.dumps(message) + "\n")
            stream.flush()
            while True:
                reply = json.loads(stream.readline())
                if "return" in reply:
                    break
                if "error" in reply:
                    raise RuntimeError(reply["error"]["desc"])
        return reply["return"]


def stop():
    pid = running_pid()
    if pid is None:
        print("not running")
        return
    try:
        qmp("system_powerdown")
    except (OSError, RuntimeError):
        pass
    for _ in range(60):
        if running_pid() is None:
            return
        time.sleep(1)
    os.kill(pid, 15)


def screenshot(path):
    target = Path(path).resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    qmp("screendump", filename=str(target), format="png")
    print(target)


def up(display):
    first_boot = not (STATE / "disk.qcow2").exists()
    seed = serve_seed() if first_boot else None
    launch(display, seed.server_port if seed else None)
    wait_for_ssh()
    if first_boot:
        # cloud-init keeps reading the seed until it finishes the first boot.
        guest("cloud-init status --wait > /dev/null || true")
        seed.shutdown()
    with (HERE / "provision.sh").open("rb") as script:
        guest("bash -s", stdin=script)
    sync()
    build()


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "help"
    args = sys.argv[2:]
    display = "--display" in args
    args = [arg for arg in args if arg != "--display"]
    if command == "up":
        up(display)
    elif command == "start":
        launch(display)
        wait_for_ssh()
    elif command == "stop":
        stop()
    elif command == "status":
        pid = running_pid()
        print(f"{NAME}: {'running, pid ' + str(pid) if pid else 'stopped'}; state in {STATE}")
    elif command == "sync":
        sync()
    elif command in ("build", "test"):
        sync()
        build(*(["test"] if command == "test" else []), *args)
    elif command == "run":
        sync()
        build()
        guest(f'''set -euo pipefail
cd "$HOME/{GUEST_SRC}"
export PATH="$HOME/.local/bin:$PATH"
mkdir -p -m 700 .zig-out/dev
export TELAR_SOCKET="$PWD/.zig-out/dev/runtime.sock"
export TELAR_HISTORY="$PWD/.zig-out/dev/history.db"
exec ./zig-out/bin/telar "$@"
''', *(args or ["--no-config"]), tty=True)
    elif command == "stop-runtime":
        guest(f'cd "$HOME/{GUEST_SRC}" && TELAR_SOCKET="$PWD/.zig-out/dev/runtime.sock" exec ./zig-out/bin/telar server stop')
    elif command == "shell":
        guest(f'cd "$HOME/{GUEST_SRC}" && exec bash -l', tty=True)
    elif command == "exec":
        guest(f'export PATH="$HOME/.local/bin:$PATH"; cd "$HOME/{GUEST_SRC}" && exec "$@"', *args)
    elif command == "screenshot":
        screenshot(args[0] if args else STATE / "screenshot.png")
    elif command == "gui-smoke":
        gui_smoke(args[0] if args else STATE / "gui-smoke.png")
    else:
        print("Usage: tools/vm/vm.py COMMAND [--display] [ARGS]")
        print("Commands: up, start, stop, status, shell, exec, sync, build, test, run, stop-runtime, screenshot, gui-smoke")
        print("build/test/run sync first. Sync replaces guest source changes; edit on the host.")
        if command != "help":
            raise SystemExit(2)


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
