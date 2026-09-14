# Step 9: client inbox/outbox

Implemented and measured on 2026-09-13, Apple M3, macOS 26.6.2, Zig 0.16.0.
The baseline is `d97cfb7681d0728d337e16768292f5a613dabbee`; the candidate is the
final step 9 working tree. [metadata.json](metadata.json) records executable
hashes and build flags. Linux correctness checks use the repository's Fedora 43
aarch64 VM.

## Implementation and decision

TUI, GUI and the headless test driver consume the same bounded inbox. Its 64
slots include both ready messages and producer reservations. Workers reserve
completion storage before starting through `std.Io.Group`. A turn handles at
most 32 messages or 1 ms, always finishing its current handler, then observes
the latest committed state for presentation.

The existing outbox, independent rearmed RX/TX operations, transport buffers,
typed host ports and resource owners remain. RX validates on its worker and
owns one decoded result beside its wire buffer; the inbox borrows that result
until dispatch finishes. Native input and GPU completions enter the inbox.
`NativeLoop` replaces the provisional `RuntimeDriver`. Shutdown closes admission,
joins producers, then frees their resources. ACK still confirms received model
state; GPU completion retires captured presentation damage.

The local decision is to keep the migration. It preserves the observed latency
range, makes admission and lifetime explicit, and passes the three host suites.
It costs about 178 KiB of additional fixed TUI heap storage. That cost and the
sampled RSS increases below are part of the result, not hidden by latency
medians. See [Client event dispatch](../../flows/client-event-dispatch.md) for
ownership, saturation, wake and shutdown contracts.

## Native key dispatch to verified GPU completion

| Host | Build | n | p50 ms | p95 ms | p99 ms | Maximum ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| GUI | Before | 500 | 3.847 | 5.590 | 17.718 | 28.187 |
| GUI | After | 500 | 3.856 | 5.574 | 6.888 | 22.029 |
| TUI in Ghostty | Before | 200 | 7.899 | 13.101 | 13.451 | 13.930 |
| TUI in Ghostty | After | 200 | 8.306 | 12.809 | 13.721 | 14.731 |

The final GUI median differs by +0.009 ms and p95 by -0.016 ms. TUI median
increases by 0.407 ms (+5.1%), p95 decreases by 0.292 ms, and p99 increases by
0.269 ms. These mixed changes and run-to-run variability do not establish a
general speedup. In particular, the lower GUI p99 reflects fewer isolated
stalls in this sample, not a guarantee against future stalls.

Raw responses, per-run statistics, geometry and GPU work durations are in
[gpu-before.json](gpu-before.json) and [gpu-after.json](gpu-after.json).
Both hosts have 100 measured responses after 20 warmup responses per run,
with the probe's varying 25–74 ms pause. Each version contributes five GUI runs
and two TUI runs. The baseline's first two rounds alternate GUI/TUI and TUI/GUI;
three extra GUI baseline runs were collected during the investigation. The
final candidate was measured afterwards, in order GUI/TUI, TUI/GUI, then three
GUI runs. Final versions are therefore not interleaved; temporal host variation
remains a limitation.

Every compared target is 1760 × 2166 physical pixels, with JetBrains Mono at
nominal size 15. GUI pane geometry is 97 × 54 cells; TUI is 97 × 52 because its
two chrome rows remain. Ghostty is 1.3.1, with VSync enabled. Both Telar versions
use ReleaseFast with echo tracing enabled and diagnostics disabled. Each run
uses an isolated runtime, a minimal configuration and the one-cell marker
workload from `tools/gui_tui_latency.py`.

The clock starts immediately before synthetic native `keyDown` dispatch and
ends at successful GPU completion of the submission containing the expected
color change. The same pixel readback instrument runs in both hosts. This
includes instrumentation and excludes physical key acquisition, compositor
presentation, scanout and photon latency.

An earlier baseline at 3460 × 2166 is excluded because the window manager
changed geometry. An incomplete earlier probe also addressed an `NSWindow`
instead of the terminal view. The probe now finds the actual `TelarView` or
Ghostty `SurfaceView`, establishes its first responder before timing and closes
only that test window. Production keyboard behavior and the timing endpoints
are unaffected by this instrument fix.

## PTY echo and output load

| Case | Build | n | p50 µs | p95 µs | p99 µs | Maximum µs |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Echo | Before | 200 | 645.792 | 1182.368 | 1851.217 | 5199.084 |
| Echo | After | 200 | 469.750 | 1051.183 | 1796.158 | 5761.666 |
| Output load | Before | 200 | 463.312 | 766.925 | 1119.906 | 1336.166 |
| Output load | After | 200 | 455.708 | 691.400 | 768.682 | 792.500 |

`tools/perf_e2e.py` measures injected PTY input until echo appears on Telar's
host PTY, excluding an outer renderer and GPU. Echo uses a 160 × 40 terminal
with a cat child. Load uses 240 × 70 with two flooding panes and a separate
echo pane. Different workloads explain why their medians cannot be compared
as a statement about the effect of adding load.

Both versions have two 100-response runs per case. Baseline runs come from the
initial paired series; the final candidate was collected later with the same
probe. [pty.json](pty.json) retains every response and shutdown. There are no
timeouts, and all eight runtimes stop, remove their sockets and clean up their
children. The candidate echo maximum increases even though its median falls.
Its two round medians are 585.833 and 236.000 µs, another reason not to infer a
general improvement from the aggregate.

With host output deliberately left unread, both versions deliver all 32 test
input bytes to the runtime before output draining resumes. Both shutdowns pass;
[slow-host.json](slow-host.json). The socket-level test separately blocks TX to
a non-reading peer while RX and local input continue, then joins both workers.

## Allocation, traffic and queue observations

A separate ReleaseFast build enables `-Ddiagnostics=true`, with echo tracing
disabled. The existing `client-split-step6/cpu_probe.py` samples CPU and RSS for
about ten seconds after warmup, once per version and workload. CPU percentages
use process CPU time from `ps`, relative to one core; zero means below this
probe's resolution. These short samples are not a CPU gate or memory soak.

| Workload | Build | Client CPU | Client peak RSS MiB | Runtime CPU |
| --- | --- | ---: | ---: | ---: |
| Idle | Before | 0.00% | 25.22 | 0.10% |
| Idle | After | 0.00% | 26.22 | 0.00% |
| Two output floods | Before | 14.59% | 26.17 | 181.88% |
| Two output floods | After | 14.91% | 27.45 | 182.17% |

[cpu.json](cpu.json) contains the exact durations, RSS observations and shutdowns.
Tracked client heap is 19,744,871 → 19,927,396 bytes at idle and
19,709,768 → 19,892,284 bytes under load. The allocation count is unchanged:
15 at idle and 24 under load. About 178 KiB of fixed additional storage comes
from replacing the 23-entry TUI completion array with 64 reserved-or-ready inbox
slots and their metadata. The TUI inbox itself occupies 284,464 bytes on this
target. The larger RSS differences also include memory outside this tracked
heap; these samples do not isolate all of that difference.

[telemetry-summary.json](telemetry-summary.json) selects roughly seven-second
steady-state intervals before the client's last sample, excluding teardown.
Full snapshots are retained in [telemetry.json.gz](telemetry.json.gz).

- Both processes and versions add **zero interactive allocations and bytes**
  in idle and load intervals. Tracked live bytes and allocation counts stay flat.
- The candidate inbox's lifetime high-water is 7 of 64 slots, including
  reservations. Sampled ready depth is at most 1; sampled reservations at most
  6. No inbox rejection, stale publication, input overflow, outbox saturation,
  runtime resync or reported drop occurs in these intervals.
- The candidate load interval admits and consumes 101,025 inbox messages, records
  101,247 wake signal attempts and yields 764 times with ready work remaining.
  Wakes count logical signals; the native endpoint may coalesce them.
- Baseline receives 39,941,917 wire bytes and 50,339 pane frames in 7.028 seconds;
  candidate receives 39,843,718 bytes and 50,203 frames in 7.034 seconds.
  Host writes are 610,981 and 618,424 bytes respectively. These free-running
  floods have slightly different frame counts; total bytes are not a change in
  encoded payload size. The wire schema is unchanged.
- Idle panes produce no new frames. The existing status bar still updates;
  this probe does not claim zero messages or writes for the whole application.

The first implementation and its measurements remain in
[initial-gpu-after.json](initial-gpu-after.json), [initial-pty.json](initial-pty.json),
[initial-cpu.json](initial-cpu.json) and
[initial-telemetry.json.gz](initial-telemetry.json.gz). Its inline RX result was
subsequently changed to a borrow from the receive owner. That avoids duplicating
RX results in the inbox, but does not shrink TUI slots: their larger completion
variants determine the stride. The initial hypothesis attributing the 178 KiB
TUI increase to RX values was incorrect; the capacity change explains it.

## Correctness and lifecycle

- macOS full suite: 3327 tests pass, with two platform skips;
  [full log](tests-macos.log). The final receive-owner change passes all 1502
  shared-client, TUI and GUI tests; [final log](tests-compact-macos.log).
- Linux final full suite plus GUI: 3329 tests pass;
  [final log](tests-compact-linux.log).
- Native window tests pass, including deferred frame admission, idle behavior
  and close with a presentation in flight; [macOS](window-macos.log),
  [Linux](window-linux.log). Linux enables Vulkan validation and exercises
  out-of-date acquire/present retries.
- Real native app checks pass input, resize, theme/font reload, invalid font
  rejection and recovery, and shell survival after window close;
  [final macOS result](macos-lifecycle.json), [Linux log](linux-lifecycle.log).
- Style, formatting, diff whitespace and import boundaries pass;
  [final checks](checks-final.log).

New tests cover full reservations, stale and duplicate tickets, concurrent
publication, bounded turns and wakes, cancellation without draining, blocked TX
with continuing RX/input, one TUI observation per batch, delayed owned headless
frames, malformed input, and queued GUI input/presentation completions. Existing
allocation-failure and allocation-free steady-state tests remain passing.

## Reproduction and limits

Build each revision into a separate prefix, then run the existing probes:

```sh
zig build -Doptimize=ReleaseFast -Decho-trace=true -Decho-trace-cpu=true \
  --prefix /tmp/telar-revision
python3 tools/gui_tui_latency.py /tmp/telar-revision/bin/telar /tmp/telar-gpu-run \
  --rounds 5 --samples 100
python3 tools/perf_e2e.py --baseline /tmp/telar-before/bin/telar \
  --candidate /tmp/telar-after/bin/telar --output /tmp/telar-pty-run \
  --samples 100 --repetitions 2 --cases echo load
```

The full five-round command also collects five TUI rounds; this report uses
only two TUI rounds per version as recorded above. Check viewport dimensions
before comparing GPU runs. The GUI-only `--viewport 1760 2166` option pins its
render target; TUI dimensions must also be verified in the result.

Measurements run serially, without builds or suites alongside them. Existing
desktop/editor processes remain active. These local macOS measurements and
Fedora VM checks do not substitute for the native Ubuntu x86_64
[performance gates](../../performance-gates.md), nightly/release workflows or a
memory soak. No Ghostty speed claim or Linux GPU performance conclusion is
inferred from these samples.
