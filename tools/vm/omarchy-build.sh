#!/bin/bash
set -euo pipefail

cd "$HOME/src/telar"
command=$1
shift

if [[ $command == build ]]; then
  sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --needed --noconfirm \
    base-devel cmake ninja clang llvm lld pkgconf git python rsync \
    openssl libnghttp2 brotli zstd sqlite libpng libpcap \
    qt6-base qt6-declarative qt6-shadertools qt6-svg qt6-wayland \
    fontconfig wayland wayland-protocols libxkbcommon libxcb \
    xcb-util-cursor xcb-util-image xcb-util-keysyms xcb-util-renderutil \
    xcb-util-wm mesa libglvnd

  bash tools/vm/install-zig.sh 0.17.0
  export PATH="$HOME/.local/bin:$PATH"

  python3 services/runtime-cpp/tools/build_ghostty.py \
    --build-dir services/runtime-cpp/dependencies/ghostty \
    --prefix services/runtime-cpp/dependencies/install

  cmake -S services/runtime-cpp -B services/runtime-cpp/out-vm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DGHOSTTY_VT_ROOT="$PWD/services/runtime-cpp/dependencies/install"
  cmake --build services/runtime-cpp/out-vm --target telar-runtime --parallel 2

  cmake -S services/gui-cpp -B services/gui-cpp/out-vm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DGHOSTTY_VT_ROOT="$PWD/services/runtime-cpp/dependencies/install"
  cmake --build services/gui-cpp/out-vm --target telar-gui --parallel 2

  mkdir -p .dev/vm/bin
  ln -sfn "$PWD/services/runtime-cpp/out-vm/telar-runtime" .dev/vm/bin/telar
  printf 'Telar C++ is built. Run tools/vm/omarchy.py run from the host.\n'
elif [[ $command == run ]]; then
  export PATH="$PWD/.dev/vm/bin:$PATH"
  export TELAR_SOCKET="$PWD/.dev/vm/runtime.sock"
  export TELAR_SOCKET_PATH="$TELAR_SOCKET"
  export TELAR_BIN_PATH="$PWD/.dev/vm/bin/telar"
  export TELAR_HISTORY="$PWD/.dev/vm/history.db"
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export QSG_RHI_BACKEND=opengl
  export QT_QPA_PLATFORM=wayland
  WAYLAND_DISPLAY=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -n 1)
  export WAYLAND_DISPLAY
  test -n "$WAYLAND_DISPLAY"
  test -x services/gui-cpp/out-vm/telar-gui
  telar server endpoint >/dev/null
  systemd-run --user --collect --unit=telar-development \
    --setenv=PATH="$PATH" --setenv=TELAR_SOCKET="$TELAR_SOCKET" \
    --setenv=TELAR_SOCKET_PATH="$TELAR_SOCKET_PATH" --setenv=TELAR_BIN_PATH="$TELAR_BIN_PATH" \
    --setenv=TELAR_HISTORY="$TELAR_HISTORY" --setenv=XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    --setenv=WAYLAND_DISPLAY="$WAYLAND_DISPLAY" --setenv=QSG_RHI_BACKEND=opengl \
    --setenv=QT_QPA_PLATFORM=wayland \
    "$PWD/services/gui-cpp/out-vm/telar-gui" --no-config --cwd "$PWD" "$@"
else
  printf 'Unknown operation: %s\n' "$command" >&2
  exit 2
fi
