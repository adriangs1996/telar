# telar

A terminal runtime for coding agents, with the UI and UX that match GUIs.

_Telar_ is Spanish for loom, the machine that holds many threads under tension
and weaves them into one surface. A **hilo** is one agent session, which is a
thread of execution and a thread of conversation at the same time. The **trama**
is how they are laid out on screen.

Written in Zig 0.16. Very early.

## Architecture

Telar is split into a long-lived runtime and a disposable client. Each process
keeps its state in one flat model and dispatches every message through one
`update`. See the [architecture](docs/architecture.md), the
[flow index](docs/flows/README.md), and the
[invariants](docs/invariants.md).

The runtime links system SQLite, libnghttp2 and Brotli. On macOS with Homebrew:

```sh
brew install sqlite libnghttp2 brotli
```

Building the native GUI also requires Rust/Cargo 1.93.1 or newer for its
[Mermaid renderer](tools/diagram-renderer/README.md). `zig build` installs the
compiled helper beside Telar; running an installed build does not require Cargo.

On Arch Linux or Arch Linux ARM, install the libraries and libc development
headers before building with Zig 0.16.0:

```sh
sudo pacman -Syu --needed base-devel sqlite libnghttp2 brotli \
  wayland wayland-protocols libxkbcommon vulkan-headers vulkan-icd-loader shaderc \
  fontconfig ttf-dejavu at-spi2-core glib2
zig build
zig build test
```

Filesystem metadata calls import the target's `sys/stat.h` declarations so
Linux and macOS use their own libc ABI. No Linux-specific source patch is
needed. `zig build cross` also compiles the local transport tests for Linux
x86_64 and aarch64, without running those foreign binaries.

Use `zig build -Dnghttp2=/path/to/prefix` when libnghttp2 is installed under a
different prefix.

## Remote runtime

Run the client on your machine and keep the runtime and child processes on an
SSH host. Install matching Telar builds on both machines, then verify that SSH
can find the remote binary without an interactive shell:

```sh
ssh dev@box 'command -v telar; telar --version'
./zig-out/bin/telar --no-config --remote dev@box
```

The window discovers the remote home and shell and forwards the runtime's Unix
socket over SSH, and reconnects by itself when the link drops. Closing the
window leaves the remote processes running; the same command reattaches. No
Telar TCP listener is exposed. See [remote attach](docs/flows/remote-attach.md)
for requirements and ownership.

Machines you use often can be saved and kept in every window:

```sh
telar machine add box dev@box --check
telar --machine box pane list          # run a telar command on box
telar gui --machine box                # a window that shows box first
```

See [machine profiles](docs/flows/machine-profiles.md),
[machine dispatch](docs/flows/machine-dispatch.md) and
[machine presentation](docs/flows/machine-presentation.md).

## Configuration and plugins

Telar uses a versioned Lua configuration with semantic keybindings, bounded
inline callbacks, expression bindings, profiles, atomic reload, and typed
runtime settings. Plugins are content-addressed packages executed in isolated
workers with digest-bound capability grants.

See [docs/configuration.md](docs/configuration.md) and
[docs/plugins.md](docs/plugins.md). Application bundles, the Linux desktop
entry and the `telar cli` PATH link are described in
[docs/packaging.md](docs/packaging.md). The opt-in TLS interception proxy, its
shared secret and its exchange capture are documented in
[docs/proxy-tls.md](docs/proxy-tls.md). A complete configuration
and plugin package live under [`examples/`](examples/): `config.lua` and
`plugins/`.

The [Neovim adapter](integrations/nvim/README.md) integrates Telar's
navigation-aware `ctrl+h/j/k/l` action with `smart-splits.nvim`.

The [Pi integration](integrations/pi/README.md) reports Pi's own lifecycle
to the runtime through `telar integration install pi`, and `runtime.engine`
keeps a headless Pi alive as Telar's model engine.

## Themes

Set `theme = "shade"` once in Lua for Telar's interface and native
terminal. Shade is the default. Vesper, Catppuccin Mocha, Tokyo Night, and
a terminal-palette theme are also built in:

```sh
zig build run -- --theme vesper
zig build run -- --theme catppuccin
zig build run -- --theme tokyo-night
zig build run -- --theme terminal
```

Themes color Telar's bars, sidebar, selections, and pane borders. The GUI also
uses the preset's terminal foreground, background, ANSI palette and cursor
colors. Customize either part with
`theme.colors` and `theme.terminal`; [Lua configuration](docs/configuration.md#theme)
documents overrides, profiles and hot reload.

## Kitty graphics

The runtime terminates Kitty graphics commands at each pane and sends the
images to the window, which keeps a bounded replica but does not draw them yet.
Run a graphical child like any other command:

```sh
zig build run -- terminal-browser open https://example.com
```

Runtime decoded-image quotas default to 256 MiB per pane and 512 MiB globally
and can be lowered on an explicit server:

```sh
zig build run -- server --graphics-pane-mib 32 --graphics-global-mib 128
```

See [docs/kitty-graphics.md](docs/kitty-graphics.md) for the supported protocol
subset, ownership boundaries, limits, and verification.

## Development diagnostics

Debug builds emit one JSON Lines sample per second without writing terminal or
PTY contents. Logs live beside the local runtime socket:

```text
<socket>.runtime-<pid>.log
<socket>.client-<pid>.log
```

Runtime samples cover PTY throughput, folded updates, frame size, damaged rows,
diff scans, no-op frames, VT ingestion, frame encoding, and acknowledgement
latency. Client samples separate cell `flush_*` from `media_flush_*`, attribute
KGP wire bytes to panes, toasts, and the sidebar, and report retained bytes for
the Kitty store, toast textures, sidebar atlas, screen buffers, Lua VM, and
instrumented heap. File writes run outside the interactive loop. Release builds
neither create these files nor schedule the telemetry actors.

Runtime heap samples keep the aggregate `interactive_alloc*` counters and split
them into `interactive_vt_alloc*` for terminal-emulator state growth and
`interactive_telar_alloc*` for allocations owned by Telar's event path. Proxy
rejections likewise distinguish missing or malformed authorization from an
otherwise valid credential that is no longer registered, without logging
either value.

## Test coverage

Telar uses [zcov](https://github.com/ericsssan/zcov) to run the native test
suites with SanitizerCoverage and write an LCOV tracefile:

```sh
just coverage
```

`zig-cov` and its adjacent `zig-cov-rt.o` must be installed together. Set
`ZIG_COV_BIN` when the executable is not on `PATH`, or
`TELAR_COVERAGE_FILE` to change the default `coverage.lcov` destination:

```sh
ZIG_COV_BIN=/path/to/zig-cov just coverage
```

The coverage build forces LLVM and libc only for native test executables. It
instruments Telar's Zig-only shared modules and suite roots, while leaving
C-family dependencies and cross-target compile checks alone. Generated
packages, caches, and vendored sources are excluded from the report.

Feed the result into `zig-crap` to join line coverage with per-function
complexity:

```sh
zig-crap src --lcov coverage.lcov --lcov-base .
```

## Fuzzing

Telar fuzzes one boundary so far: `decodeClientHello`, the first message a
runtime decodes from a connecting client. It uses Zig's built-in fuzzer
(`std.testing.fuzz`) and needs no other tools. The target lives in
[`src/core/schema/handshake_fuzz_test.zig`](src/core/schema/handshake_fuzz_test.zig)
and runs only through the `test-handshake` step. Client and server IPC
decoding and the history escape scanners have no fuzz target yet.

Run the handshake tests and replay the seed corpus, without fuzzing:

```sh
just fuzz-check   # zig build test-handshake
```

Fuzz for a bounded number of runs; the argument takes Zig's `K`, `M` and `G`
suffixes:

```sh
just fuzz         # zig build test-handshake --fuzz=10K
just fuzz 1M
```

The run ends with a report of runs, unique runs and covered program counters.
The coverage counts the whole test executable, including Zig's test runner,
not only the decoder. `zig build test-handshake --fuzz` without a limit keeps
fuzzing and serves Zig's web interface; this mode has not been tried on Telar.

With Zig 0.16.0, a failure found while fuzzing does not change the exit status
of `zig build`, so read the output instead of trusting it. A failing input is
reported as `input saved to '.zig-cache/f/crash'`. That file holds the input
in the form the fuzz test reads it, so to reproduce the failure copy it next
to the fuzz test and add `@embedFile` of it to the test's corpus; a plain
`zig build test-handshake` then replays it.

Zig 0.16.0 constrains how the target is built: its test runner does not
compile a fuzz test in Debug with error return traces, so the fuzz executable
is built without them (runtime safety stays on), and a broken property panics
rather than returning an error, because only an abort keeps the saved input.

## Performance benchmarks

Run the controlled interactive-path workloads with:

```sh
zig build bench
```

The benchmark target uses `ReleaseFast` when the main build mode is `Debug`.
It measures damage collection, frame encoding and decoding, keybinding routing,
bounded Lua callbacks, client events, KGP ingest and shared frames, text
rasterization and blitting. Cell workloads use a fixed 154×37 screen: a one-cell
patch, a representative fragmented patch with 56 spans of 24 cells, and a full
screen. Fixture construction is outside the timed section. Use `--filter`,
`--samples`, or `--sample-ms` after `--` to narrow or lengthen a run:

```sh
zig build bench -- --filter frontend.client --samples 20 --sample-ms 100
zig build bench -- --filter client.keybind --samples 20 --sample-ms 100
zig build bench -- --list
```

Save JSON Lines before and after a change, then compare median time and payload
bytes per operation. The comparison rejects runs built with different Zig
versions, optimization modes, CPUs, targets, screen sizes, sample counts or
sample durations.

```sh
zig build bench -- --json > /tmp/telar-before.jsonl
# Make the optimization.
zig build bench -- --json > /tmp/telar-after.jsonl
python3 tools/bench_compare.py /tmp/telar-before.jsonl /tmp/telar-after.jsonl
```

`--fail-above 5` gives the comparison command a nonzero exit status when any
median regresses by more than five percent. `--fail-payload-above 0` also
rejects any wire payload growth. Keep benchmark result files outside the
repository because absolute timings belong to the machine that produced them.

Architecture changes use five repeated runs of 200 samples. `perf_gate.py`
compares the median p50, p95 and p99 across those runs, rejects regressions over
5%, 8% and 10% respectively, rejects wire-payload changes, and emits no verdict
when either group is noisier than those bounds:

```sh
python3 tools/perf_gate.py \
  --baseline '/tmp/telar-before-*.jsonl' \
  --candidate '/tmp/telar-after-*.jsonl'
```

CI cadence and release-candidate requirements are recorded in
[`docs/performance-gates.md`](docs/performance-gates.md).

### End-to-end latency against tmux and herdr

The microbenchmarks above time telar's own code. The numbers a user feels are
end to end, through both processes. `tools/latency_bench.sh` measures them for
one telar binary against an isolated runtime, through its headless client
(`zig build headless`):

```sh
zig build -Doptimize=ReleaseFast --prefix /tmp/telar-candidate
tools/latency_bench.sh /tmp/telar-candidate/bin/telar candidate
```

How the measurement works:

- `tools/echo_latency.py` gives the multiplexer `SHELL` pointing at a script
  that execs `/bin/cat`. The kernel line discipline of the pane's pty echoes
  every byte immediately, so what is timed is only the multiplexer.
- telar runs as `telar-headless`. Each sample sends one token as an input
  line, and the latency runs from the client taking the line to the first
  frame of that pane the client presents, read from its exit trace
  ([headless client](docs/flows/headless-client.md#reports)). It ends where
  the client has the frame, not where a window or host terminal shows it.
- Comparators run in a pty of 160x40 columns as its session leader. Each
  sample writes one token to the pty master and waits until that token
  is visible in the multiplexer's output. Escape sequences (CSI, OSC, DCS) are
  stripped before matching, so a cursor move between two painted frames does
  not hide the token. Tokens are letters that never appear as final bytes of a
  control sequence.
- Two token sizes matter. One byte measures the single-frame path. Two bytes
  usually reach the child as two writes, which the runtime turns into two
  frames: the second frame waits for the first frame's acknowledgement, which
  the client only sends after painting. Any real keystroke in a shell that
  redraws its prompt behaves like the two-byte case.
- Samples: 200 per case, 50 ms apart, after a warm-up. The script reports
  p50, p95, p99, min, max and mean in microseconds.
- `tools/flood.py` runs `/bin/sh`, types `seq 1 300000; echo <marker>` and
  times until the marker is visible. The marker is unique per repetition
  because the previous one is still on screen and the diff repaints it when
  rows scroll. For telar the time runs from the client taking Enter to the
  last frame it presented for that pane. For comparators, `host_bytes` is what
  reached the host terminal: a multiplexer that folds intermediate frames
  writes far less.
- Isolation is mandatory. A telar runtime reads and writes the session
  checkpoint and `history.db` under `XDG_DATA_HOME`, and connects to the
  socket under `TELAR_SOCKET_PATH`. The script sets all three to fresh
  directories per pass, and unsets every inherited `TELAR_*` variable, so a
  shell running inside telar can measure without touching the live runtime,
  and a restored session cannot steal focus from the launched pane. The unix
  socket path must stay under 104 bytes.
- Comparators run through the same two scripts. tmux:
  `tmux -L bench -f /dev/null new-session`, herdr: `herdr --session bench`
  with `HOME` and `XDG_CONFIG_HOME` pointing at a short empty directory.

Results on 2026-09-03, Apple Silicon macOS 26.6, Zig 0.16.0, ReleaseFast,
one client, no config, everything else idle. Latencies are p50 / p99. They
predate the headless client: telar was measured the way the comparators are,
through its retired terminal client in a pty, up to the host write.

| Multiplexer | 1 byte | 2 bytes | Flood, 300k lines |
| --- | --- | --- | --- |
| telar, before the pacer change | 0.49 ms / 1.01 ms | 22.3 ms / 26.0 ms | 233 ms |
| telar, after (pacer burst credit, inline draw, socket read-ahead) | 0.51 ms / 0.91 ms | 0.64 ms / 1.38 ms | 242 - 261 ms |
| tmux 3.7c | 0.24 ms / 0.48 ms | 0.25 ms / 0.38 ms | 220 - 226 ms |
| herdr 0.8.2, default config | 2.91 ms / 5.29 ms | 2.91 ms / 5.41 ms | 234 - 252 ms |
| herdr 0.7.5, a real user config | 3.11 ms / 10.9 ms | 3.16 ms / 15.9 ms | marker not shown within 60 s |

Reading the table: the two-byte column is where telar used to lose two orders
of magnitude, because the second frame of an interaction waited a whole 60 Hz
pacer interval plus a late timer wakeup. With burst credit and inline
presentation it sits within the run-to-run noise of the one-byte case. The
remaining gap to tmux is structural: `std.Io.Threaded` pays one thread
handoff per read, ingest and send, across two processes, where tmux runs one
kqueue loop. Bare pty echo without any multiplexer measures about 15 us on the
same machine, which is the floor for every row.

#### Echo latency under load

`tools/load_bench.sh <binary> <label>` runs `tools/load_latency.py`: it opens
`FLOODS` extra panes (default `0 1 2 4 8`), each running `while :; do seq 1
100000; done`, then measures single-byte echo latency in one idle pane. telar
panes are opened by sending the default `ctrl+b %` and `ctrl+b "` bindings to
its headless client; tmux panes with `split-window -d` plus `select-layout tiled`. Each token is
erased with backspace after it is seen, because a later repaint of the input
line would otherwise match the next token early. A runtime whose panes are
still flooding does not finish `telar server stop`; the script kills it by
socket after five seconds.

Results on 2026-09-03, same machine as above but with a browser and a
build-on-save watcher active (load average 4-6), p50 / p99, also through the
retired terminal client:

| Flooding panes | telar before input grace | telar with input grace | tmux 3.7c |
| --- | --- | --- | --- |
| 0 | 0.41 ms / 27.9 ms | 0.87 ms / 1.62 ms | 0.49 ms / 1.07 ms |
| 2 | 15.1 ms / 20.6 ms | 0.56 ms / 1.21 ms | 0.64 ms / 0.87 ms |
| 4 | 14.6 ms / 21.1 ms | 1.02 ms / 2.36 ms | 1.11 ms / 1.45 ms |
| 8 | 15.7 ms / 21.2 ms | 1.69 ms / 5.48 ms | 2.36 ms / 7.25 ms |

Before the change telar sat on the 60 Hz pacer interval whatever the load:
the flood spent the burst credit and the keystroke's echo waited for the next
cadence slot. A control build with the interval forced to 1 ms measured
2.1 ms / 9.7 ms at four panes, which bounded what any scheduling change could
buy and ruled out a kqueue-based event loop as the next step. The input
grace window recovers most of that bound: after every host read, up to
`pace.default_input_frames` frames present immediately even while a paced
draw task is armed. tmux's own behaviour under flood is bimodal; the same
harness measured 48-50 ms medians at two and four panes in an earlier
session. The 0-pane rows and every p99 in this table carry the noise of the
busy host; idle rows measured 0.36-0.70 ms for both builds when alternated.

Run-to-run noise on a quiet laptop is about 0.1 ms at p50 and 0.3 ms at p99;
treat smaller differences as no verdict, as `docs/performance-gates.md`
already requires for the microbenchmarks.

The runtime proxy has its own gate:

```sh
zig build test-backend-proxy
```
