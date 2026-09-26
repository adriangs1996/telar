#!/bin/sh
# Traces the client hot-path windows of the current tree.
# usage: docs/performance/client-model-cache/trace.sh NAME OUT_DIR
# Writes OUT_DIR/NAME.err (layout, bases, output digest) and OUT_DIR/NAME.vg
# (touched runs per window). Build the image once:
#   docker build -t telar-touchrange docs/performance/client-model-cache/touchrange
set -eu
name=$1
out=$(cd "$2" && pwd)
docker volume create telar-zigcache >/dev/null
docker run --rm -v "$PWD":/src -v telar-zigcache:/cache -v "$out":/out -w /src telar-touchrange sh -c "
  zig build build-cache-trace -Doptimize=ReleaseFast --cache-dir /cache/local --global-cache-dir /cache/global --prefix /cache/trace-$name &&
  /opt/vg/bin/valgrind --tool=lackey --log-file=/out/$name.vg /cache/trace-$name/bin/telar-cache-trace-tui 2> /out/$name.err &&
  tail -n 1 /out/$name.err"
