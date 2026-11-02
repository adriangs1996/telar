#!/usr/bin/env python3
"""Boot the official Omarchy ARM64 desktop in an isolated development VM."""

import argparse
import concurrent.futures
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
RELEASE = "v1.2.0"
APP_NAME = "Try Omarchy.app"
APP_URL = f"https://github.com/omacom/try-omarchy/releases/download/{RELEASE}/TryOmarchy.dmg"
APP_SHA256 = "403e7695c824dc67448d9f273bd105c6a17db2e89fd120d9fc7df1d647af30ba"
DEFAULT_SSH_PORT = 2224
DEFAULT_MEMORY_MIB = 6144
DEFAULT_CPUS = 4
DEFAULT_DISK_GIB = 64
DOWNLOAD_CHUNK = 1024 * 1024
BOOT_TIMEOUT_SECONDS = 600
GUEST_USER = "telar"


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def run(command, **options):
    return subprocess.run([str(word) for word in command], check=True, **options)


def download(url, target, expected, size=None):
    if target.exists() and (size is None or target.stat().st_size == size):
        if digest(target) == expected:
            return target

    partial = target.with_name(target.name + ".download")
    if partial.exists() and size is not None and partial.stat().st_size > size:
        raise RuntimeError(f"Unexpected oversized download: {partial}")

    print(f"Downloading {target.name}", flush=True)
    run(["curl", "--fail", "--location", "--retry", "3", "--continue-at", "-",
         "--silent", "--show-error", "--output", partial, url])
    if (size is not None and partial.stat().st_size != size) or digest(partial) != expected:
        raise RuntimeError(f"Download verification failed: {partial}")

    partial.replace(target)
    return target


class Omarchy:
    def __init__(self, options):
        self.state = options.state.expanduser().resolve()
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.cache = self.state / "cache"
        self.cache.mkdir(exist_ok=True)
        self.app = self.state / "runtime" / APP_NAME
        self.resources = self.app / "Contents/Resources"
        self.machine = self.state / "machine"
        self.share = self.state / "share"
        self.port = options.ssh_port
        self.memory = options.memory
        self.cpus = options.cpus
        self.disk = options.disk

    def prepare_runtime(self):
        if sys.platform != "darwin" or platform.machine() != "arm64":
            raise RuntimeError("This launcher requires macOS on Apple Silicon")

        if not self.app.exists():
            image = download(APP_URL, self.cache / f"TryOmarchy-{RELEASE}.dmg", APP_SHA256)
            mounted = plistlib.loads(run(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", image],
                                        capture_output=True).stdout)
            volume = next(Path(item["mount-point"]) for item in mounted["system-entities"] if "mount-point" in item)
            try:
                self.app.parent.mkdir(parents=True, exist_ok=True)
                run(["ditto", volume / APP_NAME, self.app])
            finally:
                run(["hdiutil", "detach", volume])

        run(["codesign", "--verify", "--deep", "--strict", self.app], capture_output=True)
        return self.resources / "scripts/run-qemu-gpu.sh"

    def prepare_image(self):
        manifest = json.loads((self.resources / "guest/download.json").read_text())
        target = self.cache / "omarchy-aarch64-edge.img.zst"
        if target.exists() and target.stat().st_size == manifest["image"]["bytes"]:
            if digest(target) == manifest["image"]["sha256"]:
                return target

        parts = self.cache / "image-parts"
        parts.mkdir(exist_ok=True)

        def fetch(part):
            return download(part["url"], parts / part["url"].rsplit("/", 1)[1],
                            part["sha256"], part["bytes"])

        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            files = list(executor.map(fetch, manifest["parts"]))

        partial = target.with_suffix(".partial")
        with partial.open("wb") as output:
            for path in files:
                with path.open("rb") as source:
                    shutil.copyfileobj(source, output, DOWNLOAD_CHUNK)

        if partial.stat().st_size != manifest["image"]["bytes"] or digest(partial) != manifest["image"]["sha256"]:
            raise RuntimeError("The assembled Omarchy image failed verification")

        partial.replace(target)
        return target

    def environment(self, image):
        environment = dict(os.environ)
        for name in list(environment):
            if name.startswith(("OMARCHY_QEMU_", "OMARCHY_SHELL_", "QEMU_NETWORK_", "TRYOMARCHY_")):
                del environment[name]

        environment.update(
            OMARCHY_QEMU_GPU_STATE_ROOT=str(self.machine),
            OMARCHY_QEMU_GPU_FACTORY_IMAGE=str(image),
            OMARCHY_QEMU_GPU_CPUS=str(self.cpus),
            OMARCHY_QEMU_GPU_MEMORY_MIB=str(self.memory),
            OMARCHY_QEMU_GPU_DISK_GIB=str(self.disk),
            OMARCHY_QEMU_GPU_PORT_FORWARDS=f"tcp:{self.port}:22",
            OMARCHY_QEMU_GPU_IMMERSIVE="0",
            OMARCHY_QEMU_GPU_NOTCH="0",
            OMARCHY_QEMU_GPU_SHARED_FOLDER=str(self.share),
        )
        return environment

    def prepare(self):
        with (self.state / "operation.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            return self._prepare()

    def _prepare(self):
        launcher = self.prepare_runtime()
        image = self.prepare_image()
        self.share.mkdir(exist_ok=True)
        environment = self.environment(image)
        disk = self.machine / "shell/disk.img"
        if not disk.exists():
            with (self.state / "prepare.log").open("w") as output:
                run([launcher], env=dict(environment, OMARCHY_QEMU_GPU_DRY_RUN="1"),
                    stdout=subprocess.DEVNULL, stderr=output)

        if not (self.state / "owner-seeded.json").exists():
            self.seed_owner(disk)

        return launcher, environment

    def bootstrap(self):
        specification = importlib.util.spec_from_file_location("telar_linux_bootstrap", HERE / "vm.py")
        helper = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(helper)
        helper.NAME = "telar-omarchy-bootstrap"
        helper.STATE = self.state / "bootstrap"
        helper.MEMORY = "2G"
        helper.CPUS = "2"
        helper.DISK_SIZE = "12G"
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            helper.SSH_PORT = reservation.getsockname()[1]

        return helper

    def key(self):
        key = self.state / "id_ed25519"
        if not key.exists():
            run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "telar-omarchy-development", "-f", key])

        return key

    def seed_owner(self, disk):
        print("Preparing the development account in the new VM disk", flush=True)
        helper = self.bootstrap()
        seed = helper.serve_seed()
        try:
            helper.launch(False, seed.server_port, extra_arguments=[
                "-drive", f"if=none,id=omarchy-root,file={disk},format=raw",
                "-device", "virtio-blk-pci,drive=omarchy-root,serial=telar-omarchy",
            ])
            helper.wait_for_ssh()
            helper.guest("cloud-init status --wait >/dev/null")
            seed.shutdown()
            password = secrets.token_urlsafe(24)
            (self.state / "guest-password").write_text(password + "\n")
            public_key = self.key().with_suffix(".pub").read_text()
            setup = (HERE / "omarchy-owner.sh").read_text().replace("@GUEST_USER@", GUEST_USER).replace("@GUEST_PASSWORD@", password)
            unit = "[Service]\nExecStart=\nExecStart=/usr/local/lib/telar-vm/owner-setup\n"
            entries = {
                "usr/local/lib/telar-vm/owner-setup": (setup, 0o700),
                "etc/systemd/system/omarchy-provision-owner.service.d/50-telar-development.conf": (unit, 0o644),
                "var/lib/omarchy/provisioning/authorized_keys": (public_key, 0o600),
            }
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w") as archive:
                for name, (contents, permissions) in entries.items():
                    raw = contents.encode()
                    entry = tarfile.TarInfo(name)
                    entry.size = len(raw)
                    entry.mode = permissions
                    archive.addfile(entry, io.BytesIO(raw))
            payload.seek(0)
            script = r"""set -euo pipefail
device=/dev/disk/by-id/virtio-telar-omarchy-part2
for attempt in $(seq 1 30); do
    test ! -b "$device" || break
    sleep 1
done
test -b "$device"
mountpoint=$(mktemp -d)
sudo mount -t btrfs -o subvol=@ "$device" "$mountpoint"
trap 'sudo umount "$mountpoint"; rmdir "$mountpoint"' EXIT
sudo tar -xf - -C "$mountpoint"
sync
"""
            with tempfile.TemporaryFile() as source:
                source.write(payload.getvalue())
                source.seek(0)
                helper.guest(script, stdin=source)
            (self.state / "owner-seeded.json").write_text(json.dumps({"user": GUEST_USER, "public_key": public_key.strip()}) + "\n")
        finally:
            seed.shutdown()
            helper.stop()

    def running(self):
        record = self.state / "running.json"
        if not record.exists():
            return None

        data = json.loads(record.read_text())
        process = subprocess.run(["ps", "-p", str(data["pid"]), "-o", "command="], capture_output=True, text=True)
        launcher = str(self.resources / "scripts/run-qemu-gpu.sh")
        if process.returncode or launcher not in process.stdout:
            return None

        return data

    def start(self):
        with (self.state / "operation.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self._start()

    def _start(self):
        if self.running():
            print("The Omarchy development VM is already running")
            return

        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", self.port))

        launcher, environment = self._prepare()
        log = self.state / "launcher.log"
        with log.open("w") as output:
            process = subprocess.Popen([str(launcher)], env=environment, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)

        (self.state / "running.json").write_text(json.dumps({"pid": process.pid, "port": self.port}) + "\n")
        deadline = time.monotonic() + BOOT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"Omarchy stopped during startup; see {log}")

            if subprocess.run(self.ssh_command("true"), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                print(f"Omarchy is ready; SSH is on 127.0.0.1:{self.port}", flush=True)
                return

            time.sleep(3)

        raise RuntimeError(f"The VM is running but SSH is not ready; see {log} and the VM console")

    def ssh_command(self, *arguments, tty=False):
        remote = shlex.join(str(value) for value in arguments)
        port = (self.running() or {}).get("port", self.port)
        return ["ssh", "-p", str(port), "-i", str(self.key()), "-o", "IdentitiesOnly=yes",
                "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "ConnectTimeout=3",
                "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={self.state / 'known_hosts'}",
                "-o", "LogLevel=ERROR", *(["-t"] if tty else []), f"{GUEST_USER}@127.0.0.1",
                *([remote] if remote else [])]

    def qmp(self, command):
        log = (self.state / "launcher.log").read_text()
        lines = [line.split("QMP: ", 1)[1].strip() for line in log.splitlines() if "Ready. QMP: " in line]
        if not lines:
            raise RuntimeError("The VM monitor is not ready")

        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(lines[-1])
            with connection.makefile("rw") as stream:
                stream.readline()
                for request in [{"execute": "qmp_capabilities"}, {"execute": command}]:
                    stream.write(json.dumps(request) + "\n")
                    stream.flush()
                    while True:
                        response = json.loads(stream.readline())
                        if "error" in response:
                            raise RuntimeError(str(response["error"]))
                        if "return" in response:
                            break

    def stop(self):
        if not self.running():
            print("The Omarchy development VM is stopped")
            return

        self.qmp("system_powerdown")
        deadline = time.monotonic() + BOOT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if not self.running():
                print("The Omarchy development VM is stopped")
                return
            time.sleep(1)
        raise RuntimeError("Omarchy did not shut down; inspect the VM console")

    def sync(self):
        self.start()
        revision = run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        self.bootstrap().sync_sources(self.ssh_command, "src/telar")

        run(self.ssh_command("mkdir", "-p", ".local/lib/telar-vm"))
        with (HERE / "omarchy-build.sh").open("rb") as source:
            run(self.ssh_command("sh", "-c", "cat > .local/lib/telar-vm/build.sh"), stdin=source)
        (self.state / "checkout.json").write_text(json.dumps({"commit": revision}) + "\n")
        print(f"Guest sources updated from the working tree at {revision}", flush=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, default=Path(os.environ.get("TELAR_OMARCHY_STATE", ROOT / ".dev/omarchy-vm")))
    parser.add_argument("--ssh-port", type=int, default=DEFAULT_SSH_PORT)
    parser.add_argument("--memory", type=int, default=DEFAULT_MEMORY_MIB, help="Guest memory in MiB")
    parser.add_argument("--cpus", type=int, default=DEFAULT_CPUS)
    parser.add_argument("--disk", type=int, default=DEFAULT_DISK_GIB, help="Sparse virtual disk capacity in GiB")
    parser.add_argument("command", nargs="?", default="start", choices=["prepare", "start", "stop", "status", "shell", "exec", "sync", "build", "run"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    vm = Omarchy(options)
    if options.command == "prepare":
        vm.prepare()
    elif options.command == "start":
        vm.start()
    elif options.command == "stop":
        vm.stop()
    elif options.command == "status":
        print(json.dumps({"running": bool(vm.running()), "state": str(vm.state), "ssh_port": vm.port}, indent=2))
    elif options.command == "shell":
        vm.start()
        run(vm.ssh_command(tty=True))
    elif options.command == "exec":
        vm.start()
        run(vm.ssh_command(*options.arguments))
    elif options.command == "sync":
        vm.sync()
    elif options.command == "build":
        vm.sync()
        run(vm.ssh_command("bash", ".local/lib/telar-vm/build.sh", "build"))
    elif options.command == "run":
        vm.start()
        run(vm.ssh_command("bash", ".local/lib/telar-vm/build.sh", "run", *options.arguments))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"omarchy: {error}", file=sys.stderr)
        raise SystemExit(1)
