# Linux test machine

`tools/vm/vm.py` runs a Fedora or Arch virtual machine under QEMU with a Wayland
desktop, so Telar's Linux runtime, CLI and native client can be exercised
from any host: macOS on Apple Silicon (HVF, aarch64 guest), Linux
(KVM, guest matches the host CPU), or anything else QEMU supports with TCG,
which is slow but works.

Fedora is the default and supports both aarch64 and x86_64 guests. Set
`TELAR_VM_DISTRO=arch` for the official Arch x86_64 cloud image, verified against
its published SHA256 checksum. An ARM host runs this image through TCG emulation.
Arch provisioning installs the dependencies for Telar's own Desktop compositor;
Fedora provisioning starts Sway for the standalone Zig GUI tests.

## Requirements

- `qemu-system-aarch64` or `qemu-system-x86_64`, `qemu-img`, and QEMU's EDK2
  firmware (Homebrew installs all of it with `brew install qemu`).
- `python3`, `ssh`, `ssh-keygen`, `curl`, `git`.
- 8 GiB of RAM and 40 GiB of disk for the machine. `TELAR_VM_MEMORY`,
  `TELAR_VM_CPUS`, `TELAR_VM_DISK` and `TELAR_VM_SSH_PORT` change the defaults.

Machine state lives outside the repository in `~/.cache/telar-vm/<name>`
(`TELAR_VM_STATE` and `TELAR_VM_NAME` override it): the pristine cloud image,
the machine's disk, its EFI variables, an SSH key made for it, `serial.log`,
`qemu.log` and the QMP socket.

## Commands

Run from the project root on the host:

```sh
# First run: download the image, create the disk, boot, provision, sync, build.
# Later runs: boot if stopped, re-run provisioning, sync, build.
tools/vm/vm.py up

# Boot with a window showing the desktop. Without --display the desktop still
# runs on a virtual framebuffer, which `screenshot` captures.
tools/vm/vm.py up --display
tools/vm/vm.py start --display

tools/vm/vm.py status
tools/vm/vm.py stop

# Sync the working tree, then build inside the machine.
tools/vm/vm.py build

# Sync, build and run a telar CLI command against the machine's development
# runtime (--help without arguments). The runtime stays in the foreground, so
# query it from a second host terminal. A window needs the desktop: use
# gui-smoke, or `telar gui` from the foot terminal there.
tools/vm/vm.py run server --no-config
tools/vm/vm.py run runtime status

tools/vm/vm.py shell
tools/vm/vm.py exec uname -a
tools/vm/vm.py stop-runtime

# Capture the machine's display to a PNG through QMP.
tools/vm/vm.py screenshot /tmp/telar-vm.png

# Sync, build, open `telar gui` on the machine's desktop, capture it to a
# PNG, then close it and its runtime. Fails if the window exits early.
tools/vm/vm.py gui-smoke /tmp/telar-gui.png
```

`build`, `test` and `run` sync first. Sync copies the tracked and untracked,
non-ignored files of the working tree and deletes stale guest sources; edit on
the host.

## The desktop

On Fedora, the `telar` user logs in on the console automatically and its shell starts
`sway` with a `foot` terminal open. The virtio GPU has no 3D acceleration, so
wlroots draws with pixman and Vulkan comes from Mesa's software driver. That
is enough to develop and verify the native client's Linux backend; it says
nothing about frame rate on real hardware. The backend's build needs
`wayland-scanner`, the `xdg-shell` and `ext-background-effect-v1` protocols,
the Vulkan headers and loader,
Fontconfig headers for installed font lookup, ATK/AT-SPI and GLib headers for
the accessibility bridge, and `glslc` to compile the GLSL
shaders as build dependencies. Provisioning
installs them along with the Vulkan validation layer. The native renderer
requires Vulkan 1.3, dynamic rendering, Synchronization2 and
`VK_EXT_swapchain_maintenance1`.

## Telar Desktop on Arch

Arch uses a separate machine named `telar-arch`. Use a different forwarded SSH
port if the Fedora VM is also running. `prepare` boots, provisions and syncs
without building the Zig GUI.

```sh
export TELAR_VM_DISTRO=arch
export TELAR_VM_SSH_PORT=2224
tools/vm/vm.py prepare
tools/vm/vm.py exec bash -lc 'cd ~/src/telar && zig build -Dgui=false'
tools/vm/vm.py exec bash -lc 'cd ~/src/telar && cmake -S services/desktop-mode -B services/desktop-mode/out/arch -G Ninja -DCMAKE_BUILD_TYPE=Debug'
tools/vm/vm.py exec bash -lc 'cd ~/src/telar && cmake --build services/desktop-mode/out/arch --target telar-desktop'
tools/vm/vm.py exec bash -lc '~/src/telar/tools/vm/desktop-smoke/start.sh'
tools/vm/desktop-smoke.py
tools/vm/vm.py screenshot /tmp/telar-desktop-arch.png
```

The starter creates an isolated runtime and Desktop state directory, then starts
Telar on tty1 using a logind session. No other compositor runs. QEMU's virtio
display uses wlroots pixman and Qt Quick software rendering. The smoke test
sends keyboard events through QEMU and saves screenshots and state snapshots
under the VM state directory's `desktop-smoke/` folder. Read session diagnostics
from `~/.local/state/telar-desktop-smoke/desktop-state/logs/latest.log` inside
the guest. The compositor's wlroots diagnostics also reach the system journal.

The test checks PTY input, display environment propagation, splits, tabs,
workspaces, reported geometry, Wayland and X11 application management, clipboard,
pointer focus, and graceful shutdown while the runtime and a child process
remain alive. It stops Desktop at the end. To repeat from a fresh isolated
runtime, pass `--reset` to `desktop-smoke/start.sh`; the previous state is moved
to a timestamped sibling directory. Starting without `--reset` reuses it.

`TELAR_VM_RUNTIME` and `TELAR_VM_DESKTOP`, passed to the starter inside the guest,
can select binaries built elsewhere. Sync preserves Desktop's `out/` directory.
Stop the graphical session with `sudo systemctl stop telar-desktop-smoke`;
the isolated runtime remains alive. The VM is disposable, and stopping the
whole VM ends its processes.

## First boot

The first boot serves a cloud-init NoCloud seed from a local HTTP server on
the host; the guest reaches it through QEMU's user network. The seed creates
the `telar` user with the machine's SSH key and passwordless sudo, and enables
console autologin. `provision.sh` then installs the toolchain and the desktop
and `install-zig.sh` pins Zig 0.16.0 by checksum. `provision-arch.sh` supplies
the alternative Arch dependencies. These provisioning steps are idempotent.

## Native clipboard reads

Native clipboard reads retain at most 1 MiB, consume at most 16 KiB or 16 read
attempts per window-loop turn, and expire after five seconds without extending
the deadline for partial progress. Invalid UTF-8 completes as unavailable.
