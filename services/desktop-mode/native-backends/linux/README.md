# Linux session

Telar Desktop is a Wayland compositor built with wlroots 0.20. It owns the
outputs, input seat, focus, placement and workspace visibility, and runs directly
from a Linux console. Sway and Hyprland are not dependencies. XWayland supplies
compatibility with X11 applications.

The compositor runs on a dedicated thread. Qt Quick is a Wayland client of that
compositor in the same process. Commands travel through a bounded queue and
eventfd; observations are coalesced into snapshots delivered on the Qt thread.
The shared workbench supplies tiling, tabs, Lua surfaces and workspace policy.

The runtime remains a separate process. Closing Desktop disconnects graphical
applications, but terminal processes and their history remain in the runtime.
A second Desktop refuses to replace a running compositor: replacing a Wayland
server would disconnect every graphical client.

## Build and install

The required development packages on Arch are:

```sh
sudo pacman -S --needed base-devel clang cmake ninja pkgconf luajit \
  qt6-base qt6-declarative qt6-wayland wlroots0.20 wayland wayland-protocols \
  wlr-protocols libxkbcommon libinput pixman libdrm mesa xorg-xwayland
cmake -S services/desktop-mode -B services/desktop-mode/out/arch -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build services/desktop-mode/out/arch --target telar-desktop
sudo cmake --install services/desktop-mode/out/arch
```

Clang must include `clang-scan-deps`. The separate `telar` runtime must be
installed beside Desktop or available to the login shell on `PATH`;
`zig build -Dgui=false` builds it. Installation includes the executable, a
Wayland session entry for display managers, application metadata, the portal
configuration and the wlroots license.

For session locking, notifications, autostart, input methods and portals:

```sh
sudo pacman -S --needed swaylock swayidle mako dex fcitx5 \
  xdg-desktop-portal-wlr xdg-desktop-portal-gtk wireplumber xdg-utils grim slurp
```

From an active console login with a valid `XDG_RUNTIME_DIR`:

```sh
dbus-run-session telar-desktop
```

An optional socket argument attaches to an already running runtime. The session
needs access to the active seat through logind/libseat. A nested session can be
selected with `WLR_BACKENDS=wayland` while another Wayland compositor is running.

The session exports `WAYLAND_DISPLAY`, `DISPLAY`, `XDG_SESSION_TYPE=wayland`,
`XDG_SESSION_DESKTOP=Telar` and `XDG_CURRENT_DESKTOP=Telar`, and publishes them to
D-Bus activation and the systemd user manager before Qt can activate portals.
New shells receive these values even when the runtime predates the graphical
session. Existing shells retain their original environment.

## Desktop integration

- XDG toplevels and popups, XWayland, client fullscreen/maximize, clipboard,
  primary selection and drag-and-drop. Hidden tabs disable scene nodes.
  Fullscreen covers the output; maximization respects Telar and external panels.
- Multiple outputs and independent spaces, output configuration through
  `wlr-randr`, fractional scaling, rotation and output power management.
  Workspaces survive output removal; another output takes ownership of them.
- Layer-shell panels and notifications, exclusive zones and keyboard focus.
- Text-input-v3, input-method-v2, candidate popups and virtual keyboards for
  input methods such as Fcitx5. XKB configuration uses `XKB_DEFAULT_LAYOUT`,
  `XKB_DEFAULT_VARIANT` and `XKB_DEFAULT_OPTIONS`.
- Relative pointer motion, pointer confinement/locking and touchpad gesture
  forwarding. `TELAR_TAP_TO_CLICK=0` disables tapping; `TELAR_NATURAL_SCROLL=1`
  enables natural scrolling; `TELAR_POINTER_ACCEL` accepts values from -1 to 1.
- XDG activation and foreign surface parenting for application/dialog focus.
  Activating an existing window can reveal its workspace and tab.
- Screenshot and monitor ScreenCast through xdg-desktop-portal-wlr and PipeWire.
  Other portal interfaces use the GTK backend. Modern image capture and legacy
  screencopy are both available; software rendering works with ScreenCast too.

Telar does not draw foreign titlebars and requests client-side decorations.
Minimize and window-menu capabilities are not advertised; tabs and workspaces
provide the workbench's window visibility policy.

## Session services and locking

Standalone sessions start installed `swayidle`, `mako` and XDG autostart entries
through `dex`, and activate PipeWire/WirePlumber through the systemd user manager.
Nested and headless sessions leave these services disabled.
`TELAR_SESSION_SERVICES=0` or `1` overrides that choice.

`Super+L` launches `swaylock` unless a configured shortcut consumes the key.
`swayidle` also handles logind lock requests, locking before sleep, and the idle
timeout. `TELAR_IDLE_TIMEOUT` defaults to 600 seconds; 0 disables the timeout.
`TELAR_LOCK_COMMAND` replaces the default `swaylock -f -c 16131d`; replacements
must implement ext-session-lock-v1 and return only after the lock is established
when used with `swayidle -w`.

The compositor acknowledges a lock only after every enabled output presents a
frame with the desktop hidden. Locking cancels ordinary grabs, shortcuts and
input-method focus. If the locker crashes, the desktop remains black and input
remains blocked until a replacement locker explicitly unlocks it.

## Validation and boundaries

On 2026-10-22, the Arch guest used kernel 7.2.11-arch1-1, wlroots 0.20.2,
Wayland 1.26.0 and Qt 6.12.0 under QEMU 11.1.2, with one virtio GPU and TCG on
an ARM64 host. Desktop used DRM/libinput, wlroots pixman and Qt Quick software
rendering. Clang 23.1.2 cross-compiled the executable against the guest's headers
and libraries; the runtime used Zig 0.16.0 targeting x86_64-linux-musl.

The 25 base smoke checks and the integration suites in `tools/vm/README.md`
cover terminal/runtime survival,
Wayland and X11 management, clipboard, GTK file drag-and-drop, IME protocol
roundtrips and real Fcitx Chinese input, fullscreen/maximize, layer-shell,
fractional scaling/rotation, pointer locking, output power cycling while locked,
lock failure/replacement, PAM
unlocking, portal screenshots and actual PipeWire video frames. A separate
headless session exercises two outputs and workspace preservation across output
disabling and reenabling. The macOS Desktop target also builds, and Clang static analysis reports no
diagnostics for the five compositor C modules. Teardown is exercised with a
mapped X11 client still alive.

Physical GPU drivers, monitor cable hotplug, suspend/resume and touchpad gestures
need hardware validation. Touchscreens and drawing tablets are not implemented.
The portal currently shares monitors, not individual windows. The VM tests do
not establish performance or compatibility on every Linux distribution.
