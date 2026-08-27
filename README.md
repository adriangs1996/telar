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

The runtime observation proxy and the independent historical example use
separate gates:

```sh
zig build test-backend-proxy
zig build test-proxy-example
```
