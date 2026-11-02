# C++ runtime and GUI performance flows

## Objective and current phase

Compare the complete C++ stack, GUI plus runtime, with the complete Zig stack.
Adrian requested this on 2026-11-02, with particular emphasis on smooth interaction
at 120 fps when the active display supports and delivers 120 Hz. Preserve functional
and visual behavior, explicit allocator ownership, compile-time dependency selection
and the application/native-platform boundary.

The first phase defines and qualifies these flows, provisions a fresh Personal
checkout, and establishes current baselines. Production optimization starts after
Adrian selects a flow. Infrastructure needed to measure a flow belongs to this
phase; speculative production tuning does not.

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

## Deliverables and later optimization

Phase one produces a per-flow map of reusable source tools, missing harness/oracles,
qualified build identities/display mode and measured baseline status. Reusable
measurement support belongs in source; raw results and captures stay in ignored
outputs. Keep a concise table of valid cases, failures and unsupported cases.

For each subsequently selected flow, profile first, prove functional/visual
equivalence, then compare the variant against both the preceding accepted C++ build
and Zig. Follow [perf-pass](../.agents/skills/perf-pass/SKILL.md) pair-win rules.
Faster median performance alone does not close the objective while tail latency,
frame pacing, resources or another flow consistently regress. Claim complete
performance acceptance only for the whole measured matrix, naming limitations.

The initial measurement order is F03/F06/F08/F09 for interaction and smoothness,
then F04/F07/F10/F11 for load and images, F01/F02 for lifecycle and idle,
and F05/F12–F16 for the remaining daily/runtime flows. This is a measurement order,
not authorization to start optimizing any flow without Adrian's next instruction.
