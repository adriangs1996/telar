# telar

A terminal runtime for coding agents, with the UI and UX that match GUIs.

_Telar_ is Spanish for loom, the machine that holds many threads under tension
and weaves them into one surface. A **hilo** is one agent session, which is a
thread of execution and a thread of conversation at the same time. The **trama**
is how they are laid out on screen.

Written in Zig 0.16. Very early.

## Architecture

Telar is split into a long-lived runtime and a disposable client. The source
tree is organized as capability namespaces with explicit process entrypoints.
See the [capability map](docs/capabilities.md), the
[flow index](docs/flows/README.md), and the
[engineering invariants](docs/engineering-invariants.md).

The runtime links system SQLite and libnghttp2. On macOS with Homebrew:

```sh
brew install sqlite libnghttp2
```

Use `zig build -Dnghttp2=/path/to/prefix` when libnghttp2 is installed under a
different prefix.

## Configuration and plugins

Telar uses a versioned Lua configuration with semantic keybindings, bounded
inline callbacks, expression bindings, profiles, atomic reload, and typed
runtime settings. Plugins are content-addressed packages executed in isolated
workers with digest-bound capability grants.

See [docs/configuration.md](docs/configuration.md) and
[docs/plugins.md](docs/plugins.md). The opt-in TLS interception proxy, its
agent-state contract, and its bounded semantic transformation boundary are
documented in [docs/proxy-tls.md](docs/proxy-tls.md). A complete configuration
and plugin package live under [`examples/`](examples/).

The [Neovim adapter](integrations/nvim/README.md) integrates Telar's
navigation-aware `ctrl+h/j/k/l` action with `smart-splits.nvim`.

The [Pi integration](integrations/pi/README.md) reports Pi's own lifecycle
to the runtime through `telar integration install pi`, and `runtime.engine`
keeps a headless Pi alive as Telar's model engine.

## Themes

Vesper is the default client theme. Catppuccin Mocha, Tokyo Night, and a
terminal-palette theme are built in:

```sh
zig build run -- --theme catppuccin
zig build run -- --theme tokyo-night
zig build run -- --theme terminal
```

Themes color Telar's bars, sidebar, selections, and pane borders. Applications
inside panes keep their own terminal colors. `frontend.theme.Overrides` exposes
the color roles that the user configuration will map onto later.

## Kitty graphics

Telar probes the exterior terminal instead of trusting `TERM`. With a compatible
terminal, `automatic` selects the hybrid Kitty sidebar; otherwise the existing
cell renderer remains active:

```sh
zig build run -- --sidebar-renderer automatic
zig build run -- --sidebar-renderer cells
zig build run -- --sidebar-renderer kitty-hybrid
```

Run a graphical child like any other command:

```sh
zig build run -- terminal-browser open https://example.com
```

`kitty-hybrid` fails with a concrete error when the exterior terminal rejects
the KGP query. `kitty-full` is reserved and currently uses the hybrid behavior;
text remains selectable cells. Runtime decoded-image quotas default to 64 MiB
per pane and 256 MiB globally and can be lowered on an explicit server:

```sh
zig build run -- server --graphics-pane-mib 32 --graphics-global-mib 128
```

See [docs/kitty-graphics.md](docs/kitty-graphics.md) for the supported protocol
subset, ownership boundaries, limits, and verified terminal matrix.

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
packages, caches, and vendored sources are excluded from the report. The
historical proxy example under `examples/proxy` is outside the default test
step and therefore outside this report.

Feed the result into `zig-crap` to join line coverage with per-function
complexity:

```sh
zig-crap src --lcov coverage.lcov --lcov-base .
```

## Fuzzing

Telar has development-only AFL++ harnesses for byte-stream boundaries owned by
Telar:

```sh
just fuzz-check
just fuzz schema-client
just fuzz schema-server
just fuzz escape
```

The fuzz package builds instrumented binaries for client IPC schema decoding,
server IPC schema decoding, and history escape scanners. AFL++ output is kept
under `test/fuzz/afl-out/` and ignored. The harness glue is never linked into
Telar's runtime or client binaries. See [`test/fuzz/README.md`](test/fuzz/README.md)
for setup, replay, and target details.

## Performance benchmarks

Run the controlled interactive-path workloads with:

```sh
zig build bench
```

The benchmark target uses `ReleaseFast` when the main build mode is `Debug`.
It measures damage collection, frame encoding and decoding, client application
plus terminal output, native keybinding routing, bounded Lua callbacks, cursor-only output, direct KGP
encoding, the no-damage KGP path, and a 1920×1080 RGBA upload through APC,
base64, zlib, and Ghostty. Cell workloads use a fixed 154×37 screen: a one-cell
patch, a representative fragmented patch with 56 spans of 24 cells, and a full
screen. Client chrome workloads render the real tab model with 1, 8, and 64
tabs. Fixture construction is outside the timed section. Use `--filter`,
`--samples`, or `--sample-ms` after `--` to narrow or lengthen a run:

```sh
zig build bench -- --filter frontend --samples 20 --sample-ms 100
zig build bench -- --filter frontend.client_ui.chrome --samples 20 --sample-ms 100
zig build bench -- --list
```

The pinned terminal-browser exterior check currently requires Ghostty.app on
macOS. It builds the upstream revision, runs it inside Telar, validates KGP and
hybrid-sidebar telemetry, checks response drops and history isolation, then
writes `zig-out/terminal-browser-verification.json`:

```sh
zig build verify-terminal-browser
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
end to end: from a byte written to the host terminal until the echo is
visible, through both processes. `tools/latency_bench.sh` measures that for
one telar binary against an isolated runtime:

```sh
zig build -Doptimize=ReleaseFast --prefix /tmp/telar-candidate
tools/latency_bench.sh /tmp/telar-candidate/bin/telar candidate
```

How the measurement works:

- `tools/echo_latency.py` opens a pty of 160x40 columns, makes the
  multiplexer its session leader with a controlling terminal, and gives it
  `SHELL` pointing at a script that execs `/bin/cat`. The kernel line
  discipline of the pane's pty echoes every byte immediately, so what is timed
  is only the multiplexer: pty read, emulation, IPC, render, host write.
- Each sample writes one token to the pty master and waits until that token
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
- `tools/flood.py` runs `/bin/sh` in the same pty, types
  `seq 1 300000; echo <marker>` and times until the marker is visible. The
  marker is unique per repetition because the previous one is still on screen
  and the diff repaints it when rows scroll. `host_bytes` is what reached the
  host terminal: a multiplexer that folds intermediate frames writes far less.
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
one client, no config, everything else idle. Latencies are p50 / p99:

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

Run-to-run noise on a quiet laptop is about 0.1 ms at p50 and 0.3 ms at p99;
treat smaller differences as no verdict, as `docs/performance-gates.md`
already requires for the microbenchmarks.

The runtime observation proxy and the independent historical example use
separate gates:

```sh
zig build test-backend-proxy
zig build test-proxy-example
```
