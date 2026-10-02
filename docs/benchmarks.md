# Performance benchmarks

Run these commands from the repository root. The September 2026 comparison
tables below describe the retired terminal client, not the current native GUI.
See [performance gates](performance-gates.md) for the validation policy and
[performance investigations](performance/) for later measurements.

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
[`docs/performance-gates.md`](performance-gates.md).

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
  ([headless client](flows/headless-client.md#reports)). It ends where
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
