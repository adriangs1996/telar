# Linux test machine

For the C++ runtime and Qt Quick client on Omarchy, use the
[Omarchy development VM](OMARCHY.md). Its Apple Silicon launcher uses the
official Try Omarchy image and accelerated OpenGL.

`tools/vm/vm.py` runs a Fedora virtual machine under QEMU with a Wayland
desktop, so Telar's Linux runtime, CLI and Qt Quick client can be exercised
from any host: macOS on Apple Silicon (HVF, aarch64 guest), Linux
(KVM, guest matches the host CPU), or anything else QEMU supports with TCG,
which is slow but works.

Fedora supports both aarch64 and x86_64 guests, and provisioning starts Sway
with software rendering.

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

# Boot, provision and sync without building.
tools/vm/vm.py prepare

# Boot with a window showing the desktop. Without --display the desktop still
# runs on a virtual framebuffer, which `screenshot` captures.
tools/vm/vm.py up --display
tools/vm/vm.py start --display

tools/vm/vm.py status
tools/vm/vm.py stop

# Sync the working tree, then build the runtime, CLI and GUI inside the machine.
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

`build`, `run` and `gui-smoke` sync first. Sync copies the tracked and untracked,
non-ignored files of the working tree and deletes stale guest sources; edit on
the host.

`build` runs `tools/cpp bootstrap`, then `just runtime-build out-vm Release` and
`just gui-build out-vm Release` with the pinned toolchain, so the guest keeps
its builds in `services/runtime-cpp/out-vm` and `services/gui-cpp/out-vm`.
The first GUI build compiles the private Qt and takes a while. Sync leaves
those directories, `.toolchain`, `.dependencies-cache`, `.qt-cache` and `.dev`
alone. `run`, `gui-smoke` and `stop-runtime` use the CLI from `out-vm`, which
starts the `telar-runtime` beside it, with `telar-gui` on `PATH` and the
runtime socket and history under `.dev/vm`.

## The desktop

The `telar` user logs in on the console automatically and its shell starts
`sway` with a `foot` terminal open. The virtio GPU has no 3D acceleration, so
wlroots draws with pixman and OpenGL comes from Mesa's software driver. That
is enough to check the Qt Quick client on Wayland; it says nothing about frame
rate on real hardware. Provisioning installs the Fedora equivalents of
`packaging/release/install-linux-deps.sh`: the compiler, Perl, flex and bison
the private Qt build needs, and the X11/XCB, Wayland, xkbcommon, Fontconfig,
EGL/OpenGL, Vulkan and D-Bus headers its platform plugins link against.

## First boot

The first boot serves a cloud-init NoCloud seed from a local HTTP server on
the host; the guest reaches it through QEMU's user network. The seed creates
the `telar` user with the machine's SSH key and passwordless sudo, and enables
console autologin. `provision.sh` then installs the build dependencies and the
desktop; it is idempotent. The pinned LLVM, CMake, Ninja, Just and the Zig that
builds libghostty-vt come from `tools/cpp` on the first `build`.

## Native clipboard reads

Native clipboard reads retain at most 1 MiB, consume at most 16 KiB or 16 read
attempts per window-loop turn, and expire after five seconds without extending
the deadline for partial progress. Invalid UTF-8 completes as unavailable.
