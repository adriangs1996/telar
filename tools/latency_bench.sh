#!/bin/sh
# Measures keystroke-to-echo latency and flood throughput of one telar binary
# against an isolated runtime socket, so the live runtime is never touched.
#
#   tools/latency_bench.sh zig-out/bin/telar label
set -eu
binary=$1
label=$2
# A shell running inside telar inherits pane identity; none of it may leak
# into the measured processes.
for name in $(env | sed -n 's/^\(TELAR_[A-Z_]*\)=.*/\1/p'); do unset "$name"; done
tools=$(cd "$(dirname "$0")" && pwd)
dir=${TMPDIR:-/tmp}/telar-bench-$$
mkdir -p -m 700 "$dir"
sock=$dir/runtime.sock
shell=$dir/catshell
# The runtime persists its session checkpoint and history under XDG_DATA_HOME;
# the measured runtime must not read or write the user's real ones.
# Each pass gets a fresh data directory: a restored session would put focus
# on the previous pass's pane instead of the one this pass launched.
mkdir -p -m 700 "$dir/data-1B" "$dir/data-2B" "$dir/data-flood" "$dir/config"
isolation() { echo "--env TELAR_SOCKET_PATH=$sock --env XDG_DATA_HOME=$dir/data-$1 --env XDG_CONFIG_HOME=$dir/config"; }
printf '#!/bin/sh\nexec /bin/cat\n' > "$shell"
chmod +x "$shell"
serving() { ps -axo command | grep "[s]erver --daemonized --socket $sock" || echo "no runtime on $sock"; }
stop() { serving; TELAR_SOCKET_PATH=$sock XDG_DATA_HOME=$dir/data-flood XDG_CONFIG_HOME=$dir/config "$binary" server stop >/dev/null 2>&1 || true; sleep 0.5; }
trap 'stop; rm -rf "$dir"' EXIT
python3 "$tools/echo_latency.py" --shell "$shell" --samples 200 --gap 0.05 --warmup 3 --single \
  $(isolation 1B) "$label-1B" -- "$binary" --no-config
stop
python3 "$tools/echo_latency.py" --shell "$shell" --samples 200 --gap 0.05 --warmup 3 \
  $(isolation 2B) "$label-2B" -- "$binary" --no-config
stop
python3 "$tools/flood.py" $(isolation flood) "$label-flood" -- "$binary" --no-config
