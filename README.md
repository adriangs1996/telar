# telar

A terminal runtime for coding agents, with the UI and UX that match GUIs.

_Telar_ is Spanish for loom, the machine that holds many threads under tension
and weaves them into one surface. A **hilo** is one agent session, which is a
thread of execution and a thread of conversation at the same time. The **trama**
is how they are laid out on screen.

Written in Zig 0.16. Very early.

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
latency. Client samples cover input and server throughput, applied, scanned and
painted cells, frame pacing, protocol work, and terminal flush latency. File
writes run outside the interactive loop. Release builds neither create these
files nor schedule the telemetry actors.

## Performance benchmarks

Run the controlled interactive-path workloads with:

```sh
zig build bench
```

The benchmark target uses `ReleaseFast` when the main build mode is `Debug`.
It measures damage collection, frame encoding and decoding, client application
plus terminal output, keybinding routing, cursor-only output, direct KGP
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
versions, optimization modes, CPUs, targets, or screen sizes.

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
