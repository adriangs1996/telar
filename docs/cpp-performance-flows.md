# C++ runtime and GUI performance flows

## Objective and continuous execution

Compare the complete C++ stack, GUI plus runtime, with the complete Zig stack.
Adrian requested this on 2026-11-02, with particular emphasis on smooth interaction
at 120 fps when the active display supports and delivers 120 Hz. Preserve functional
and visual behavior, explicit allocator ownership, compile-time dependency selection
and the application/native-platform boundary.

Measurement and optimization are one continuous task. Define and qualify the flows,
provision a fresh Personal checkout, establish current baselines, then optimize every
flow as far as evidence supports. Adrian explicitly removed the initial-phase stop
and per-flow approval gate: proceed autonomously through the whole matrix. The goal
is a complete C++ stack faster than the complete Zig stack in every flow, with smooth
native 120 Hz interaction where supported. A baseline report or a subset of wins is
progress, not completion. Preserve the measurement contract throughout iteration.

Historical lessons are in [GUI optimization](../services/gui-cpp/OPTIMIZATION.md)
and [runtime performance](../services/runtime-cpp/performance.md). They identify
previously attempted paths, rather than current performance or reusable environments.
The previous Personal checkout, VM and generated artifacts were removed.

## Flows

The variants below are workload definitions to qualify, not claims of existing
benchmark coverage. The agent must map each one to existing source tools, specify
missing support, and record exact dataset sizes, rates and iteration counts before
timing. A failed or unavailable case remains visible in the baseline report.

| ID | Flow and controlled variants | Primary measurements and oracle |
| --- | --- | --- |
| F01 | Cold startup; attach to an owned running runtime with saved tabs/panes | Launch to first qualified presented content; restored layout/content and surviving child processes |
| F02 | Idle with an empty terminal, populated tabs and background agents; visible, hidden and disconnected GUI | GUI/runtime CPU, wakeups and settled memory; no unnecessary rendering while idle; runtime state survives GUI exit |
| F03 | Interactive typing, cursor movement and bounded paste; ASCII, Unicode and combining sequences | Native input to qualified presented pixels, p50/p95/p99; exact bytes/cells, input ordering and selection behavior |
| F04 | Sustained ASCII/ANSI/Unicode output; unconstrained throughput and a separate fixed-rate background load | Validated bytes/s, input latency under load, CPU and allocations; exact final grid/transcript, unchanged offered-rate gate |
| F05 | Full-screen TUI trace with partial edits, colors, alternate screen and cursor updates | Presented frame cadence, input latency and damage work; deterministic final cells and representative visual checks |
| F06 | Continuous scroll through populated scrollback, selection and return to live output | Presented frame intervals, missed refreshes and stalls; correct visible lines, selection and scroll position |
| F07 | Four splits, one producer active and all producers active, including fixed-rate load | Foreground latency/cadence, fairness, CPU and memory; all pane geometries and per-producer receipts match |
| F08 | Switch among four tabs and among workspaces while hidden panes continue producing output | Action to first correct presented target, frame pacing and hidden-work cost; no stale pane/frame or lost output |
| F09 | Continuous window resize and split-divider movement; matched opaque and blur-enabled appearance | Frame pacing, main/render-thread work, GPU work and resize latency; correct grid/layout, clipping and background effects |
| F10 | Kitty images at 1024² and 3840×2160, first display, replacement, scroll and hide/show recovery | Image-pixel presentation latency, concurrent UI cadence, upload/transport CPU and memory; actual dimensions, alpha/colors, budgets and generations |
| F11 | Native image paste, attachment shelf, open/close preview and bounded multiple attachments | Action to actual image/modal presentation, encode/decode cost and settled memory; source limits, cancellation and clipboard preservation |
| F12 | Populate command history, filter/search, inspect an entry and scroll results; cold/warm queries | Runtime query latency and query-to-presented-results latency, cancellation and memory; exact results/order and stale-response rejection |
| F13 | Agent reports, task/plan/activity changes and sidebar updates while terminals stream | Report to visible status, UI cadence, hook/service cost and idle cost; correct identities, state transitions and bounded queues |
| F14 | Configured bars/panels/picks, plugin worker activity, Lua reload and path/suggestion queries | Interaction/query to visible result, worker/startup CPU and memory; same configured behavior, highlights and reload semantics |
| F15 | Owned SSH transport, reconnect and backlog recovery, with explicitly controlled delay/backpressure | Input/presentation latency, reconnect to current frame and queue bounds; correct process continuity, terminal state and generations |
| F16 | Runtime proxy/traffic services under terminal interaction: opaque relay, CONNECT, HTTP/1 and HTTP/2 where comparable | Service latency/throughput, GUI pacing, CPU and queue/memory pressure; byte/protocol/capture oracles and identical enabled features |

For F10, declare image arrival rate separately from the interactive refresh target.
For F12–F16, identify unsupported combinations explicitly; functional differences
must not be hidden by dropping work from one stack. Synthetic agent/network fixtures
must be deterministic and avoid paid provider requests or unrelated remote machines.
Include PTY/control-query component probes where needed to explain a full-flow cost;
their round-trip timings do not establish visible GUI latency.

## Smoothness at high refresh rates

Identify the display actually presenting the candidate window, its current refresh
mode and its variable-refresh behavior. A reported maximum alone does not prove a
120 Hz run. Record the measured presentation cadence and VSync policy per run.

At 120 Hz the refresh period is 8.33 ms. For continuous-motion variants of F05–F10
and F13–F14, report presented frame-interval p50/p95/p99, refresh opportunities
missed, longest stall, and active-frame CPU/GPU time. Use repeated representative
motion sequences long enough to expose stalls, with a declared warmup. Report
interaction latency separately; a refresh period is not an input-latency deadline.

Qualify timestamp resolution, callback ordering and missed-refresh classification
before choosing numerical jitter tolerances. Freeze those tolerances before timing.
Sustained 60 fps on a verified 120 Hz display fails the smoothness goal for these
continuous-motion workloads. Idle windows remain event-driven. If the active
hardware/mode cannot supply 120 Hz, report the supported rate and leave 120 Hz
acceptance unverified; VM/software rendering cannot certify it.

## Comparison and validity

The primary pairs are C++ GUI + C++ runtime versus Zig GUI + Zig runtime, from
identified current source revisions and new Release builds. Record both executable
hashes and verify which process actually owns each socket. Plugin helpers, discovery
and child processes must not silently select the other runtime through PATH or an
installed app. Document any retained helper-language dependency separately.

Use mixed GUI/runtime pairings only as diagnostics if the wire schemas support
them. Label all four combinations; a faster GUI connected to the other runtime is
not proof that the requested complete C++ stack wins.

Match configuration, fonts, grid/viewport, native platform effects, dataset and
offered work. Fix producer rates independently of the consumer's speed. Use
alternated pairs on the same host without concurrent builds, tests or profiling.
Start with six valid pairs per full-client case and seven for runtime/component
cases that already use the seven-pair contract. Increase sampling only for a
stated uncertainty, retaining every invalid run and the reason it failed.

On a shared host, inspect `uptime` before each series and record load/processes
before and after each variant. Discard or repeat the entire series when elevated
load or concurrent compilation is observed; do not select its quiet-looking pairs
afterward. Leave unrelated agents, worktrees and processes alone.

The `tools/gui_tui_latency.py` CLI enforces these boundary checks through
`tools/benchmark_host.py`. Its default one/five-minute load limits are
`max(2, logical CPUs / 2)` and `max(3, logical CPUs * 3 / 4)`; `--max-load ONE FIVE`
sets explicit finite positive limits before the series. Active compiler processes
above 10% CPU also reject a checkpoint. `host-load.json` preserves the policy,
`uptime`, process snapshots and rejection. A rejected series exits with status 2,
retains raw observations and does not publish `comparison.json`. Missing host
observations fail closed. The observer is included in the frozen source manifest.
Custom drivers calling `measure()` directly must use `HostLoadGate.run()` around
each invocation and `finish()` before computing an aggregate. Boundary snapshots
cannot exclude every transient interference and do not replace workload, focus,
geometry or presentation qualification.

Visible endpoints require qualified initial readiness and verified content on the
drawable with a positive native presentation timestamp. An acknowledgement, texture
submission or GPU-completion timestamp is a separate endpoint. Qualify negative
controls for stale/zero/missing presentation, focus, VSync, geometry and actual
image dimensions. Keep the existing 5% offered-rate tolerance for fixed-load cases.

Record latency distributions, throughput where relevant, GUI/runtime CPU separately,
settled/peak memory with observation windows, queue growth and allocation counts
where available. Allocation instrumentation and profilers run separately from
headline timing. Avoid summing shared RSS; obtain actual clock/timebase units and
validate native resource counters.

For Darwin runtime counters without adding queries inside the GUI input phase,
build `tools/macos_process_resources.c` with `clang -O2` into an ignored scratch
directory. Programmatic callers can wrap native `measure()` with
`native_runtime_resources.capture(harness, receipt_path, helper_path)`.
This serial adapter samples the socket-verified runtime before GUI launch and
after GUI exit, then preserves the harness's owned-runtime cleanup. The window
includes GUI startup, warmup and boundary-observer time, excludes runtime startup/shutdown and child CPU,
and differs from the GUI measured-input interval. It must be reported separately.
The helper records the Mach timebase, process start time, executable UUID and
clock brackets. Memory values are boundary snapshots and a lifetime footprint
maximum, not an interval peak. This optional adapter is not enabled by the CLI.

For diagnostic GUI CPU attribution on native macOS, use
`python3 tools/build_thread_cpu_probe.py OUT` to build an isolated tab-switch
probe. It adds measured-interval hooks and a 100 ms in-process observer from
`tools/macos_thread_cpu.c`; the ordinary probe and production GUI are unchanged.
`python3 tools/thread_cpu_report.py CAPTURE --output REPORT` validates the resulting
`thread-cpu.jsonl`. The report retains signed process/thread accounting residuals:
new threads contribute their observed lifetime CPU, retired threads can have an
unobserved tail, and completely unseen threads remain unattributed. Names do not
prove a thread's current dispatch queue. Counter units are seconds/microseconds
from Mach `THREAD_BASIC_INFO` and `getrusage`, not raw Mach ticks. These observed
CPU totals include probe work; their timings never count toward acceptance.

Before using that observer on a new host, compile `tools/macos_thread_cpu.c` and
`tools/macos_thread_cpu_control.c` together with `clang -O2 -pthread`. Run the
control with a new capture path, retain its stdout JSON, then pass that JSON as
`--control RECEIPT` to `thread_cpu_report.py`. This checks known busy/sleep CPU
and the residual from short-lived threads. Missing or failed thread reads reject
the capture. Synthetic negative controls are in `test_thread_cpu_report.py`.

## ASCII TUI interaction diagnostic

Build an isolated copy of the native harness with
`python3 tools/build_tui_bench_probe.py out-perf/tui/probe`. Its
`gui_tui_latency.py` accepts the ordinary explicit Zig binary, `--cpp-gui`,
`--cpp-runtime`, `--config`, `--source`, viewport and host-load arguments; use
`--mode telar --cases tui --endpoint presented`. The default remains three
rounds, so explicitly request at least `--rounds 6` for paired timing. For a
separate PNG qualification use `--capture --idle-seconds 0.2`; a zero idle interval
cannot wait for capture completion.

The fixture changes full and partial ASCII rows, colors, bold styles, cursor and
alternate-screen state before each native marker. Final runtime screen text is
verified before owned cleanup; corrupt/stale results fail and cannot enter the
shared report. This check does not verify every intermediate drawable's body,
cell styles or continuous native120 cadence. The fixture's producer generation
and receipt I/O are included in the end-to-end workload. The final-screen query
is outside GUI measured-input CPU, but occurs before the ordinary runtime
resource adapter's stop-boundary snapshot; report that wider runtime scope.
Current visual differences and diagnostic qualification are in the progress
report. They must not be hidden by treating the marker alone as full F05 parity.

For a producer-boundary control, build a separate harness with
`python3 tools/build_tui_bench_probe.py out-perf/tui/coalesced --write-mode coalesced`.
It combines the same body, marker and cursor bytes into one `write_all` call per
draw. Short writes and separate PTY reads remain possible. Receipts explicitly
label this diagnostic; the shared timing report rejects it for ordinary workload
acceptance. The default `split` mode preserves the original producer behavior.
Run `tools/test_tui_coalesced_fixture.py` to check byte-stream equivalence across
input, capture, resize and short-write cases before using the control.

The private render-work census (`tools/build_render_work_probe.py OUT`) also
exports commit counts by input epoch. Use
`render_work_report.analyze_sequences(census, warmup, measured_samples)` to
validate the partition and retain boundary work separately. This attributes the
epoch observed at commit entry, including inter-input work; it does not prove
frame content, causality or display cadence. Compile and run
`tools/render_sequence_control.c` with `tools/render_work_census.c` before using
the extended counter on a new host. Keep all instrumented timings diagnostic.

## Deliverables and later optimization

Fresh setup, coverage gaps and current experiments are tracked in
[cpp-performance-progress.md](cpp-performance-progress.md).

Maintain a per-flow map of reusable source tools, missing harness/oracles, qualified
build identities/display mode, current baseline and accepted/rejected optimizations.
Reusable measurement support belongs in source; raw results and captures stay in
ignored outputs. Keep a concise table of valid cases, failures and unsupported cases.

For native cadence receipts, [native_cadence_report.py](../tools/native_cadence_report.py)
validates content/producer coverage before applying the fixed-clock checks in
[native_display_reference.py](../tools/native_display_reference.py). Run it with
the native result and producer JSON paths; `--output` writes the report. A qualified
clock and interval classification do not imply sustained 120 content FPS: inspect
the content rate and missing refresh opportunities as well. The matching
[producer completion helper](../tools/native_cadence_completion.py) waits for a
checkpoint covering the native observation before an owned runtime is stopped.
It does not relax producer-rate or presentation criteria. Unit tests are
`test_native_cadence_report`, `test_native_display_reference` and
`test_native_cadence_completion` in `tools`.

For each flow, profile first, prove functional/visual
equivalence, then compare the variant against both the preceding accepted C++ build
and Zig. Follow [perf-pass](../.agents/skills/perf-pass/SKILL.md) pair-win rules.
Faster median performance alone does not close the objective while tail latency,
frame pacing, resources or another flow consistently regress. Claim complete
performance acceptance only for the whole measured matrix, naming limitations.

The initial measurement order is F03/F06/F08/F09 for interaction and smoothness,
then F04/F07/F10/F11 for load and images, F01/F02 for lifecycle and idle,
and F05/F12–F16 for the remaining daily/runtime flows. Iterate across all flows,
rechecking the complete matrix after accepted changes. Continue past measurement
and partial improvements until every flow satisfies the objective; actual unresolved
regressions or unavailable native validation remain open findings.
