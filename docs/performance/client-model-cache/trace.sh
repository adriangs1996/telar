#!/bin/sh
# Traces the client hot-path windows of the current tree, terminal and
# native adapters.
# usage: docs/performance/client-model-cache/trace.sh NAME OUT_DIR
# Writes OUT_DIR/NAME-{tui,gui}.err (layout, bases, output digest) and
# OUT_DIR/NAME-{tui,gui}.vg (touched runs per window). Build the images once:
#   docker build -t telar-touchrange docs/performance/client-model-cache/touchrange
#   docker build -t telar-touchrange-gui -f docs/performance/client-model-cache/touchrange/Dockerfile.gui docs/performance/client-model-cache/touchrange
set -eu
name=$1
out=$(cd "$2" && pwd)
docker volume create telar-zigcache >/dev/null
docker run --rm -v "$PWD":/src -v telar-zigcache:/cache -v "$out":/out -w /src telar-touchrange-gui sh -c "
  zig build build-cache-trace -Doptimize=ReleaseFast --cache-dir /cache/local --global-cache-dir /cache/global --prefix /cache/trace-$name &&
  for adapter in tui gui; do
    /opt/vg/bin/valgrind --tool=lackey --log-file=/out/$name-\$adapter.vg /cache/trace-$name/bin/telar-cache-trace-\$adapter 2> /out/$name-\$adapter.err
    tail -n 1 /out/$name-\$adapter.err
  done"
