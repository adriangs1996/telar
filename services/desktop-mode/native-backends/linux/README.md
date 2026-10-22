# Linux session

Telar Desktop is a Wayland compositor built with wlroots 0.20. It owns the
outputs, input seat, focus, window placement and workspace visibility. It runs
directly from a Linux console; Sway and Hyprland are not dependencies.
XWayland supplies compatibility with X11 applications.

The compositor runs on a dedicated thread. Qt Quick is a Wayland client of that
compositor in the same process. The compositor consumes client buffers through
wlroots; Qt windows and other applications use the same scene. Commands travel
through a bounded queue and eventfd; observations are coalesced into snapshots
delivered on the Qt thread. The existing workbench supplies tiling, tabs, Lua
surfaces and workspace policy.

The runtime remains a separate process. Closing Desktop disconnects graphical
applications, but terminal processes and their history remain in the runtime.
A second Desktop refuses to replace a running compositor. This differs from
the macOS Desktop handoff, because replacing a Wayland server would disconnect
every client of that server.

## Build on Arch Linux

Install the dependencies in `tools/vm/provision-arch.sh`, or run that script in
a disposable Arch machine. It also configures console autologin for the VM, so
do not run the provisioning script on a personal workstation.

```sh
cmake -S services/desktop-mode -B services/desktop-mode/out/arch -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug
cmake --build services/desktop-mode/out/arch --target telar-desktop
```

Clang with `clang-scan-deps`, CMake, Ninja, Qt Quick and Qt Wayland, LuaJIT,
wlroots 0.20 development files, libwayland and xkbcommon are required.
XWayland must be installed to run X11 applications.
The separate `telar` runtime must be installed beside Desktop or available to
the login shell on `PATH`; it can also be built with `zig build -Dgui=false`.

From an active console login, with a valid `XDG_RUNTIME_DIR`:

```sh
dbus-run-session services/desktop-mode/out/arch/telar-desktop /path/to/runtime.sock
```

Omit the socket argument to use the existing runtime discovery. Installing the
CMake target also installs `share/wayland-sessions/telar.desktop`, for display
managers that discover Wayland sessions. The session needs access to the active
seat through logind/libseat. A nested session can be selected with
`WLR_BACKENDS=wayland` while another Wayland compositor is running.

The session sets `WAYLAND_DISPLAY`, `DISPLAY`, `XDG_SESSION_TYPE=wayland` and
`XDG_CURRENT_DESKTOP=Telar`. New shells started through Desktop receive these
values even when the runtime predates the graphical session. Existing shells
retain the environment with which they were launched.

## Current scope

The backend implements XDG toplevels and popups, XWayland windows, keyboard and
pointer input, global shortcuts, clipboard and primary selection, screencopy,
output enumeration, and one visible workspace per output. Hidden tabs disable
their scene nodes; they do not park windows offscreen. Telar's wallpaper and
panels are internal surfaces in separate scene layers.

External layer-shell panels, input-method protocols, a session locker, desktop
portals and drag-and-drop integration are not implemented. Screen sharing
through PipeWire and input methods requiring those protocols are therefore
outside this backend's current scope. Hardware GPU rendering and monitor
hotplug require testing on physical machines; a software-rendered VM cannot
validate them.

Application requests for maximization or fullscreen do not override the
workbench layout. Use the workbench's maximize and floating commands.

See `tools/vm/README.md` for the Arch/QEMU workflow and reproducible smoke test.

## Validation recorded on 2026-10-22

The Arch guest ran kernel 7.2.11-arch1-1, wlroots 0.20.2, Wayland 1.26.0 and
Qt 6.12.0 under QEMU 11.1.2, with one virtio GPU and TCG on an ARM64 host.
Desktop used DRM/libinput, wlroots pixman and Qt Quick software rendering.
The Linux executable was cross-compiled with Clang 23.1.2 against the guest's
headers and libraries. The runtime was built with Zig 0.16.0 for
`x86_64-linux-musl`.

All 24 checks in `tools/vm/desktop-smoke.py` passed, including actual keyboard
input through QEMU, focus transfer between Telar and an external Wayland
window, XWayland discovery and closure, clipboard paste, observed geometry,
and shutdown with both the runtime and a child process still alive. The test
keeps six screenshots and desktop/runtime/workbench snapshots in the VM's
state directory. Session diagnostics remain in the guest's Desktop log directory.

A separate headless session verified automatic runtime startup, an unblocked
signal mask in that runtime, and graceful Desktop termination by SIGTERM.
The macOS Desktop target also compiled successfully. CMake installation was
checked for the executable, Wayland session entry and wlroots license.
