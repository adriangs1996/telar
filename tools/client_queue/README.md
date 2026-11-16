# Client queue trace

Measures, for two runtime builds, how much output is queued to each client when `stop()` runs and how long
a client's queue takes to empty: per queued frame, from being queued until its last byte leaves in a
`write()`, and per busy period of a queue, from non-empty to empty. It was written for the open question of
P11.1 in `TODO.md` (signature (a) of `server-cli-tests`) and compares the refactor's module tree
(`src/runtime`) with `main`'s header tree (`services/runtime-cpp`).

Nothing here changes the runtime: `instrument.py` edits a disposable worktree.

## Repeat the measurement

```sh
# Two disposable worktrees: the head under test and main.
git worktree add --detach ../queue-head HEAD
git worktree add --detach ../queue-main main
tools/client_queue/instrument.py ../queue-head
tools/client_queue/instrument.py ../queue-main

# Head: the pinned toolchain, Release.
(cd ../queue-head && tools/setup-checkout && tools/cpp configure release -- -DBUILD_TESTING=ON -DTELAR_BUILD_GUI=OFF \
  && tools/cpp build release -- --target telar telar-runtime checkpoint-probe pane-traffic-probe)

# main: as its CI builds services/runtime-cpp (Homebrew LLVM and libraries on macOS), Release.
B=$(brew --prefix)/opt
(cd ../queue-main/services/runtime-cpp && python3 tools/build_ghostty.py --build-dir /tmp/main-vt-build --prefix /tmp/main-vt \
  && cmake -S . -B /tmp/main-release -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=$B/llvm/bin/clang++ \
       -DGHOSTTY_VT_ROOT=/tmp/main-vt -DOPENSSL_ROOT_DIR=$B/openssl@3 -DNGHTTP2_ROOT=$B/libnghttp2 -DBROTLI_ROOT=$B/brotli \
       -DZSTD_ROOT=$B/zstd -DPNG_ROOT=$B/libpng -DTELAR_RUNTIME_INSTALL_DESKTOP_COMMAND=ON \
  && cmake --build /tmp/main-release --target telar-runtime checkpoint-probe pane-traffic-probe)
```

Build one tree at a time and measure on a machine at rest. Then, for each scenario, at rest and under
load:

```sh
H=../queue-head/out/release M=/tmp/main-release C=src/runtime/tools/check_server_cli.py
tools/client_queue/measure.py server-cli --side head:$H/telar:$H/checkpoint-probe \
  --side main:$M/telar-runtime:$M/checkpoint-probe --check $C --blocks 10 --per-block 20 [--load 20] --out runs/cli
tools/client_queue/measure.py traffic --side head:$H/telar:$H/pane-traffic-probe \
  --side main:$M/telar-runtime:$M/pane-traffic-probe --blocks 10 --per-block 4 --seconds 3 [--load 20] --out runs/traffic
tools/client_queue/analyze.py runs/cli --lanes ../queue-head/src/runtime/transport/connection/connection.cppm \
  ../queue-main/services/runtime-cpp/transport/delivery_lane.hpp --json runs/cli.json
```

`--lanes` names each side's `DeliveryLane` enum: the two trees number their lanes differently (main has no
`shell`, `scrollback`, `panes`, `git`, `blocks` or `document`).

`--load 20` runs 20 `/usr/bin/yes` during the whole measurement and stops them by their exact PIDs. Blocks
alternate the order of the two sides.

## Scenarios

- `server-cli`: `check_server_cli.check_runtime`, the scenario of `server-cli-tests`. Runtime #0 in each run
  is the one `checkpoint-probe seed` stops; the others are stopped by `telar server stop`.
- `traffic`: an interactive client (`pane_traffic_probe.cpp`) opens an 80x24 pane that prints 400 lines
  every 20 ms, reads and acknowledges its frames for `--seconds` and then stops the runtime.

## Trace

`instrument.py` mirrors each `OutgoingFrames` with one entry per queued frame (its size, lane and queue
time), keeps it in byte order through appends, deferred responses resolved in place and partial writes, and
records into a fixed in-memory buffer that `stop()` writes once to `$QUEUE_TRACE_DIR/queue-<pid>.bin`. The
record layout is `trace_api.inc`; `analyze.py` reads it. In `stop()` it snapshots each client's queue
before `RuntimeStopping` is queued (phase 0), after (1) and after the one `write()` (2). Each `publish()`
records how long its phases take before the loop that writes to the clients.

The trace adds work to every queue operation and every `publish()`, the same on both sides: compare the two
builds with each other, never with an uninstrumented one.
