#!/bin/bash
set -euo pipefail

cd "$HOME/src/telar"
command=$1
shift

if [[ $command == build ]]; then
  sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --needed --noconfirm \
    base-devel cmake ninja clang llvm lld pkgconf git python rsync perl flex bison \
    fontconfig wayland wayland-protocols libxkbcommon libxkbcommon-x11 libxcb \
    libx11 libxext libxfixes libxi libxrender \
    xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil \
    xcb-util-wm mesa libglvnd

  OMARCHY_UPDATE_UNATTENDED=1 OMARCHY_ALLOW_DIRECT_PACMAN=1 omarchy-migrate
  omarchy-update-boot

  desktop_session=omarchy.desktop
  if [[ ! -f /usr/share/wayland-sessions/$desktop_session ]]; then
    desktop_session=hyprland-uwsm.desktop
  fi
  test -f "/usr/share/wayland-sessions/$desktop_session"
  printf '[Autologin]\nUser=%s\nSession=%s\nRelogin=true\n' "$(id -un)" "$desktop_session" \
    | sudo tee /etc/sddm.conf.d/zz-telar-development.conf >/dev/null

  install -Dm755 tools/vm/omarchy-shell.sh "$HOME/.local/lib/telar-vm/bin/omarchy-launch-shell"
  install -Dm644 tools/vm/omarchy-environment.lua "$HOME/.local/lib/telar-vm/environment.lua"
  desktop_environment='dofile(os.getenv("HOME") .. "/.local/lib/telar-vm/environment.lua")'
  desktop_autostart="$HOME/.config/hypr/autostart.lua"
  if ! rg -F -x -q -- "$desktop_environment" "$desktop_autostart"; then
    printf '\n%s\n' "$desktop_environment" >>"$desktop_autostart"
  fi

  bash tools/vm/install-zig.sh 0.17.0
  export PATH="$HOME/.local/bin:$PATH"

  python3 src/runtime-cpp/tools/build_ghostty.py \
    --build-dir src/runtime-cpp/dependencies/ghostty \
    --prefix src/runtime-cpp/dependencies/install

  cmake -S src/runtime-cpp -B src/runtime-cpp/out-vm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DGHOSTTY_VT_ROOT="$PWD/src/runtime-cpp/dependencies/install"
  cmake --build src/runtime-cpp/out-vm --target telar-runtime telar telar-config-check --parallel 2

  cmake -S src/gui-cpp -B src/gui-cpp/out-vm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DGHOSTTY_VT_ROOT="$PWD/src/runtime-cpp/dependencies/install"
  cmake --build src/gui-cpp/out-vm --target telar-gui --parallel 2

  mkdir -p .dev/vm/bin
  # The CLI starts the telar-runtime built beside it.
  ln -sfn "$PWD/src/runtime-cpp/out-vm/telar" .dev/vm/bin/telar
  printf 'Telar C++ is built. Run tools/vm/omarchy.py run from the host.\n'
elif [[ $command == run ]]; then
  export PATH="$PWD/.dev/vm/bin:$PATH"
  export TELAR_SOCKET="$PWD/.dev/vm/runtime.sock"
  export TELAR_SOCKET_PATH="$TELAR_SOCKET"
  export TELAR_BIN_PATH="$PWD/.dev/vm/bin/telar"
  export TELAR_HISTORY="$PWD/.dev/vm/history.db"
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR
  export QSG_RHI_BACKEND=opengl
  export QT_QPA_PLATFORM=wayland
  test -x src/gui-cpp/out-vm/telar-gui

  desktop_startup_timeout_seconds=60
  desktop_probe_interval_seconds=1
  desktop_startup_deadline=$((SECONDS + desktop_startup_timeout_seconds))
  while true; do
    WAYLAND_DISPLAY=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' -quit)
    if [[ -n $WAYLAND_DISPLAY && -S $XDG_RUNTIME_DIR/bus ]]; then
      break
    fi

    if (( SECONDS >= desktop_startup_deadline )); then
      printf 'The Omarchy Wayland session did not become ready.\n' >&2
      exit 1
    fi

    sleep "$desktop_probe_interval_seconds"
  done
  export WAYLAND_DISPLAY

  telar server endpoint >/dev/null
  systemd-run --user --collect --unit=telar-development \
    --setenv=PATH="$PATH" --setenv=TELAR_SOCKET="$TELAR_SOCKET" \
    --setenv=TELAR_SOCKET_PATH="$TELAR_SOCKET_PATH" --setenv=TELAR_BIN_PATH="$TELAR_BIN_PATH" \
    --setenv=TELAR_HISTORY="$TELAR_HISTORY" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    --setenv=WAYLAND_DISPLAY="$WAYLAND_DISPLAY" --setenv=QSG_RHI_BACKEND=opengl \
    --setenv=QT_QPA_PLATFORM=wayland \
    "$PWD/src/gui-cpp/out-vm/telar-gui" --cwd "$PWD" "$@"
else
  printf 'Unknown operation: %s\n' "$command" >&2
  exit 2
fi
