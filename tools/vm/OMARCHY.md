# Omarchy development VM

Run from the repository root on an Apple Silicon Mac:

```sh
python3 tools/vm/omarchy.py start
python3 tools/vm/omarchy.py build
python3 tools/vm/omarchy.py run
```

The first start downloads the pinned, signed Try Omarchy application and its
official ARM64 image, verifies their SHA-256 checksums and creates a private
development account. Python 3.11 or newer and QEMU must be installed on the
host. A temporary headless Fedora VM prepares that account on the new disk
before Omarchy boots.

The default guest has four CPUs, 6 GiB RAM and a sparse 64 GiB disk. It uses
the bundled accelerated graphics backend in a window. Its SSH port is bound
to `127.0.0.1:2224`. A dedicated SSH key is generated for this VM; personal SSH
keys, agent forwarding and the host's SSH server are not used.

`build` installs guest dependencies, applies pending Omarchy migrations,
runs Omarchy's boot-chain check, copies the current working tree, builds
the pinned VT dependency with Zig 0.17 and compiles the C++ runtime and GUI in
Release mode. The runtime executes inside Linux. `run` uses a private runtime
socket and history database in the guest source tree, and starts the GUI on
the guest's Wayland session using OpenGL.

The GUI loads the guest user's `~/.config/telar/config.lua`, or the matching
path under `XDG_CONFIG_HOME`, and reloads changes to that file and its Lua
modules. Arguments after `run` are forwarded to the GUI; use
`run --no-config` explicitly to test the built-in defaults.

The first GUI build compiles the project's pinned Qt sources and keeps that
installation in the guest's `.qt-cache` for later builds. If package updates
replace Hyprland or its libraries, stop and start the VM after building so
the desktop uses the installed versions.

The development account has persistent automatic desktop login. The build
selects the installed Omarchy/UWSM session, including images whose update
replaces `omarchy.desktop` with `hyprland-uwsm.desktop`.

The VM launches Quickshell with Qt Quick's software renderer. Its accelerated
renderer produced opaque desktop layers after the Omarchy update, hiding
application windows. The override applies to the Omarchy shell launcher;
Telar uses OpenGL through the VM's accelerated graphics backend.

The VM's Hyprland overlay disables `quirks.skip_non_kms_dmabuf_formats`. With
that quirk enabled, Hyprland advertises only the virtual display plane's `XR24`
format to Wayland clients. Composited RGBA buffers need not support direct
scanout: the same virgl driver supports `AR24` and EGL configurations with eight
alpha bits. Disabling the filter restores those formats without changing the
renderer or restarting the runtime. The overlay is loaded on every desktop login
and installed by `build`; an already running desktop needs a configuration reload.

Telar clears the window to transparent and paints its configured background as a
scenegraph rectangle. This preserves premultiplied color as well as alpha with
both GPU and software rendering. Explicit terminal background colors remain
opaque. These VM choices do not change native Linux installations.

Check the overlay without a running compositor:

```sh
lua tools/vm/test_omarchy_environment.lua
```

Native Wayland/OpenGL checks after the fix identify `virgl (Apple M3)`,
`graphics_api=3` and eight alpha bits. Captured backgrounds at opacity 0.3, 0.9
and 1 have alpha 77, 230 and 255 respectively, retaining the configured RGB
within two channel steps instead of brightening it. The window-background
regression also passes on Wayland/OpenGL, Cocoa/Metal and both software backends.
Its isolated test fixture used `-O0`, linked against the Release GUI libraries;
these are correctness checks, not performance measurements. The four Lua overlay
cases pass. Reloading the overlay preserves the setting without config errors.
Only the GUI was restarted to remove its earlier software override; the runtime
PID and all preexisting direct child processes survived.

The Linux thickening checks pass `gui-font-resolver` and `gui-scene` with the
offscreen/software renderer. The three targeted text/cursor/preedit/procedural
scene checks also pass through accelerated XWayland. Direct accelerated Wayland
`gui-scene-test` font comparisons still fail, including unchanged-rendering and
procedural controls; one attempt reports capture DPR changing from 1.5 to 1.
Their cause remains open. The passing window-background regression does not
qualify those separate font comparisons.

The 2026-11-03 ARM64 validation built the Release runtime and GUI with the
pinned Qt sources. The Wayland/OpenGL smoke test reported
`connected=1 panes=1 graphics_api=3 error=` and saved a rendered terminal
window. The [runtime validation](../../src/runtime-cpp/README.md)
records the native Linux suites and sanitizer checks. A complete VM restart
preserved automatic login and the Quickshell override; the repeated GUI
smoke check passed with the same connection and OpenGL result.

Wayland virtual-keyboard input executed commands and displayed their output
after the client initialized. The first sequence, injected immediately when
the window gained focus, lost the `ec` prefix of `echo`. Later sequences
worked with and without an initial keyboard delay. Startup input buffering
remains unverified.

With the GUI closed, repeat the window check with:

```sh
python3 tools/vm/omarchy.py run --smoke-ms 12000 --screenshot /tmp/telar-linux-smoke.png
python3 tools/vm/omarchy.py exec journalctl --user -u telar-development -n 20 --no-pager
```

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
