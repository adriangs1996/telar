#!/bin/sh
# Echo latency under load: telar (isolated runtime) and tmux, with 0..8 panes
# flooding output while one idle pane is measured.
#
#   tools/load_bench.sh zig-out/bin/telar label
set -eu
binary=$1
label=$2
for name in $(env | sed -n 's/^\(TELAR_[A-Z_]*\)=.*/\1/p'); do unset "$name"; done
tools=$(cd "$(dirname "$0")" && pwd)
dir=${TMPDIR:-/tmp}/telar-load-$$
mkdir -p -m 700 "$dir/config"
sock=$dir/runtime.sock
# A runtime whose panes are still flooding does not finish stopping; the
# measurement must not wait for it.
stop() {
  TELAR_SOCKET_PATH=$sock XDG_DATA_HOME=$dir/data XDG_CONFIG_HOME=$dir/config \
    timeout 5 "$binary" server stop >/dev/null 2>&1 || true
  pkill -9 -f "server --daemonized --socket $sock" 2>/dev/null || true
  sleep 0.5
}
trap 'stop; tmux -L telarbench kill-server 2>/dev/null || true; rm -rf "$dir"' EXIT
for floods in ${FLOODS:-0 1 2 4 8}; do
  rm -rf "$dir/data"; mkdir -p -m 700 "$dir/data"
  python3 "$tools/load_latency.py" --mux telar --floods "$floods" \
    --env TELAR_SOCKET_PATH="$sock" --env XDG_DATA_HOME="$dir/data" --env XDG_CONFIG_HOME="$dir/config" \
    "$label" -- "$binary" --no-config
  stop
done
for floods in ${FLOODS:-0 1 2 4 8}; do
  python3 "$tools/load_latency.py" --mux tmux --floods "$floods" --warmup 1.5 \
    tmux -- tmux -L telarbench -f /dev/null new-session
  tmux -L telarbench kill-server 2>/dev/null || true
  sleep 0.5
done
