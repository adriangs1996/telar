# Omarchy development VM

Run from the repository root on an Apple Silicon Mac:

```sh
python3 tools/vm/omarchy.py start
python3 tools/vm/omarchy.py build
python3 tools/vm/omarchy.py run
```

The first start downloads the pinned, signed Try Omarchy application and its
official ARM64 image, verifies their SHA-256 checksums and creates a private
development account. QEMU must be installed on the host. A temporary headless
Fedora VM prepares that account on the new disk before Omarchy boots.

The default guest has four CPUs, 6 GiB RAM and a sparse 64 GiB disk. It uses
the bundled accelerated graphics backend in a window. Its SSH port is bound
to `127.0.0.1:2224`. A dedicated SSH key is generated for this VM; personal SSH
keys, agent forwarding and the host's SSH server are not used.

`build` installs guest dependencies, copies the current working tree, builds
the pinned VT dependency with Zig 0.17 and compiles the C++ runtime and GUI in
Release mode. The runtime executes inside Linux. `run` uses a private runtime
socket and history database in the guest source tree, and starts the GUI on
the guest's Wayland session using OpenGL.

```sh
python3 tools/vm/omarchy.py status
python3 tools/vm/omarchy.py shell
python3 tools/vm/omarchy.py exec uname -a
python3 tools/vm/omarchy.py sync
python3 tools/vm/omarchy.py stop
```

`sync` includes tracked files and untracked files that Git does not ignore.
Deleted sources are removed from the guest while build outputs and dependency
caches created by these helpers are preserved. Git metadata is not copied.

All VM state is under the ignored `.dev/omarchy-vm` directory. Its generated
login password is in `guest-password`. Override the state directory with
`--state PATH` or `TELAR_OMARCHY_STATE`; `--ssh-port`, `--cpus`, `--memory`
and `--disk` configure a new machine. Memory is expressed in MiB and disk
capacity in GiB. Stop a running machine before changing its configuration.

The VM is suitable for testing the native Linux runtime, Wayland integration
and GUI behavior. It does not establish native-hardware frame pacing or
120 Hz performance. The PF transparent-redirection helper remains specific
to macOS; Linux's explicit proxy and packet-capture paths are independent.
