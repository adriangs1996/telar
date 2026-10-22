#!/usr/bin/env bash
set -euo pipefail

source_dir="$HOME/src/telar"
run_dir="$HOME/.local/state/telar-desktop-smoke"
desktop_binary="${TELAR_VM_DESKTOP:-$source_dir/services/desktop-mode/out/arch/telar-desktop}"
runtime_binary="${TELAR_VM_RUNTIME:-$source_dir/zig-out/bin/telar}"
[[ -x $desktop_binary && -x $runtime_binary ]]
if [[ ${1:-} == --reset ]]; then
    if systemctl is-active --quiet telar-desktop-smoke; then
        sudo systemctl stop telar-desktop-smoke
    fi
    if [[ -S $run_dir/runtime.sock ]]; then
        TELAR_SOCKET="$run_dir/runtime.sock" "$runtime_binary" server stop
    fi
    if [[ -d $run_dir ]]; then
        mv "$run_dir" "$run_dir.previous.$(date +%s)"
    fi
elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--reset]" >&2
    exit 1
fi
mkdir -p "$run_dir"
chmod 700 "$run_dir"
printf '%s\n' "$runtime_binary" > "$run_dir/runtime-binary"
cp "$source_dir/tools/vm/desktop-smoke/smoke.lua" "$run_dir/smoke.lua"
export TELAR_SOCKET="$run_dir/runtime.sock"
export TELAR_HISTORY="$run_dir/history.db"
"$runtime_binary" server endpoint > "$run_dir/endpoint"
sudo systemctl stop getty@tty1
sudo systemd-run --unit=telar-desktop-smoke --collect \
    --property="User=$USER" --property=PAMName=login \
    --property=StandardInput=tty --property=TTYPath=/dev/tty1 \
    --property=TTYReset=yes --property=TTYVHangup=yes \
    --property=StandardOutput=journal --property=StandardError=journal \
    --property=TimeoutStopSec=20 \
    /usr/bin/dbus-run-session /usr/bin/env \
    "HOME=$HOME" "XDG_RUNTIME_DIR=/run/user/$UID" \
    "TELAR_DESKTOP_CONFIG=$run_dir/smoke.lua" \
    "TELAR_DESKTOP_STATE_DIR=$run_dir/desktop-state" \
    WLR_BACKENDS=drm,libinput WLR_RENDERER=pixman QT_QUICK_BACKEND=software \
    "$desktop_binary" "$TELAR_SOCKET"
