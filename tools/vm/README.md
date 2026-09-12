# Linux test machine

`tools/vm/vm.py` runs a Fedora virtual machine under QEMU with a Wayland
desktop, so Telar's Linux runtime, terminal client and native client can be
exercised from any host: macOS on Apple Silicon (HVF, aarch64 guest), Linux
(KVM, guest matches the host CPU), or anything else QEMU supports with TCG,
which is slow but works.

Fedora rather than Arch: Arch publishes cloud images for x86_64 only, and an
aarch64 host would have to emulate them. Fedora ships cloud-init images for
both architectures, its packages are recent enough for Mesa's software Vulkan,
and provisioning is one `dnf` line.

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

# Sync the working tree, then build or test inside the machine.
tools/vm/vm.py build
tools/vm/vm.py test --summary all

# Sync, build and run the terminal client in your terminal.
tools/vm/vm.py run --no-config

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

The `telar` user logs in on the console automatically and its shell starts
`sway` with a `foot` terminal open. The virtio GPU has no 3D acceleration, so
wlroots draws with pixman and Vulkan comes from Mesa's software driver. That
is enough to develop and verify the native client's Linux backend; it says
nothing about frame rate on real hardware. The backend's build needs
`wayland-scanner`, the `xdg-shell` protocol, the Vulkan headers and loader,
and `glslc` to regenerate the shaders; provisioning installs them.

## First boot

The first boot serves a cloud-init NoCloud seed from a local HTTP server on
the host; the guest reaches it through QEMU's user network. The seed creates
the `telar` user with the machine's SSH key and passwordless sudo, and enables
console autologin. `provision.sh` then installs the toolchain and the desktop
and pins Zig 0.16.0 by checksum. Both are idempotent.
