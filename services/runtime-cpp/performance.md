# macOS ARM64 runtime comparison

The initial C++ snapshot below passed the performance gate in 22 workloads.
It predates the ongoing parity work and does not certify the current runtime.
Later sections retain accepted and rejected experiments for their specific
binary hashes. Current full-runtime acceptance remains open; the first proxy
service measurement also regressed against Zig. The request coverage and
remaining compatibility limits are in [README.md](README.md).

## Build identity

Measured on 2026-10-22, Apple M3, 8 logical CPUs, 16 GiB RAM,
macOS 26.6.2 (25G83), ARM64. Each JSON report records its start time, load
averages, executable paths, hashes, individual timings and oracle digests.
The host was shared; builds, tests and profiling were not run concurrently
with the final paired comparisons.

| Build | Identity |
| --- | --- |
| Zig baseline | Telar `23c87dfcb14d0a0524808c4ca46c3d9d17056ad1`, Zig 0.16.0, ReleaseFast. |
| C++ candidate | `feat/cpp-runtime` worktree at the same base, C++23, Homebrew LLVM 23.1.2, CMake Release (`-O3 -DNDEBUG`). |
| Ghostty | `a4edca2a90d6cf89900bb058e71cb6860cec78c5`, ReleaseFast, static libghostty-vt with the checked-in C API patch. |
| Zig SHA-256 | `1ccddbc99db623679f0190c65ab483745f05807e61496cb14206ac46e47c21f8` |
| C++ SHA-256 | `6a0d6ff50da9bbca244c5b0e83fbed1faf3fa9e893883f97f97aecd12d561fd0` |

The measured C++ executable was copied to a separate immutable path before
these comparisons. Its hash identifies that snapshot, not the current
`out/telar-runtime`.
Probe hashes are recorded in the corresponding JSON files. A clean dependency
build with `tools/build_ghostty.py --source` and a fresh CMake build also
succeeded and passed the 22 canonical oracles. These measurements do not
establish support for older macOS versions, Intel Macs, Linux or Windows.

## Initial measurements

Times are medians in microseconds per workload iteration. The ratio is the
median of the seven paired C++/Zig ratios, which can differ from the ratio of
the two independently calculated median times. Lower is better.

| Workload | Iterations per run | Zig µs | C++ µs | Paired ratio | C++ wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| sparse | 200 | 65.44 | 17.86 | 0.272 | 7/7 |
| full | 200 | 105.89 | 54.75 | 0.506 | 7/7 |
| scroll | 200 | 76.07 | 29.51 | 0.368 | 7/7 |
| unicode | 200 | 65.62 | 18.86 | 0.285 | 7/7 |
| modes | 200 | 62.49 | 17.39 | 0.270 | 7/7 |
| links | 200 | 94.00 | 42.93 | 0.442 | 7/7 |
| colors | 200 | 75.19 | 26.19 | 0.332 | 7/7 |
| mixed | 200 | 69.93 | 22.55 | 0.317 | 7/7 |
| bulk | 200 | 2940.85 | 1320.16 | 0.448 | 7/7 |
| graphemes | 200 | 213.53 | 120.41 | 0.564 | 7/7 |
| executions | 50 | 12320.68 | 2654.06 | 0.215 | 7/7 |
| limits | 50 | 13.10 | 6.58 | 0.502 | 7/7 |
| paths | 50 | 35.10 | 27.49 | 0.727 | 7/7 |
| worktrees | 50 | 2380.82 | 1968.48 | 0.832 | 7/7 |
| editor | 50 | 51.17 | 47.37 | 0.854 | 6/7 |
| suggestions | 50 | 51.12 | 47.32 | 0.914 | 6/7 |
| agents | 50 | 142.49 | 89.62 | 0.656 | 7/7 |
| agent-hooks | 200 | 467.61 | 431.82 | 0.935 | 6/7 |
| agent-hooks-interrupt | 200 | 475.72 | 432.45 | 0.947 | 7/7 |
| graphics | 100 | 4020.69 | 2496.69 | 0.618 | 7/7 |
| graphics-shared | 100 | 3942.42 | 2374.40 | 0.601 | 7/7 |
| history | 1 | 1962.50 | 1311.50 | 0.595 | 7/7 |

Raw results: [terminal](measurements/terminal-macos-arm64.json),
[services](measurements/services-macos-arm64.json),
[named agents](measurements/agents-macos-arm64.json),
[graphics](measurements/graphics-macos-arm64.json),
[history](measurements/history-macos-arm64.json).

## What the probes establish

Each probe talks to a real daemon over its Unix socket. Each run starts a
fresh daemon in a private temporary directory with isolated XDG directories
and no inherited `TELAR_*` settings. The Zig daemon uses `--no-config`.
Daemon startup is outside the timer. The same probe binary drives both
implementations. Timings include probe work and socket scheduling; they are
elapsed round trips, not isolated function CPU costs or latency percentiles.

- Terminal: an 80×24 PTY, sparse and full-screen changes, scrolling,
  Unicode, modes, hyperlinks, palette updates, alternate screens and edits.
  Bulk emits 4,096 lines of 80 bytes per iteration; graphemes appends 5,000
  combining marks. Each iteration waits for its visible marker and
  acknowledges frames. Text reads, search, selection, reconnect, resize and
  final output before exit are also checked. The timing covers the repeated
  input-to-visible-marker path; the final state checks run outside it.
- Executions: start a real shell, collect separate stdout/stderr, observe
  exit code 7 and forget the execution. Worktrees: register, update, launch
  two PTYs, inspect tabs and forget. The worktree benchmark does not measure
  Git observation on a large checkout.
- Paths: create a seven-entry filesystem fixture and alternate four
  queries. The timer includes fixture creation, the first index build,
  cached queries and fixture removal. Final results and highlight positions
  must match. This does not measure a large index or progressive replies.
- Limits: report a limit and query its ledger. Agents: reports and snapshots
  for an unknown provider, acknowledgement and rejection of a foreign
  process attempting descent verification.
- Named agents: execute the fixture as `claude` inside a real PTY, verify
  descent, report session/title/progress/state, persist a command with a
  duplicate start, query history and acknowledge completion. The interrupt
  variant also verifies that Ctrl-C reaches the PTY. The fixture's canonical
  cwd avoids the `/tmp` versus `/private/tmp` alias changing asynchronously.
- Graphics: repeatedly upload a 256×256 RGBA image, transfer all pixel bytes
  and placements inline or through shared memory, and return credit. Image
  replacement generations, deletion and an empty requested snapshot are
  checked. PNG decoding, input files and eviction under saturation are not
  performance cases in this table.
- History: one complete import/deduplication, paging, fuzzy search, filtering,
  statistics, output read, deletion and pruning sequence per run. Each query
  uses a new connection because the reference daemon closes history-query
  connections. Buffers are retained across requests.
- **Editor and suggestions measure unavailable-target responses.** Actual
  Neovim endpoint behavior and a configured Pi RPC fixture are covered by
  integration tests, but their successful paths have no paired performance
  result here. No real agent or suggestion model inference is measured.

The oracle compares the complete captured canonical byte streams. It does
not require identical packet boundaries or asynchronous notification order.
Terminal frames normalize pane/frame identities while preserving rendered
cells, styles and metadata. Service probes normalize generated workspace,
pane, process and worktree identities, timestamps, and the temporary path
root. Agent snapshots additionally normalize revision, sequence, age,
expiry and session identity. Command history normalizes its start time and
duration. Graphics normalize transfer revisions and generations while
checking their progression. Provider, status, authority, title, progress,
exit status, path ranking, styles and pixel bytes are not normalized.

## Performance changes and rejected variants

PTY startup initially closed every possible descriptor in the forked child.
On this host that meant scanning up to 61,440 descriptor numbers. The child
now enumerates its open descriptors into an 8 KiB stack buffer and closes
only those present, retaining the error-report pipe. Enumeration failure or
an exhausted buffer falls back to the full scan. Tests cover a high-numbered
inherited descriptor and missing standard descriptors. The initial
single-pair diagnostic showed worktrees at 3.959× Zig; the final seven-pair
result is 0.832×. The diagnostic is retained in
[experiments](measurements/experiments/), but is not acceptance evidence.

A `posix_spawn` SETEXEC/CLOEXEC_DEFAULT variant failed the controlling-PTY
setup with EBADF because of its close/action ordering and was discarded.
The final PTY path retains fork, setsid, TIOCSCTTY and an exec-error pipe.
An attempted `/dev/fd` enumeration through `getdirentries` was rejected
because that API was unavailable to the 64-bit build.

Named-agent authorization now verifies identity and ancestry in one walk
and reuses that result when the reporter is already the foreground process.
Accepted command reports acknowledge queue admission, matching Zig's
behavior, and persistence reuses prepared statements on the history worker.
Accepted writes survive disconnect and drain at orderly shutdown. The
intermediate authorization-only version still failed the gate. Queueing
and statement reuse reduced work, but those changes alone did not pass
every pair either.

The agent probe also had a measurement defect: it repeatedly allocated
8.5 MiB of client buffers while reconnecting. It now retains the buffers
and the control connection for both runtimes, while preserving the
reference's required history reconnections. The final results use only
that corrected probe. Earlier measurements are retained as experiment
history, not mixed into the final table.

Path queries avoid a worker round trip only for an already built, idle
index of at most 256 entries and a maximum 16,384-step matching budget.
A nonblocking mutex attempt protects the cache; everything else goes to
the dedicated path worker. The isolated candidate won 6/7 pairs at 0.584×;
the complete final run won 7/7 at 0.727×. The difference illustrates why
the report retains individual pairs instead of claiming a fixed speedup.

## Profile and ARM64 assembly

[runtime-bulk.sample.txt](measurements/runtime-bulk.sample.txt) samples the
final executable every millisecond for one second during 4,000 bulk
iterations. Of 850 main-thread samples, 454 were in `kevent`, 138 in the
PTY read syscall under `Pane::read`, and 145 under terminal ingestion.
The five service workers were waiting on their condition variables during
this workload. These are sampled stacks, not exact time attribution.
The sampled run is excluded from performance acceptance; its command and
hashes are in [profile-macos-arm64.json](measurements/profile-macos-arm64.json).

The saved [cell projection assembly](measurements/cell_projection.arm64.s)
uses `ubfx` for packed-cell fields and paired `ldp q0,q1` / `stp q0,q1`
instructions for 32-byte cell copies. The default-style ASCII cell loop
has no per-cell allocation or `memcpy` call. Style and grapheme API calls
remain on their conditional paths; exception allocation appears in cold
error paths. The [child descriptor assembly](measurements/child_descriptors.arm64.s)
shows the bounded stack buffer, process-descriptor enumeration and close
loop without heap allocation. Assembly inspection is limited to ARM64,
the requested initial platform.

## Tracing and verification

The Debug binary with ASan/UBSan produced 11,531 complete trace events
across three threads, with zero dropped records, while running named-agent,
sparse-terminal and path probes. JSON parsing, nonnegative timestamps and
durations, mode `0600`, normal shutdown flushing and preservation of an
existing trace file were checked. Release rejected `--trace`, contained no
trace symbols and contained none of the instrumented scope-name strings.
See [tracing-macos-arm64.json](measurements/tracing-macos-arm64.json).
Debug trace durations are not performance evidence.

Release and ASan/UBSan runtime test suites passed. All 95 project headers
compiled individually. The tests include allocation failure, process
identity rejection, accepted history writes after disconnect, high-FD
isolation, shared-memory credit cleanup, graphics state, Git hardening,
Neovim endpoint validation and suggestion-engine cancellation/deadlines.
The CMake sanitizer option instruments C++; the separate Ghostty build and
system libraries are outside that instrumentation.

## Reproduce the comparisons

Build C++ as described in [README.md](README.md). Build the Zig baseline
from the recorded commit in its own clean checkout and scratch prefix:

```sh
zig build -Doptimize=ReleaseFast --prefix /absolute/path/to/zig-baseline
```

From `services/runtime-cpp`, set `zig_runtime` to that baseline executable
and `cpp_runtime` to a frozen copy of the Release candidate. Run these
sequentially without concurrent builds, tests or profiling:

```sh
zig_runtime=/absolute/path/to/zig-baseline/bin/telar
cpp_runtime=/absolute/path/to/frozen/telar-runtime
python3 tools/compare_runtimes.py --zig "$zig_runtime" --cpp "$cpp_runtime" --probe out/runtime-probe --output /tmp/terminal.json --pairs 7 --iterations 200 --enforce
python3 tools/compare_runtimes.py --zig "$zig_runtime" --cpp "$cpp_runtime" --probe out/services-probe --output /tmp/services.json --pairs 7 --iterations 50 --workloads executions limits paths worktrees editor suggestions agents --enforce
python3 tools/compare_runtimes.py --zig "$zig_runtime" --cpp "$cpp_runtime" --probe out/agent-probe --output /tmp/agents.json --pairs 7 --iterations 200 --workloads agent-hooks agent-hooks-interrupt --enforce
python3 tools/compare_runtimes.py --zig "$zig_runtime" --cpp "$cpp_runtime" --probe out/graphics-probe --output /tmp/graphics.json --pairs 7 --iterations 100 --workloads graphics graphics-shared --enforce
python3 tools/compare_runtimes.py --zig "$zig_runtime" --cpp "$cpp_runtime" --probe out/history-probe --output /tmp/history.json --pairs 7 --iterations 1 --workloads history --enforce
```

The script alternates Zig/C++ and C++/Zig, fails immediately on an oracle
mismatch, and exits unsuccessfully if any workload wins fewer than six
of seven pairs. It does not silently retry or discard a losing pair.
Run it again when implementation, compiler, dependency or hardware changes.

## Agent observation parity pass

The new screen workload exercises real child processes named `claude`,
`codex` and `cursor-agent`. It checks process-only status, screen work and
completion, Codex Stop ordering, Cursor approval precedence, acknowledgements,
confidence, authority and the complete canonical agent snapshot.

The initial polling experiment failed: median C++/Zig ratios were 1.121,
1.029 and 1.092. Profiling showed avoidable provider scans, per-query snapshot
buffer initialization, and observation dispatch delayed until the next event
loop iteration. The implementation now selects only relevant scans, retains
snapshot buffers and submits observations as PTY output arrives.

The latest polling experiment (`screen-reused-snapshots.json`) has median
ratios below one but still fails the six-of-seven win-count gate. Its cause
is not fully established. The one-millisecond sleep in the polling client
quantizes observations; the notification workload was added separately,
without replacing or discarding the polling results.

In `screen-events.json`, 200 iterations in each of seven alternated pairs
produce identical canonical snapshots. Claude wins 7/7 with median 0.702,
Codex wins 6/7 with median 0.788, and Cursor wins 7/7 with median 0.750.
These measurements do not certify pending features or later binaries.

## Automatic command capture pass

The capture probe verifies rendered commands, UTF-8 and wrapping, human versus
automation authors, OSC 133 exit status, natural child exit and persisted history.
It normalizes record identities and timestamps for comparison; command text,
directory, workspace, status, exit code, author, origin and truncation remain
part of the exact oracle. Every command is acknowledged through history before
the next submission, avoiding the reference runtime's asynchronous attribution
race between an older completed command and a newer automation submission.

The first run (`capture-smoke.json`) was 18.066 times slower. Phase measurements
in `capture-phase-timing.json` located 102.289 ms of a 105.494 ms execution in
the final child-exit wait. The event loop had no SIGCHLD wakeup and could wait
for its 100 ms periodic poll. Watching SIGCHLD with a handler that preserves
wait status removed that delay. `capture-child-exit.json` passes six of seven
pairs with median C++/Zig 0.923.

Automatic observation initially regressed bulk output. The retained experiments
include `observation-terminal.json`, `observation-registered-agent-screen.json`,
`observation-completion-ready.json` and `observation-pty-foreground.json`.
Sampling found main-thread waits on the observation mutex and redundant PTY
queries. Atomic result readiness, nonblocking collection and direct TIOCGPGRP
removed most of that cost, but the last experiment still won only five of seven
bulk pairs. Adding command capture left all seven bulk pairs slower in
`capture-terminal-before-opt.json`.

The worker had also used a result-shaped request containing optional 4 KiB
process directory buffers for every pane. Requests now contain only input
fields, and an empty process-probe batch no longer constructs a result. In
`capture-process-snapshots.json`, sparse and bulk each win seven of seven pairs;
bulk has median C++/Zig 0.952. The paired C++ comparison against the frozen
pre-change executable (`capture-process-snapshots-ab.json`) also wins seven of
seven. `capture-process-snapshots-history.json` passes automatic capture seven
of seven. The reports retain exact binary hashes and all individual samples.

Subsequent CWD freshness, retirement bounds and validation changes require
new measurements; these results are not final acceptance of the entire port.

Reading CWD for every observation batch preserves rapid directory changes but
regressed bulk output (`capture-directory-terminal.json`). The OSC parser now
skips plain text with memchr; that candidate still won only 5/7 bulk pairs.
FixedText now copies only its initialized prefix, including when moving
optional process snapshots. `capture-fixed-text-terminal.json` passes sparse
and bulk 7/7; `capture-fixed-text-history.json` passes capture 6/7 and capture-CWD
7/7. Release and ASan/UBSan tests cover empty, overlapping and bounded copies.

After adding host metrics, `host-metrics-terminal.json` passes sparse 7/7 and
bulk 6/7 (median 0.904). The later server CLI binary fails bulk in
`server-cli-terminal.json` with 3/7 wins. This regression remains unresolved;
its dependent history run was not executed. No report establishes final
performance parity for the whole runtime.

Configured output capture passes 7/7 pairs of 40 commands in
`config-capture-output.json` (median 0.810), with exact output bytes and metadata.
The CWD probe formerly zeroed its entire vnode buffer before a syscall that
writes it completely; only exact-size successful reads are consumed. Removing
that redundant write yields 7/7 sparse and bulk wins at 160 iterations in
`cwd-buffer-terminal.json`. `cwd-buffer-ab.json` retains the paired comparison
against the frozen pre-change C++ binary. Neither result closes final acceptance.

The CWD-buffer candidate is rejected and reverted: the controlled A/B test
wins only 5/7 pairs (median 0.994), below the perf-pass acceptance rule. Its
7/7 Zig comparison is retained as experiment data, not evidence for accepting
that optimization. Frozen binaries are `/tmp/telar-cpp-config-capture-before-cwd-buffer`
and `/tmp/telar-cpp-cwd-buffer-runtime`.

## Configured agents and terminal throughput

The frozen `/tmp/telar-cpp-config-agents-json-v1` executable passes the exact
custom-agent notification oracle in seven pairs of 80 transitions, with median
C++/Zig 0.614 (`config-custom-agent.json`). Sparse output also passes 7/7.
Bulk still fails acceptance at 4/7 despite median 0.976, retained in
`config-agents-json-terminal.json`. The next experiment coalesces immediately
available PTY reads within the existing 16 KiB per-turn bound. Sampling had
identified per-read foreground ioctls as a main-thread cost. The experiment
must pass controlled C++ A/B, Zig equivalence and capture/CWD checks before
being retained.

The read-coalescing experiment is rejected and reverted: it loses all seven
C++ A/B pairs for both bulk and sparse output (`pty-coalescing-ab.json`).
An instrumented read census (`pty-read-census.txt`) shows 64,640 PTY reads in
the 1,024–2,047-byte bucket for 200 bulk iterations; requesting more bytes
does not make them available immediately. This census is not timing evidence.

The next candidate reports whether the capture worker is awaiting or running
a command. Output only needs a foreground-process query in those phases.
Every new input keeps queries enabled until its replay completes; a revision
guard prevents an older worker result from disabling them after a submission.
Input itself still samples the foreground process, and CWD probing is unchanged.

The foreground-demand candidate is accepted for the measured capture and
terminal workloads. Controlled C++ A/B wins 7/7 bulk pairs (median 0.804)
and 6/7 sparse pairs (0.986). Against Zig, all ten terminal workloads win
7/7 in `foreground-demand-terminal.json`; bulk median is 0.742. Capture,
capture-CWD and configured output capture also pass exact response comparison
and win 7/7 in `foreground-demand-history.json` and `foreground-demand-output.json`.
The frozen executable is `/tmp/telar-cpp-foreground-demand-v1/telar-runtime`.
The ARM64 assembly in `foreground-demand-pane-read.asm` confirms that an
`ldrb`/`cbz` guard bypasses the foreground call when no command awaits completion.
New session-file work changes the executable and requires its own verification.


## Session files and generated titles

`session-files-terminal.json` records 7/7 wins for all ten terminal workloads
with session-file readers enabled in the binary. The aligned file-title fixture
matches all three providers; its one-second polling intervals are functional
checks, not a throughput gate.

`descriptions-activity-performance.json` accepts the generated-title success
path at 6/7 paired wins, median C++/Zig 0.931, for 12 generations per runtime.
Its oracle includes canonical agent snapshots and the SQL title projection.
The fixture emits activity after its working hook so the reference runtime
starts its observation-driven generator reliably. Silent repeated fixtures
were diagnosed before this measurement and are not performance evidence.

`descriptions-terminal.json` passes all ten terminal workloads in seven pairs;
`descriptions-history.json` passes capture 6/7 and CWD capture 7/7. Those reports
predate the provider-replacement reset and subsequent process-identification
work. Final acceptance still requires measurements of the final binary.


## Reporter authorization and rejection

The initial group-identification implementation revalidated native process
lineage for every named hook report. The reference binds descent to the
connection and pane generation, so repeated native authorization was removed
for parity. `credentials-ab.json` passes Node reports 7/7 but group reports only
5/7; `credentials-zig.json` passes Node 7/7 and group reports 4/7. These changes
correct the authorization contract; they do not establish overall performance.

Process acquisition now uses the reference's six-attempt cache and explicit
rechecks. `process-cache-zig.json` passes Node 7/7 but group reports only 3/7.
The five functional process cases match in `process-cache-parity.json`.

`reporter-rechecks-performance.json` measures real agent replacement and nested
reporter rejection. State and title pass 6/7, progress and commands pass only
5/7, and nested rejection passes 2/7. Profiling the nested case found 438 sampled
stacks under `__cxa_throw`; exception allocation and unwinding were on the
repeated-refusal path (`reporter-nested-before.sample.txt`).

The accepted C++ optimization returns an explicit `ReportDecision` for cached
or confirmed refusals. The response is unchanged. `reporter-decisions-ab.json`
wins 7/7 nested-rejection pairs, median candidate/baseline 0.646. The ARM64
assembly in `reporter-decision.arm64.asm` returns enum value 2 directly from
those branches; payload allocation is confined to newly deferred reports.
Frozen binaries are `/tmp/telar-cpp-reporters-v3/telar-runtime` and
`/tmp/telar-cpp-reporter-decisions-v1/telar-runtime`.

Against Zig, `reporter-decisions-zig.json` passes state 7/7 and progress 6/7,
but nested rejection 5/7, title 4/7 and command reports 4/7 remain below the
acceptance threshold. Those runs last roughly 2–15 ms per process and retain
all samples. The measured A/B improvement does not close those Zig gates.


## Session cloning and pane event handles

`clone-shutdown-terminal.json` passes all ten terminal workloads at 160 iterations:
nine win 7/7 pairs; graphemes win 6/7. After public pane IDs were separated from
event handles, `pane-handles-terminal.json` passes all ten at 7/7 each. These
reports identify frozen executables before the progressive path-index changes.
They do not close the outstanding process/reporter gates or certify the final
runtime. The clone fix also resolves an observed shutdown hang; its stack sample
and failed initial report remain alongside the passing functional clone report.

## Progressive path queries

The first large-path comparison scans 4,129 entries and alternates four query
shapes. `paths-large-performance.json` has exact responses but wins 0/7 pairs,
median C++/Zig 1.345. The retained sample attributes most active samples to fuzzy
matching. Moving query folding outside the initial subsequence scan wins 7/7
A/B pairs, median 0.805 (`fuzzy-scan-ab.json`). Folding once per alignment row
and separating unreachable cells wins 6/7, median 0.986 (`fuzzy-row-ab.json`).
Both changes are retained. The intermediate Zig comparison still wins 0/7,
median 1.073 (`fuzzy-scan-zig.json`); final acceptance remains open.

Three measured candidates were rejected and reverted: separator bonus lookup
(2/7, 1.021), separate alignment kernels (0/7, 1.019), and an ARM64 vector byte
search (4/7, 0.993). Their reports are `fuzzy-bonus-ab.json`,
`fuzzy-alignment-ab.json` and `fuzzy-byte-ab.json`. Each candidate passed a
12,000-case exact score/highlight oracle before timing. The vector experiment
also passed a protected-page bounds test; its code and test were removed with
the rejected implementation. No failed timing report was replaced by a retry.

`paths-tsan.json` records an isolated ThreadSanitizer run of the progressive
index and immutable-prefix tests with no diagnostics. This covers the tested
build/query/cancel/publication interactions, not all runtime concurrency.

## Event-driven process observation

Git/worktree parity exposed a scheduling mismatch: idle 250 ms probes replaced
OSC 7 logical directories with native physical paths. The corrected scheduler
observes every nonempty event batch and only creates an empty batch for an
explicit process recheck. Functional process, reporter, capture and worktree
oracles pass; the change also increases process-query work during terminal I/O.

`git-observation-terminal.json` passes nine terminal workloads at 7/7 wins,
but bulk loses 0/7, median C++/Zig 1.286. The isolated large-path measurement
`git-observation-large-paths.json` also loses 0/7, median 1.086. An earlier
`workspace-git-paths-large.json` overlapped a functional fixture and is explicitly
excluded from acceptance; its exclusion is retained in the report.

The bulk profile `git-observation-bulk.sample.txt` identifies repeated foreground
ioctls, native identity reads and result initialization. Skipping unchanged cached
process projections passes the process oracle and wins 6/7 bulk A/B pairs,
median 0.879, and 6/7 sparse pairs (`process-projection-ab.json`). The ARM64
`process-projection.arm64.asm` shows two byte guards before `applyProcess`.

Reusing the root identity when the foreground group equals the root PID avoids
two duplicate native reads while retaining before/after identity checks.
`shared-identity-equivalence.json` matches group, Node and process-name results;
`shared-identity-ab.json` wins bulk 7/7 and sparse 6/7. The ARM64 comparisons in
`shared-identity.arm64.asm` bypass the duplicate identity calls on equal PIDs.

Against Zig, `shared-identity-zig.json` wins sparse 7/7, but bulk only 5/7 despite
a median ratio of 0.990. This does not pass the six-of-seven acceptance rule.
Both optimizations are retained based on their controlled C++ A/B comparisons;
bulk and large paths still need work before final performance acceptance.

Default-initializing process result entries avoids clearing their unused text
capacity. Every readable field remains initialized, and only text prefixes are
copied. `process-result-equivalence.json` matches all three process fixtures.
The ARM64 assembly in `process-result.arm64.asm` removes the 72,832-byte clear
before the field-initialization loop. This candidate is retained: bulk wins
6/7 C++ A/B pairs, median 0.990, while sparse and full each win 5/7 with medians
below one (`process-result-ab.json`). The script's stricter every-case gate
fails for those two controls; neither has a consistent regression under the
per-candidate acceptance rule. The Zig comparison still fails bulk at 2/7,
median 1.046; sparse and full each pass 7/7 (`process-result-zig.json`).

Skipping native identity reads for unchanged cached groups passed functional
process and reporter oracles but failed timing. `cached-process-ab.json` wins
only 3/7 bulk pairs and 1/7 sparse pairs, despite 7/7 full-frame wins. The
candidate and its specific test changes were reverted. The regression's cause
has not been established; the failed report remains part of the record.


## Bounded PTY reads and concurrent interaction

`read-batch-ab.json` measures an eight-read, 64 KiB batch against the prior C++
binary. Bulk and full-frame output win 7/7. The concurrent-pane control rejects
that implementation: `read-batch-concurrent-ab.json` has 0/7 mean-latency wins
and 1/7 P99 wins, with a median P99 ratio of 1.261. The unconditional batch was
reverted.

The retained implementation allows that batch only when exactly one pane exists.
Every pane in a multipane runtime keeps one read per event.
`isolated-read-ab.json` has 7/7 bulk and full-frame wins; sparse has 3/7 with a
1.004 median ratio. `isolated-read-concurrent-ab.json` has 4/7 mean wins and
2/7 P99 wins, with median ratios 0.993 and 1.050. No control has a consistent
0–1/7 regression. `isolated-read.arm64.asm` records the bounded loop.

Against Zig, `close-state-terminal.json` passes all ten terminal workloads:
sparse wins 6/7 and the other nine win 7/7. Bulk's median ratio is 0.828.
`close-state-concurrent.json` wins 7/7 for mean, P50, P95 and P99 latency;
median ratios are 0.493, 0.481, 0.479 and 0.516. Maximum latency wins 5/7.
The concurrent fixture keeps a second pane continuously producing bulk output;
it records each runtime's background iteration count rather than fixing equal
background bytes. Results certify this interactive workload, not equal-volume
aggregate throughput.

`worktree-lifecycle-terminal.json` repeats all ten workloads after asynchronous
tab/worktree closure and command-label fixes. All ten win 7/7 with exact output.
These reports identify distinct frozen executables; final whole-runtime
acceptance remains open.

`client-definitions-terminal.json` passes all ten terminal workloads 7/7 after
panel/pick validation. `client-config-terminal.json` also passes all ten 7/7
after bar/component validation and command-tab budgeting, with bulk median
C++/Zig 0.854. The matching `client-config-concurrent.json` passes mean, P50,
P95 and P99 in 7/7 pairs, with medians 0.494, 0.489, 0.477 and 0.500;
maximum latency passes 6/7. These certify the frozen `client-config-v1` binary,
before the later exact-notice and default-keymap corrections.

`client-admission-terminal.json` checks the executable after handshake admission
and basic client/binding validation: all ten terminal workloads win 7/7, with
bulk median C++/Zig 0.789. `client-admission-concurrent.json` wins 7/7 for mean,
P50, P95 and P99 latency, with median ratios 0.457, 0.448, 0.446 and 0.464.
Maximum latency wins 5/7. The same continuous-background-work qualification
applies; these measurements do not close the other outstanding workload gates.

## Client keymap and media worker measurements

`client-keymap-{terminal,services,agent-hooks,graphics,history}.json` compares
the frozen keymap executable across the original 22 workloads. All outputs
match, and 18 workloads satisfy the six-of-seven rule. Suggestions win 4/7
(median C++/Zig 0.968), agent hooks 5/7 (0.838), inline graphics 2/7 (1.039),
and shared graphics 1/7 (1.032). These four gates remain open.

`media-worker-graphics-parity.json` verifies inline/shared image bytes and
placements after moving decoding to a dedicated worker. In the subsequent
seven-pair timing, inline graphics wins 2/7 (1.044) and shared graphics 2/7
(1.021). Nine terminal workloads win 7/7; bulk wins 5/7 (0.916).
`media-worker-concurrent.json` wins mean interaction latency in 7/7 pairs,
median 0.569. Its background byte volume remains scheduler-dependent.
The worker is required for parity; these measurements do not certify its
performance against Zig.

An eight-step graphics-publication loop was rejected and reverted.
`media-publication-paired-graphics.json` compares it with the prior C++ binary:
inline/shared graphics each win only 3/7, with medians 1.003 and 1.019.
Controls in `media-publication-paired-control.json` win sparse 2/7, full 3/7
and bulk 3/7. The rejected candidate's Zig comparisons remain in
`media-publication-zig-{graphics,terminal}.json`; the terminal results do not
override its failed controlled A/B test. Later file-input changes require new
measurements against the final executable.

`media-files-{graphics,terminal,concurrent,services,agent-hooks,history}.json`
checks the file-input executable before prepared transfers. All compared
outputs match. Eighteen of the original 22 workloads pass: inline graphics
wins 3/7 (median 1.007), shared output 2/7 (1.090), editor 4/7 (0.973), and
suggestions 2/7 (1.040). The four new image-input workloads have file/inline
3/7 (1.015), file/shared 0/7 (1.042), child-shared/inline 7/7 (0.901), and
child-shared/shared 6/7 (0.916). Concurrent mean, P50, P95 and P99 win 7/7;
their median ratios are 0.592, 0.566, 0.607 and 0.613, respectively. Maximum
latency wins 5/7. Prepared-transfer changes require their own measurements.


## Prepared image transfers and independent graphics scheduling

`media-transfers-{paired-graphics,zig-graphics,zig-terminal,zig-concurrent}.json`
records the prepared-transfer candidate. All outputs match. Against Zig, all
ten terminal workloads and concurrent mean latency win 7/7; bulk has median
0.843 and concurrent 0.565. Graphics inline/shared win 3/7 (1.060) and 1/7
(1.045), file inline/shared 1/7 (1.043) and 0/7 (1.039), and child shared input
inline/shared 6/7 (0.944) and 7/7 (0.943). Preparing copies on the worker is a
functional isolation requirement, not a demonstrated graphics speedup.

The subsequent scheduling correction lets graphics advance when cell delivery
is waiting for its pacing deadline, matching Zig's independent delivery lanes.
`graphics-pacing-paired-graphics.json` has only file/inline reaching 6/7 (0.992).
Paired sparse/full/bulk controls win 3/7, 4/7 and 3/7, with median ratios
1.003, 0.989 and 1.012. Against Zig, inline/shared win 3/7 (1.007) and 2/7
(1.023), file inline/shared 2/7 (1.031) and 2/7 (1.038), and child shared input
inline/shared 7/7 (0.907) and 6/7 (0.955). The correction fixes scheduling;
these measurements do not establish an overall performance improvement.


## Graphics quota enforcement

`graphics-quotas-{paired-graphics,paired-controls,zig-graphics,zig-terminal,
zig-services,zig-agent-hooks,zig-history,zig-concurrent}.json` records the
quota candidate before vectorizing framing. All compared outputs match.
Against the preceding C++ runtime, file/inline and file/shared regress in all
seven pairs, with median ratios 1.315 and 1.361. Inline/shared direct input
wins 7/7 (0.929) and 6/7 (0.935); child shared input inline/shared wins 1/7
(1.027) and 5/7 (0.990). Sparse/full/bulk controls win 4/7 (0.973), 5/7 (0.986)
and 7/7 (0.950). The file regression is retained as an unresolved gate.

Against Zig, all ten terminal workloads pass 7/7, as do history and concurrent
mean latency (median 0.573). The original 22 workloads pass 19 gates: shared
graphics wins 5/7 (0.945), editor 3/7 (1.061), and suggestions 1/7 (1.089).
Of the four added media workloads, child shared input passes both transports;
file inline/shared wins 0/7 with ratios 1.382 and 1.421. Thus the extended
26-workload set passes 21 gates. These are not final acceptance results.

`graphics-quotas-file-{quotas,previous}.sample.txt` retains three-second
sampling profiles from each frozen binary. In the quota profile, 521 samples
from the media worker's upload observation descend into `KittyFraming::advance`;
only two samples on that path descend into quota enforcement. The next candidate
skips printable ASCII runs with ARM64 vectors while preserving scalar control
transitions. It must pass equivalence and paired timing before acceptance.


## Rejected global ASCII framing scan

`graphics-framing-{paired-graphics,paired-controls,zig-graphics,zig-terminal,
zig-concurrent}.json` evaluates vector scanning in every Kitty framing caller.
All functional outputs match; Release, ASan/UBSan and 243 standalone headers
pass. Unit cases cover all 256 byte values at 32 vector offsets, plus every
split of a long command. `graphics-framing-advance.asm.txt` confirms a 16-byte
ARM64 load, signed comparison and reduction; `graphics-framing-file.sample.txt`
reduces scanner samples from 524 to 25 in the three-second file workload.

The candidate is nevertheless rejected globally: against the preceding C++
binary, direct inline/shared images win 0/7 with ratios 1.268 and 1.326. File
inline/shared improves in 7/7 (0.744 and 0.741). Sparse/full/bulk controls win
4/7, 4/7 and 5/7, without a consistent control regression. Against Zig, direct
inline/shared wins 0/7 (1.260 and 1.347), file inline/shared 1/7 (1.042 and
1.076), and child shared input inline/shared 7/7 (0.927) and 6/7 (0.898).
All ten terminal workloads and concurrent mean latency still pass 7/7.

The follow-up keeps scalar framing on the interactive PTY path and selects
vector scanning at compile time only for upload counting on the media worker.
This isolates the changed processing path; paired results must establish its
benefit before it is accepted.


`worker-framing-{paired-graphics,paired-controls,zig-graphics}.json` rejects
vector scanning limited to upload counting as well: direct inline/shared
wins 1/7 (1.124) and 2/7 (1.037) against the quota binary, while file
inline/shared wins 7/7 (0.740 and 0.744). All vector framing changes were
removed. The scalar scanner remains the path for arbitrary PTY output.

`encoded-framing-{paired-graphics,paired-controls,zig-graphics}.json` evaluates
counting only the envelope of a runtime-generated file chunk. Control data is
validated and base64 cannot contain framing transitions; the opening escape
still accounts for a preceding incomplete APC. Exact quota/input oracles and
unit cases starting in each framing state pass. File inline/shared improves
7/7 (0.739 and 0.724) against the quota binary; direct inline/shared wins
4/7 (0.984) and 2/7 (1.028). However, sparse control regresses in 6/7
(1.039), so full acceptance remains open. Against Zig, direct inline passes
7/7 (0.956), shared wins 4/7 (0.999), file inline/shared 3/7 (1.005) and
2/7 (1.051), and child shared input inline/shared 7/7 (0.928) and 5/7 (0.986).

The next candidate encodes pairs of base64 symbols through an 8 KiB constant
table and handles padding only after complete triples. It uses the preceding
frozen graphics probe for both runtimes so changing the shared encoder cannot
change the fixture's own encoding work. Its paired controls and graphics
results must pass independently.


`base64-pairs-{paired-graphics,quota-graphics,paired-controls,zig-graphics,
zig-terminal,zig-concurrent}.json` records that candidate. File inline/shared
improves in 7/7 (0.949) and 6/7 (0.944) against encoded framing, but direct
shared output wins only 1/7 (1.014). Against the quota binary, direct shared
wins 1/7 (1.012); sparse/full/bulk controls win 5/7, 3/7 and 2/7. This leaves
a shared-output control concern rather than establishing aggregate acceptance.
Against Zig, direct inline/shared passes 6/7 (0.986 and 0.975), file
inline/shared wins 5/7 (0.974 and 0.993), and child shared input inline/shared
passes 7/7 (0.916) and 6/7 (0.963). All ten terminal workloads and concurrent
mean latency pass 7/7. Release (1.34 s), ASan/UBSan (5.07 s), 243 standalone
headers and exact six-mode image output pass. The assembly in
`base64-pairs-encode-chunk.asm.txt` shows two 16-bit table loads/stores per
complete triple.

The next candidate reads up to sixteen 3 KiB file chunks at once while feeding
exactly the original 3 KiB protocol chunks to Ghostty. Failed read-ahead retries
one chunk before using the existing partial-upload termination path. This
reduces pread calls without weakening the byte/chunk quotas or changing
successful protocol payloads. It requires separate paired measurements.


`file-read-batch-{paired-graphics,paired-controls,zig-graphics,zig-terminal,
zig-concurrent}.json` records the sixteen-chunk read candidate. Against the
preceding base64 binary, file inline/shared wins 5/7 (0.968) and 7/7 (0.962);
the inline target therefore does not yet pass the paired acceptance gate.
Direct inline/shared and child shared inline/shared controls win 4/7, 3/7,
2/7 and 4/7. Sparse/full/bulk controls against the quota binary win 4/7,
2/7 and 3/7. Against Zig, direct inline/shared wins 5/7 (0.980) and 6/7
(0.984), file inline/shared 5/7 (0.948) and 6/7 (0.927), and child shared
inline/shared 7/7 (0.933) and 5/7 (0.970). All ten terminal workloads and
concurrent mean latency pass 7/7; bulk is 0.927 and concurrent mean 0.567.
Functional six-mode and sanitized file-input comparisons pass. These results
leave graphics acceptance open; lower medians alone are insufficient.


`atomic-frames-*` records the complete mapped-frame candidate. All exact
oracles pass. Against the preceding read-batch binary, atomic file inline/shared
wins 7/7 (0.863 and 0.798); atomic child shared inline/shared wins 2/7 (1.033)
and 5/7 (0.984). Ordinary graphic controls win 4/7, 6/7, 2/7, 2/7, 6/7 and
5/7; sparse/full/bulk controls win 5/7, 3/7 and 2/7. No independent control
falls to zero or one win. Atomic child-shared target acceptance remains open.

Against Zig, the original suite passes 19/22: direct inline graphics (5/7,
0.991), editor (3/7, 1.013) and suggestions (4/7, 0.998) miss the gate.
All ten terminal cases pass (sparse 6/7, the others 7/7); bulk is 0.848.
Both agent-hook cases and history pass. All four ordinary external-input
extensions pass: file inline/shared 7/7 (0.947) and 6/7 (0.992), child shared
inline/shared 7/7 (0.924) and 6/7 (0.970). Atomic file inline passes 6/7
(0.978), atomic file shared fails at 3/7 (1.005), and atomic child shared
inline/shared passes 7/7 (0.907 and 0.943). Thus the 30 serial cases pass
26/30; concurrent mean latency separately passes 7/7 (0.566). Every report
retains its executable/probe hashes and all seven measurements.

`service-admission-*` measures early rejection of suggestions without a configured
engine and editor candidate filtering by the cached process name. Before this
change every unavailable suggestion dumped the terminal, allocated a prompt and
woke a worker; every editor request inspected unrelated foreground processes.
The editor worker now also exposes its outstanding work so admission enforces
one global request, including completed requests awaiting collection.

Against the frozen atomic-frame C++ binary, editor and suggestions each win
7/7, with median ratios 0.839 and 0.746. Independent sparse/full/bulk controls
win 4/7 each (0.992, 0.999 and 0.975); no control consistently regresses.
Against Zig, editor wins 6/7 (0.859) and suggestions 7/7 (0.769). All seven
service cases pass, all ten terminal cases pass 7/7, and concurrent mean
latency passes 7/7 (0.570). Graphics and hooks were not remeasured in this
candidate, so their preceding results do not establish acceptance for this
executable. The frozen binaries and all exact oracle hashes are recorded in
the reports. Failed admission fixture runs remain alongside their corrected
versions; functional-only sanitizer ratios are not performance evidence.


### Proxy transport experiments

`proxy-service-performance-v1.json` is the first integrated proxy measurement.
All byte oracles pass, but CONNECT, 64-byte round trips and 64 KiB round trips
win only 1/7, 0/7 and 1/7 against Zig, at median ratios 1.086, 1.408 and 1.099.
A diagnostic interposer, excluded from timing, counted 79,767 receive calls
and 59,763 empty reads for 10,000 small round trips. Readiness-directed relay
reduces that to 20,006 receive calls and two empty reads.

A cached `poll` reactor did not pass its paired gates and was removed. The
Kqueue actor then gained an occupied-slot bitset. The first expanded CONNECT
run failed mid-series, including a C++ reference run; its cause was not proven.
The checker now saves each completed pair immediately. CONNECT runs use 200
iterations, while persistent workloads use 10,000 small or 1,000 large round
trips. The persistent probe warms up 32 iterations, checks all received bytes
inside the loop and writes its normalized dump after timing. Results using
this probe cannot attribute the change from the first short run solely to
runtime improvements.

`proxy-indexed-v4-bounded-*` records the longer workloads. Against the original
C++ service, small and large persistent transfers each win 6/7 at 0.971 and
0.913; CONNECT wins 4/7 at 0.993. Against Zig, they win only 2/7 at 1.031,
1/7 at 1.018 and 1/7 at 1.081. Outliers remain in the reports. Independent
terminal/service controls also leave a sparse-terminal concern at 1/7 and
1.006. These results do not satisfy final acceptance.

`proxy-watches-v5-*` batches socket registrations and relies on Kqueue removing
owned descriptors at close. Its functional and descriptor-reuse tests pass,
but the large-transfer control regresses against v4 in 6/7 pairs, median
1.027; small transfers and CONNECT win 5/7 and 3/7. Against Zig none of the
three modes passes. This variant was rejected and its source changes removed.

### HTTP/1 component measurements

`http1-message-performance-v1.json` measures the new C++ message relay against
the original Zig HTTP relay in memory. Both forward the same bytes and report
the same deframed body; C++ reuses connection-owned storage across messages.
These measurements exclude TLS, sockets and actor scheduling. Empty requests,
small bodies and large heads win 7/7 at 0.407, 0.437 and 0.030. Large bodies
win 1/7 at 1.016, and chunked messages lose 7/7 at 1.172.

A growing peek window reduces bytes copied beyond the delimiter. In
`http1-message-lookahead-v2.json`, large bodies and chunks improve 7/7 against
v1 at 0.930 and 0.918. Empty/small messages and large heads consistently regress,
so this variant was removed. Chunked messages also still lose all seven pairs
against Zig at 1.067. The next candidate exposes an immutable view of buffered
TLS input and consumes only the delimiter prefix. Body reads use the original
direct path when no prefetched bytes remain. Acceptance requires fresh paired
measurements and the same exact framing oracle.

### Buffered HTTP/1 and integrated transport controls

All eight HTTP/1 variants preserve the 51,597-case oracle. Buffered head views
improve all five cases against v1, but chunked messages initially fail the Zig
gate. Borrowed body views remove another copy. The current v8 component wins
7/7 against Zig in empty requests, small bodies, large bodies, large heads and
chunks, at median ratios 0.350, 0.378, 0.888, 0.027 and 0.880. Against the earlier
v3 C++ prototype, empty/small messages still regress in all seven pairs by
3.3%/3.0%; this remains an acceptance concern. Compile-time delimiter and split
write-path experiments were rejected. Reports retain every attempted variant.

The integrated HTTP/1 executable does not meet proxy performance acceptance.
`http1-runtime-zig-proxy-*` gives small/large/CONNECT ratios 1.083, 1.167 and
1.124, with 0/7, 0/7 and 2/7 wins. Large opaque transfers also regress against
the earlier indexed v4 C++ runtime in 6/7 pairs, median 1.161. Independent
terminal and service controls have no 0/7 or 1/7 results.

The transport-separation experiment gives opaque and intercepted connections
distinct allocator-owned components. Against the HTTP/1 v8 executable, small
and large transfers improve 6/7 at 0.981 and 0.906; CONNECT wins 5/7 at 0.970.
Against indexed v4, large transfers still regress 6/7 at 1.027. Against Zig,
small/large transfers win only 1/7 and 2/7 at 1.049 and 1.053. The Zig CONNECT
series is incomplete: its sixth pair failed with `EADDRNOTAVAIL` in the Zig
probe's connect call. Its five completed pairs are not an accepted result.
The earlier timeout/outlier pairs remain in their reports. These experiments
do not establish a single cause for the remaining opaque-transport gap.

### HTTP/2 observation and sensitive erasure

`http2-observer-functional-v1.json` and `http2-observer-erasure-v2.json` compare
9,820 inputs with the unchanged Zig relay, using the same nghttp2 1.70.0 static
library. Forwarded bytes, consumed counts, serialized header/body/lifecycle
events and limit/failure statistics match. The measurements include inflater
allocation/destruction and header-block erasure, but exclude TLS and sockets.

The first C++ version loses all seven pairs in all five cases. Assembly shows
131,072 individual volatile byte stores at observer destruction. The shared
sensitive-erasure helper now permits bulk memset and retains a compiler memory
barrier after the last use. Erasure is retained in the release binary; it is
not removed from the workload. The v2 request/response headers, multiplexed
streams and large-body cases win 7/7 against Zig at 0.362, 0.701, 0.610 and
0.560. Seven-byte fragmentation still loses 7/7 at 1.653. Independent whole
runtime controls are required because the erasure helper is shared.

The v2 fragmented-input sample attributes most payload CPU samples to the
response-table lookup. Request DATA unnecessarily scanned all 128 empty
response slots for every fragment. v3 only looks up response state in the
response direction. It preserves all 9,820 exact cases, improves fragmentation
7/7 against v2 at 0.465, and has 2–4 wins in each independent component control
(none consistently regresses). Against Zig all five cases win 7/7: request
headers 0.669, response headers 0.380, multiplexed streams 0.590, large bodies
0.523 and fragmented input 0.791. The v3 integrated Release and ASan/UBSan suites
pass; whole-runtime paired controls remain necessary for acceptance.

`http2-runtime-v3-*` records those integrated controls. Compared with the
transport-separation C++ executable, small/large/CONNECT cases win 2/7, 4/7 and
4/7, at 1.006, 0.965 and 0.990. Against Zig they win 0/7, 0/7 and 1/7, at 1.069,
1.063 and 1.324. CONNECT uses 100 iterations in this series. Terminal controls
have 3/7, 4/7 and 5/7 wins; executions/editor/suggestions have 4/7, 3/7 and 4/7.
No independent control consistently regresses. The proxy remains unaccepted.

The separate syscall diagnostic `proxy-system-calls-v2.json` forwards the same
10,000 64-byte round trips plus 32 warmups through each runtime. Zig records
20,071 readv and 20,070 sendmsg calls without Kqueue waits; C++ records 20,070
recv and 20,065 send calls plus 20,076 Kqueue waits. Darwin's recv/send wrappers
also trigger the recvfrom/sendto hooks, so those pairs must not be counted
twice. These counts support investigating the extra readiness round trips;
they are not a timed performance comparison or proof that scheduling alone
accounts for the entire remaining difference.
# Pane reuse and capture storage

The launch-environment correction passed reuse against the preceding C++ binary
in 7/7 pairs (median 0.905), but lost every pair to Zig (2.851).
`launch-parity-{paired-reuse,zig-reuse,control-terminal,control-services}.json`
retain that result and its independent controls. Sampling identified redundant
resize, color application and snapshot work on an already attached pane.

The subsequent unchanged-pane correction wins reuse 7/7 against both the prior
C++ binary (0.229) and Zig (0.666), with 10,000 requests per pair.
`unchanged-pane-control-terminal.json` records sparse 1/7 (1.036), full 5/7
(0.997) and bulk 2/7 (1.007); the sparse control is a consistent regression and
prevents accepting the change's overall performance. Service controls record
executions 2/7 (1.015), editor 3/7 (1.014) and suggestions 2/7 (1.076).
The reports remain evidence of an unresolved control failure, even though the
targeted reuse workload improved. Functional/sanitizer results are separate.

`capture-storage-v1.json` compares independent capture components with the
unchanged Zig library after 4,529 exact equivalence cases. Small captures,
fragmented captures, quota pressure and metadata win all seven pairs. The 1 MiB
case wins only 5/7 and does not pass the six-win gate. This component measurement
does not certify integrated proxy performance or unfinished capture delivery.

`capture-decode-v8.json` passes the 3,136 non-crashing decoder cases but loses
all small-body comparisons. Valid-input profiles under
`/tmp/telar-cpp-capture-decode-v8/small-{gzip,zstd}-valid.sample.txt` identify
allocation/erasure work; the earlier `small.sample.txt` used a rejected fixture
and is not the valid-body profile. Removing an unnecessary Zstd output reserve
and redundant zlib allocation zeroing preserves erasure on release and produces
`capture-decode-v9.json`.

The v9 256 KiB cases win 7/7 for gzip (0.682), deflate (0.686), Brotli (0.962)
and Zstd (0.871). All 1 KiB cases still lose 0/7: gzip 1.459, deflate 1.455,
Brotli 1.272 and Zstd 1.275. Decoder performance acceptance remains open.
There is no paired C++ A/B report for these two changes yet; successive Zig
comparisons alone do not establish their isolated speedups.


# Integrated capture pipeline

`capture-pipeline-v1` freezes the first runtime with HTTP/1 and HTTP/2 capture
adapters, a bounded receive worker and the joiner connected to the runtime loop.
Release and ASan/UBSan runtime/TLS suites pass; an isolated ThreadSanitizer run
also passes (`capture-pipeline-tsan-v2.json`). Its first link attempt omitted
`platform/file_descriptor.cpp`; that failed build log is retained. All 368
headers present at the time passed standalone compilation. The later shared
HTTP/2 oracle test header is outside that header-check snapshot.

`capture-pipeline-runtime-functional-v1.json` verifies matching proxy status,
environment, CONNECT and opaque forwarding with capture enabled. Those timings
are functional diagnostics only. TLS fixture tests verify captured bodies and
metadata; they are not an integrated C++/Zig capture performance comparison.

The isolated `capture-pipeline-{paired,zig}-*-v1.json` series uses the frozen
executable. Against the preceding C++ runtime, opaque small/large/CONNECT cases
win 3/7, 5/7 and 3/7, with median ratios 1.003, 0.963 and 1.016. Against Zig,
they win 2/7, 2/7 and 0/7, at 1.038, 1.032 and 1.233. Latency uses 10,000
iterations, throughput 1,000 and CONNECT 100. No proxy acceptance is claimed.

Independent controls against the preceding C++ binary record sparse/full/bulk
4/7, 5/7 and 5/7 (0.975, 0.998, 0.958), and executions/editor/suggestions
4/7, 3/7 and 4/7 (0.988, 1.009, 0.982). None consistently regresses. These
controls do not resolve the older sparse-output regression against the earlier
launch implementation, nor the remaining proxy and small-body decoding gaps.

`http2-capture-v4.json` records 9,860 exact cases and five seven-pair wins:
request headers 0.405, response headers 0.387, multiplexing 0.454, large bodies
0.717 and fragmented input 0.465. These are component measurements using the
real Zig capture adapters, not integrated TLS/runtime acceptance.

The isolated Lua worker has frozen versions under `/tmp/telar-cpp-plugin-host-v*`.
v2 loses the empty/notification/JSON/256 KiB cases at 0/7, 1/7, 0/7 and 0/7
(1.067, 1.062, 1.039, 1.160). Sampling identifies allocation mutexes in the
single-threaded host and copies through the 16 KiB frame read buffer. Profiles
and the failed experiment are retained.

v3 injects the unsynchronized budget allocator into this single-threaded
subcommand. Against v2 it records 5/7, 7/7, 6/7 and 4/7 wins (0.947, 0.925,
0.935, 0.997). Against Zig, it records 4/7, 5/7, 7/7 and 0/7 (0.990, 0.995,
0.973, 1.142). Its empty-case improvement does not meet the six-win gate.

v4 reads large remaining payloads directly into their owned frame storage.
Fragmentation and consecutive-frame tests pass. Against Zig, empty/notification/
JSON/256 KiB record 2/7, 4/7, 6/7 and 7/7 (1.029, 0.997, 0.974, 0.989).
Overall plugin performance acceptance remains open. Reports distinguish exact
functional comparisons from six reference `requireLocal` crashes; those crashes
are retained and excluded from timing workloads.

The v4 C++ A/B comparison confirms the direct-read change: the 256 KiB case
wins 7/7 at 0.870; empty/notification/JSON controls record 4/7, 5/7 and 5/7
(0.999, 0.997, 0.986), with no consistent regression.

v5 gives each Lua host its own recycling allocator. It erases released
blocks and retains at most 512 KiB, with constant-time lookup for blocks up to
4 KiB. Against v4, empty/notification/JSON/256 KiB win 7/7 each at 0.906,
0.906, 0.888 and 0.984. Against Zig, the same workloads win 7/7, 7/7, 7/7
and 6/7 at 0.903, 0.891, 0.869 and 0.983. Each uses 10,000 events per pair,
64 warmup events and exact reply checks. The isolated worker passes its gates;
configured plugin integration has not been measured yet.

Independent v4→v5 terminal controls (160 iterations) record sparse/full/bulk
3/7, 6/7 and 3/7 (1.006, 0.998, 1.001). Service controls (50 iterations)
record executions/editor/suggestions 4/7, 3/7 and 6/7 (0.993, 1.018, 0.977).
None shows the 0–1/7 pattern of a consistent regression. The first service
control command used the invalid workload name `exec`; its error log remains,
and the corrected `executions` run is recorded separately. The harness's
six-win improvement gate is not the independent-control acceptance criterion.

Package inspection v3 matches all 35 functional cases. Fifty inspections per
pair, seven alternating pairs and exact stdout checks record 7/7 wins for a
small package, 256 entries and a package just below 16 MiB: median C++/Zig
ratios 0.645, 0.744 and 0.906 (`plugin-package-v3-timing.json`). These include
CLI process startup and measure inspection, not private copying or plugin work.

The initial integrated service retains the host's 564 exact cases and six
reference crashes. Independent terminal controls against host v5 record
sparse/full/bulk 3/7, 5/7 and 4/7 (1.007, 0.973, 0.979). Service controls
record executions/editor/suggestions 4/7, 2/7 and 6/7 (0.988, 1.045, 0.908).
No control has 0–1 wins, but the editor median is a signal to revisit on the
final implementation. These measurements do not close older performance gaps.

`plugin-service-v6.json` measures capture reconstruction, the actual service
actor, child protocol and Lua worker with 5,000 exchanges per pair and exact
reply checks. All 53 functional cases match. Empty/notification/JSON/256 KiB
record 1/7, 0/7, 0/7 and 0/7 wins at 1.091, 1.065, 1.067 and 1.272.
All four service gates fail despite the earlier isolated-host gains. Sampling
shows worker time in `SessionIo::ready`/`poll` before writes as well as in
`writev`; the large-body sample records 389 and 350 samples respectively.
The retained profiles motivate attempting nonblocking I/O before waiting,
with cheap cancellation/deadline checks on every operation. This proposed
change needs its own validation and paired measurements.

v7 attempts I/O before polling and checks an atomic cancellation flag plus
the deadline before every operation. Release/ASan/UBSan tests and 53 service
cases pass, but all workloads still lose 0/7: 1.073, 1.044, 1.050 and 1.257.
The diagnostic syscall count for 1,000 large exchanges shows 17,997 C++
`writev` calls, 7,997 blocked writes and 10,998 polls; Zig uses 4,000 `writev`
calls, zero blocked writes and 1,111 polls. The hook is diagnostic only.

v8 uses a Unix socket for worker input with bounded 256 KiB send/receive
buffers; stdout and stderr remain pipes. The 256 KiB workload wins 7/7 at
0.840 versus Zig and 0.673 versus v7. Empty/notification/JSON still lose 0/7
versus Zig (1.093, 1.078, 1.073), and the corresponding v7 controls regress
consistently at 1/7, 0/7 and 0/7 (1.012, 1.016, 1.014). Thus v8 is not
accepted as a complete performance improvement. Release runtime/plugin tests
pass; v9 additionally changes result queues to move owned pointers and lets
request queues wake their actor directly, avoiding a second pipe per actor.


## Plugin service follow-up and priority

The service v9 pointer-result queue and direct condition-variable wakeup pass
all 53 functional cases. Against v8, empty/notification/JSON/256 KiB win
6/7, 6/7, 7/7 and 6/7 at 0.9554, 0.9526, 0.9542 and 0.9929. Against Zig,
these record 0/7, 1/7, 0/7 and 7/7 at 1.0524, 1.0167, 1.0227 and 0.8322.

v10 limits collection to one result batch so continuously publishing workers
cannot monopolize the runtime. v11 allocates each encoded frame at its exact
size while retaining the original admission charge. Its shared size/writer
schema removes the unused 64 KiB allocation. Against v10, the four workloads
win 6/7, 5/7, 7/7 and 5/7 at 0.9815, 0.9825, 0.9839 and 0.9847. Against
Zig, they win 1/7, 0/7, 4/7 and 7/7 at 1.0231, 1.0094, 0.9986 and 0.8306.

v12 consumes one bounded pipe notification per result batch instead of draining
and re-notifying. Concurrent publication, full queues and fairness are tested.
Against v11 it wins 4/7, 4/7, 6/7 and 3/7 at 0.9978, 0.9896, 0.9669 and
1.0034. Against Zig it wins 0/7, 3/7, 1/7 and 7/7 at 1.0269, 1.0093,
1.0062 and 0.8437. All 53 functional cases still match. The three small-message
gates remain open. Further plugin optimization is deprioritized by request.
Raw results are `plugin-service-v{9,11,12}{,-paired}.json`.

## Core history and launch diagnostics

`core-v1-terminal.json` establishes the pre-filter/parser baseline: sparse,
full, bulk and scroll win 7/7 each against Zig at 0.5790, 0.7731, 0.8948
and 0.6196. This is a distinct executable from the later core v4 candidate.

Core v4 adds filter admission, signed OSC exit parsing and durable post-spawn
launch diagnostics. Every measured byte stream matches. Seven alternating
pairs in `core-v4-terminal.json` give sparse/full/bulk/scroll 7/7, 7/7, 4/7
and 7/7 at 0.6495, 0.7947, 0.9168 and 0.6427. Bulk does not pass the
six-win rule. Against core v2, the independent sparse/full/bulk controls win
6/7, 4/7 and 2/7 at 0.9785, 0.9942 and 1.0399. The bulk median is an
unresolved regression signal; no unchanged retry replaces these results.

`core-v4-capture.json` passes capture 6/7 and controlled directory changes
7/7, at 0.8779 and 0.8971. `core-v4-history.json` passes the history request
sequence 7/7 at 0.6570. These do not certify the asynchronous real-shell CWD
race, graphics, proxy or remaining whole-runtime performance gaps.

`core-v4-bulk-profile.json` retains two-second samples of core v2 and v4 under
4,000 bulk iterations. Both output digests match. In v4, 236 main-thread
samples descend through the observation enqueue foreground-group ioctl and
149 through terminal feeding. The observation worker already reads native
process identity; Darwin includes the terminal foreground group in that same
result. This motivates a candidate that moves group discovery to the worker,
retaining the current-group check before applying a newly identified process.
Sampled run timings are excluded from acceptance.

## Foreground discovery: bounded acceptance

The native process snapshot now exposes Darwin's `e_tpgid` separately from
process identity. With exactly one active pane, the observation worker uses
that group from its existing process query; multiple panes retain the earlier
main-thread foreground query. Applying a newly identified process still checks
the current PTY group. Native tests exercise an interactive shell, foreground
`cat`, return to the shell and the reaped root.

The unrestricted v1 candidate was rejected: its concurrent mean improved in
7/7 pairs (0.8258), but observed maximum latency regressed in 6/7 (1.1444).
The cause is not established. `foreground-snapshot-v1-acceptance.json` retains
the rejected result.

The single-pane v2 candidate wins bulk 7/7 (0.8278) and full 7/7 (0.9118)
against core v4; sparse is 4/7 (0.9765). Concurrent controls, with 400 iterations
per run, have mean/P50/P95/P99/max wins of 3/4/3/2/5, at ratios
1.0208/0.9875/1.0388/1.0355/0.6234. None consistently loses 0–1/7. The background
volume in that fixture is scheduling dependent, so this is a latency control,
not proof of equal aggregate background work.

`foreground-snapshot-v2-terminal.json` compares the frozen candidate against
Zig for 160 iterations in each of seven alternating pairs. All ten scenarios
have byte-identical terminal output and seven wins: sparse 0.5610, full 0.7233,
scroll 0.5608, unicode 0.5858, modes 0.5609, links 0.6480, colors 0.5283,
mixed 0.5644, bulk 0.7307 and graphemes 0.5994. Release tests pass in 1.54 s
and ASan/UBSan tests in 5.40 s. The frozen binaries, enqueue ARM64 disassembly
and command are under `/tmp/telar-cpp-foreground-snapshot-v2`.

This accepts that foreground optimization on macOS ARM64. It does not close
the proxy, small compressed capture, large path query or other outstanding
performance gates. These figures predate the hook CLI additions below.

## Hook CLI mapping

The hook benchmark includes process startup, JSON input, mapping and IPC to the
same acknowledging fixture server. `measure_hook_cli.py` alternates seven pairs
of 16 invocations, after warmup, and requires identical exit status, stdout,
stderr and protocol frames. Live-pane oracles are separate functional checks.

The initial v7 implementation beats Zig in lifecycle 7/7 (0.8721), command 7/7
(0.8429) and plan 6/7 (0.8746), but the 512 KiB input wins only 4/7 (0.9956).
That last case was not accepted. The two-second mapping sample found 322
samples under repeated dynamic-value validation and 161 under the Unicode
escape scan. Those samples motivated reusing the parsed root and cached field
values rather than scanning the same encoded value again.

The v8 mapping change passes all 324 CLI cases and the five live-pane provider
scenarios. Against v7, large input wins 7/7 at 0.8872; lifecycle wins 7/7 at
0.9664, command 2/7 at 1.0077 and plan 4/7 at 0.9973. No control consistently
loses 0–1/7. Against Zig, all four modes win 7/7: lifecycle 0.8834, command
0.8329, plan 0.8622 and large input 0.8985. The mapping probe's allocator
counters fall from ten allocations per iteration to five, with peak charged
storage decreasing from 525,856 to 525,184 bytes for that input. The profile
run durations are not acceptance measurements. ARM64 constructor disassembly
and exact commands are retained in `/tmp/telar-cpp-hooks-v8`.

The v8 server controls against the accepted foreground v2 binary have bulk
3/7 (1.0168), sparse 3/7 (1.0066) and full 4/7 (0.9841). Concurrent mean/P50/
P95/P99/max wins are 6/5/6/6/4, at ratios 0.9440/0.9723/0.8690/0.8287/0.7811.
Against Zig, all ten terminal cases pass the six-win gate: colors wins 6/7 and
the other nine win 7/7. Ratios range from 0.4135 to 0.6932. Capture wins 7/7
(0.8282); controlled capture with CWD changes wins 6/7 (0.8044). These results
precede the later worktree refusal-diagnostic correction, which is recorded
separately. Earlier proxy, path-query, graphics and compression gates remain
open; no whole-runtime performance guarantee is inferred from the hook results.

The final hook v10 binary includes the worktree diagnostic correction and
embedded-NUL path rejection. Its SHA-256 is
`841c70d4392a77dc57c59c13c43da52334119d54908029145bb5eb7b823abd1e`.
Against Zig, all four hook cases win 7/7: lifecycle 0.8767, command 0.8489,
plan 0.8766 and large input 0.8885. Against v8, wins are 6/5/5/4, with ratios
0.9737/0.9880/0.9835/0.9979. The ten terminal cases all pass: full wins 6/7,
the others 7/7, with ratios from 0.5231 to 0.7293. Capture and capture-CWD both
win 7/7, at 0.8711 and 0.9001.

Controls against foreground v2 have bulk 5/7 (0.9679), sparse 3/7 (1.0073)
and full 4/7 (0.9998). Concurrent mean/P50/P95/P99/max wins are 4/4/4/5/2,
at 0.9994/0.9991/0.9987/0.9343/1.1865. Maximum latency has not improved in
this run; no measured control reaches the 0–1/7 consistent-loss threshold.
`hooks-v10-acceptance.json` records this bounded acceptance. Its terminal and
hook comparisons used frozen binaries without concurrent builds or tests.

## Small gzip and deflate allocation pass

The unchanged decoder v9 binary and matching source hashes form the component
baseline. A fresh valid-body sample records retained-window allocation inside
`inflate`, followed by erasure and release in `inflateEnd`. The SDK's zlib
contract permits `Z_FINISH` to omit that window when the complete stream fits.
The first variant selects it only when the first block carries the final bit;
multiple-block input retains `Z_BLOCK` and its existing truncation boundaries.

`flate-final-v1-oracle.json` passes 3,452 cases. One reference crash remains
separate from equivalence. Against decoder v9, 1 KiB gzip/deflate improve 7/7
at 0.7357/0.7321, without a consistently losing control. Against Zig they
still fail the gate: 1/7 at 1.0520 and 0/7 at 1.1083. This intermediate result
is retained rather than presented as final acceptance.

Variant v2 replaces the small flate output's large heap allocation with the
existing 64 KiB `SensitiveBuffer` and copies only the accepted prefix into the
owned result. The same validation boundary and complete erasure remain.
Against v1, small gzip/deflate improve 7/7 at 0.8567/0.8789. The other six
component controls win 2–6/7, with no consistent loss. Against Zig, gzip and
deflate at 1 KiB each win 6/7, at 0.9303 and 0.9801. Both 256 KiB cases win
7/7 at 0.7161/0.7162. Brotli and Zstd at 1 KiB still lose 0/7, at 1.2512 and
1.2594; their larger cases win 7/7 at 0.9555/0.8485.

An independent allocation diagnostic uses the same valid twelve-byte body
and stack output in both variants. Decoder-state allocations fall from two
to one, with peak charged state storage falling from 39,944 to 7,168 bytes.
Both finish with zero live bytes. These figures exclude output storage.
ARM64 disassembly shows the final-bit test selecting flush values 4/5 before
`inflate`; the small-output function reserves its fixed stack window and keeps
`bzero` on normal and exceptional exits. Exact commands, profiles and listings
are under `/tmp/telar-cpp-flate-final-v1` and `/tmp/telar-cpp-flate-final-v2`.

The integrated v2 runtime has SHA-256
`da7a526ca8ab4e9b75e07a95dd8cd723b1215474905200a807f3c6168a9d1854`.
Against hook v10, terminal bulk/sparse/full controls win 5/2/3 at
0.9923/1.0174/1.0002. Concurrent mean/P50/P95/P99/max win 3/4/3/5/3 at
1.0078/0.9946/1.0013/0.9140/1.3515. Maximum latency remains variable and
does not establish an improvement. Opaque proxy small/large/CONNECT controls
win 4/5/2 at 0.9948/0.9849/1.0175; hook controls win 4/3/4/4. No control
reaches the 0–1/7 consistent-loss threshold.

Against Zig, the final runtime wins all ten terminal modes 7/7, with median
ratios 0.5008–0.7547. Capture and capture-CWD win 7/7 at 0.8965/0.8721.
All four hooks win 7/7, at 0.8304/0.8174/0.8159/0.8478. These measurements
accept the gzip/deflate change and the recorded controls on macOS ARM64.
They do not close the older proxy, graphics, large-path-query or remaining
small-decoder performance gates.

## Static dependency installation

`distribution-v1-*` measures the staged Release executable
`94fccc6c4739fac80ed064c78f7760960a3ea99634cb6628131501a6a9109abc`
against the previous flate v2 C++ binary and the unchanged Zig reference.
OpenSSL 3 and libpng are now static, and the deployment target is explicitly
26.0. All workloads retain equivalent outputs. Builds, tests and profiling
were complete before the seven alternated timing pairs.

| Hook workload | C++ wins vs previous C++ | Median ratio | Wins vs Zig | Median ratio |
| --- | ---: | ---: | ---: | ---: |
| Lifecycle | 7/7 | 0.8943 | 7/7 | 0.7782 |
| Command | 7/7 | 0.8479 | 7/7 | 0.7505 |
| Plan | 7/7 | 0.8813 | 6/7 | 0.7229 |
| 512 KiB input | 7/7 | 0.9263 | 7/7 | 0.8021 |

Terminal controls versus previous C++ win 4/7, 5/7 and 4/7 for bulk, sparse
and full frames, with ratios 0.9809, 0.9943 and 0.9981. Against Zig, all ten
terminal cases pass: graphemes wins 6/7 and the other nine win 7/7. Capture
and capture-CWD pass 6/7 at 0.7180 and 0.9670.

Concurrent controls are less favorable: mean/P50/P95/P99/max win
3/3/2/2/3 pairs, with ratios 1.0357/1.0140/1.1330/1.2168/1.1214.
None reaches the defined 0–1/7 consistent-regression threshold, but these
results do not establish unchanged tail latency. The cause is not established.
Against Zig, mean/P50/P95/P99 win 7/7 and maximum latency wins 4/7.

The three proxy controls each win 4/7 against previous C++: small 0.9764,
large 0.9830 and CONNECT 0.9500. They still fail against Zig, winning
1/7, 1/7 and 2/7 at 1.0471, 1.0553 and 1.0744. This installation work closes
no proxy gate. Brotli/Zstd small bodies and the other previously recorded
component gaps also remain. Commands and logs are retained under
`/tmp/telar-cpp-distribution-v1`; no global performance guarantee is inferred.

## Rejected follow-up experiments

The proxy watch v6 experiment updates only the read or write filter that
changed, preserving re-registration for descriptor/token replacement. Real
kqueue tests cover independent filter changes, stale events and descriptor
reuse; runtime/TLS suites pass. Two-second CONNECT/large-transfer samples of
the frozen distribution binary show registration and relay work. ARM64 output
confirms independent conditional registration in the candidate. This is not
enough to justify keeping the change: against previous C++, CONNECT wins only
2/7 at 1.0459; small/large controls win 5/7 and 3/7 at 0.9601/1.0259. Against
Zig those modes win 2/7, 2/7 and 0/7. Production changes were reverted, while
the independent-filter correctness test remains. Reports are
`proxy-watch-v6-*`; samples, binaries, source variants and disassembly remain
under `/tmp/telar-cpp-proxy-watch-v6`.

The small Zstd v1 experiment uses a fixed 128 KiB erased output window on the
stack and allocates only the returned prefix. It passes 3,452 exact decoder
cases, excluding the separately recorded reference crash. Small Zstd improves
7/7 against previous C++ at 0.966, but remains 0/7 against Zig at 1.285. The
small Brotli control regresses in 6/7 pairs at 1.054. This variant is rejected.

A fresh valid-body sample shows Zstd context release and allocation/erasure
work. The v2 experiment keeps output storage unchanged and supplies a bounded,
aligned 128 KiB workspace to the library's static-context API for small bodies,
falling back to injected allocation if the state does not fit. It also passes
3,452 exact cases, excluding the same reference crash. It regresses small Zstd
in all seven pairs against previous C++ at 1.051 and loses all seven against
Zig at 1.353. This variant is also rejected. Its larger fixed erase window and
extra setup are visible in the source/ARM64 output, but their individual share
of the regression has not been measured.

Both Zstd variants and their lower-heap-budget assertion were removed. The
accepted flate v2 decoder sources are restored byte-for-byte. Reports retain
all eight decoder controls and both reference comparisons in
`small-zstd-v{1,2}-{oracle,paired,zig,decision}.json`. Source variants, valid-body
profile and disassembly remain under `/tmp/telar-cpp-small-zstd-v{1,2}`.


## System trust v2

The frozen Release executable is `/tmp/telar-cpp-system-trust-v2/release/telar-runtime`
(SHA-256 `7a4a6bffb67e6d53372f84816314d3ee081a28a5f5aa338a8701cde032f584d1`).
Source hashes and copies are retained beside it. These measurements precede the
provider-installation implementation.

Against the previous installed C++ build, bulk wins 4/7 (median ratio 0.9875),
sparse 1/7 (1.0067), and full 4/7 (0.9945). The sparse control fails the consistent
regression rule. Its cause has not been established; an initial assembly listing
is not sufficient evidence to attribute the result to code placement.
Proxy latency, throughput and CONNECT win 3/7, 3/7 and 4/7, with median ratios
1.0135, 1.0516 and 0.9877. The throughput report retains a 7.781 outlier.

Against Zig, nine terminal workloads win 7/7 and scrolling wins 6/7. Median
ratios range from 0.5303 to 0.7387. All exact terminal results match.
Proxy latency, throughput and CONNECT each win only 2/7, with median ratios
1.0322, 1.0231 and 1.3944. Proxy performance acceptance remains failed.
Reports are `system-trust-v2-{terminal,proxy-latency,proxy-throughput,proxy-connect}-{paired,zig}.json`.

## Integration CLI and CWD ordering

`integration-v2-cli-zig.json` measures a fresh provider installation, including
process startup, settings/extension publication and both bundled skills. Each
case checks normalized outputs and file contents outside the timed region.
All five providers win 7/7 paired comparisons against Zig: Claude 0.823, Codex
0.776, Cursor 0.771, Pi 0.773 and OpenCode 0.793. These are median C++/Zig ratios
for 16 installations per pair. The same executable's terminal controls against
the prior C++ runtime are mixed: bulk 4/7 at 0.968, sparse 2/7 at 1.019 and full
3/7 at 1.002 (`integration-v2-terminal-paired.json`).

The subsequent CWD-ordering binary is frozen under `/tmp/telar-cpp-cwd-v1`.
Against the integration binary, bulk/sparse/full controls win 3/7, 6/7 and 4/7
at 1.016, 0.973 and 0.991. All ten terminal scenarios win 7/7 against Zig,
with median ratios from 0.480 to 0.740. The opaque proxy latency case still
fails its gate: 1/7 at 1.0435 for 10,000 round trips per pair. Reports are
`cwd-v1-terminal-{paired,zig}.json` and `cwd-v1-proxy-latency-zig.json`.
The earlier proxy and component performance gaps remain; these measurements
do not establish an overall performance guarantee.
No builds, tests or profiles ran concurrently with timing. These results do not
certify later binaries or equal-or-better performance for the complete runtime.

## Compiled-out telemetry and screen fixes

The default Release telemetry binary is frozen under `/tmp/telar-cpp-telemetry-v3`.
Its bulk/sparse/full controls against the CWD binary win 4/7 each, with median
ratios 0.975, 0.990 and 0.979. These mixed controls do not prove an improvement.
All ten terminal scenarios win 7/7 against Zig, with median ratios from 0.508
to 0.750. Reports: `telemetry-v3-terminal-{paired,zig}.json`. Detailed runtime
metrics are compiled out of this binary; this result does not measure the
Debug or Release-opt-in instrumentation cost.

The subsequent screen fixes are frozen under `/tmp/telar-cpp-screen-v2`.
`screens-v2-zig.json` retains seven alternated pairs of 20 provider cycles each.
Exact protocol snapshots match in every pair. Claude wins 2/7 at median
1.0232, Codex 3/7 at 1.0041 and Cursor 7/7 at 0.9444. Claude and Codex therefore
fail acceptance. The fixture includes one-millisecond state-query polling;
these numbers measure the complete interaction, not only scanner execution.
No builds, tests or profiles ran concurrently with these measurements.

## Degraded history and SQLite diagnostics

The history v3 binary (before the later disconnected-import fix) wins 7/7
against Zig in all ten terminal workloads, with median C++/Zig ratios between
0.506 and 0.728. Against the screen-v2 C++ binary, bulk/sparse/full controls
win 3/7, 5/7 and 3/7 at median ratios 1.010, 0.937 and 1.009. No consistent
regression or improvement is established by these controls. Reports are
`history-v3-terminal-{paired,zig}.json`; no tests, builds or profiles overlapped
timing. These results do not certify the subsequent history v4 binary or the
remaining proxy, graphics, decoder, path-query and screen-performance gates.

## Fuzzy alignment bounds

A three-second sample of the history-v4 binary places 1,795 top-of-stack samples
in `FuzzyMatch::score` and 281 in `PathIndex::queryPublished`. The baseline
already wins 7/7 against Zig for the longer 1,000-query workload; that result
is retained separately and is not attributed to this change.

The candidate records each earliest prefix match during the existing
subsequence scan. Alignment rows start there and stop while sufficient bytes
remain for later query characters. This removes unreachable work without
changing scores, highlighting, matrix ownership or heap allocation count.
ARM64 disassembly shows the earliest-column `ldrh` and the row-specific upper
bound replacing full-width loops. Source, binaries, assembly and the earlier
profile are preserved under `/tmp/telar-cpp-fuzzy-bounds-v1` and
`/tmp/telar-cpp-paths-profile-v1`.

Seven alternated pairs produce exact responses throughout:

| Workload | Compared with | Wins | Median ratio |
| --- | --- | ---: | ---: |
| 4,129 entries, 1,000 queries | Prior C++ | 7/7 | 0.7632 |
| 4,129 entries, 1,000 queries | Zig | 7/7 | 0.6770 |
| 4,129 entries, 120 queries | Zig | 7/7 | 0.8670 |
| Small path control | Prior C++ | 4/7 | 0.9965 |
| Bulk terminal control | Prior C++ | 4/7 | 0.9703 |
| Sparse terminal control | Prior C++ | 3/7 | 1.0057 |
| Full terminal control | Prior C++ | 4/7 | 0.9886 |

All ten terminal cases win 7/7 against Zig, at median ratios 0.513–0.724.
No builds, tests or profiles overlapped timing. The actual Zig matcher agrees
on 24,971 score/highlight cases, and 12,000 baseline cases also agree under
ASan/UBSan. The candidate is accepted for macOS ARM64. Reports retain every
pair in `fuzzy-bounds-v1-{paired,zig,cold-zig,small-paired,terminal-paired,terminal-zig}.json`
and the acceptance criteria in `fuzzy-bounds-v1-decision.json`.

## Media diagnostics controls

The `/tmp/telar-cpp-media-telemetry-v1/release/telar-runtime` binary adds Debug
media/graphics/process counters. Seven alternated pairs of 40 image generations
use identical pixels and protocol results. Compared with fuzzy-bounds v1, direct
images win 4/7 at 0.9386, shared images 3/7 at 1.0339 and atomic file/shared images
5/7 at 0.9597. These controls are mixed. Against Zig, direct and shared images
win 7/7 at 0.7304 and 0.7565; atomic file/shared images remain below acceptance
at 3/7 and 1.0100. Reports are `media-telemetry-v1-{paired,zig}.json`.

## Bounded storage for complete Zstd frames

Small complete Zstd frames now use their declared output size as the physical
allocation bound after checking that the input contains exactly one complete
frame. Unknown sizes, concatenated frames and incomplete input retain the prior
capacity. The decoder still uses the reference's 128 KiB logical validation
boundary and erases every byte of allocated output and decoder state.

The actual-Zig oracle passes 3,662 cases, including 210 added combinations of
false/true content-size declarations and output limits. The previously recorded
reference crash remains excluded and retained separately. Release and ASan/UBSan
runtime suites pass, including injected allocation failure and erasure checks;
a small Zstd body now succeeds under a 128 KiB heap budget. Seven touched headers
compile independently. A test-only narrowing error was corrected before these
checks completed.

ARM64 inspection retains separate physical and logical capacities. The new
path calls `ZSTD_getFrameContentSize` and `ZSTD_findFrameCompressedSize` before
selecting the allocation size; the decoded prefix and validation policy are
unchanged. The prior valid-body profile identified allocation/erasure work.
The frozen source, binaries and 332/347-line before/after function disassemblies
are under `/tmp/telar-cpp-zstd-capacity-v1`.

| Decoder workload | Wins vs previous C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| gzip-1024 | 4/7 | 0.9998 | 7/7 | 0.9349 |
| gzip-262144 | 5/7 | 0.9963 | 7/7 | 0.7184 |
| deflate-1024 | 4/7 | 0.9969 | 7/7 | 0.9226 |
| deflate-262144 | 2/7 | 1.0008 | 7/7 | 0.7091 |
| br-1024 | 6/7 | 0.9591 | 0/7 | 1.2787 |
| br-262144 | 5/7 | 0.9911 | 7/7 | 0.9673 |
| zstd-1024 | 7/7 | 0.4833 | 7/7 | 0.6341 |
| zstd-262144 | 4/7 | 0.9920 | 6/7 | 0.8579 |

Whole-binary controls against fuzzy-bounds v1 also include the intervening
telemetry and identity fixes. bulk wins 3/7 at 1.0004, sparse wins 2/7 at 1.0208, full wins 4/7 at 0.9925. All ten terminal modes win 7/7 against Zig;
the 1,000-query large-path workload wins 7/7 at 0.6849.
The Zstd change is accepted. Small Brotli still fails, and the remaining proxy,
graphics and latency gates are separate unfinished work. All results and the
decision are retained in `zstd-capacity-v1-*.json`.

## Bounded Brotli scratch allocation

The valid-body profile identifies decoder allocations and erasure alongside Brotli
processing. An injected buffer allocator now serves decoder allocations from a
32 KiB local buffer, falling back to the original injected allocator when full.
Every block is still erased when released. The same 1 KiB fixture reduces heap
allocations from eleven to one; output ownership is unchanged.

ARM64 inspection confirms that the dedicated decoder function reserves the
32 KiB stack buffer and destroys decoder state before returning. Other decoders
do not reserve that buffer. Source, binaries, allocation traces and assembly are
frozen under `/tmp/telar-cpp-brotli-buffer-v1`. Release and ASan/UBSan tests pass,
including alignment, bounded allocation failure and immediate erasure. The actual
Zig oracle passes 3,662 cases with the same single excluded reference crash.

| Decoder workload | Wins vs previous C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| gzip-1024 | 4/7 | 0.9901 | 7/7 | 0.9405 |
| gzip-262144 | 5/7 | 0.9974 | 7/7 | 0.7182 |
| deflate-1024 | 6/7 | 0.9937 | 7/7 | 0.9408 |
| deflate-262144 | 2/7 | 1.0055 | 7/7 | 0.7156 |
| br-1024 | 7/7 | 0.8394 | 0/7 | 1.0400 |
| br-262144 | 2/7 | 1.0044 | 6/7 | 0.9762 |
| zstd-1024 | 2/7 | 1.0175 | 7/7 | 0.6200 |
| zstd-262144 | 2/7 | 1.0035 | 6/7 | 0.8684 |

The small Brotli change is retained as an incremental improvement; it still
fails the final Zig performance requirement. No decoder or terminal control
has zero or one win against the preceding C++ binary. All ten terminal cases
win 7/7 against Zig. Opaque proxy latency and throughput win 0/7, and CONNECT
wins 4/7; those independent gates remain open. Reports and the explicit
non-parity decision are retained in `brotli-buffer-v1-*.json`.

## History ordering and immediate admission replies

The history-queue v3 binary includes the supersession and import-admission fixes.
Release and ASan/UBSan behavior matches the locked-database reference fixtures.
Seven paired controls against Brotli-buffer v1 yield:

| Terminal control | Wins vs prior C++ | Median ratio |
|---|---:|---:|
| bulk | 2/7 | 1.0067 |
| sparse | 2/7 | 1.0589 |
| full | 2/7 | 1.0097 |

Controls are mixed and do not establish an improvement. All ten terminal
modes win 7/7 against Zig, at median ratios 0.4944–0.7320. The history
fixture wins 7/7 at 0.5960; it includes import, pagination, fuzzy/distinct
query, stats, output, deletion and pruning, with exact protocol replies. No
builds, tests or profiles overlapped timing. Remaining decoder/proxy/graphics
and latency gates are not certified by this result.

## Connected socket I/O

The history-queue v3 profiles place proxy-thread work in readiness waits and
socket I/O: latency has 1,806 worker `kevent` samples, 295 `sendto` and 221
`recvfrom` top-of-stack samples. Connected stream reads/writes now use POSIX
`read`/`write`; peeking retains `recv(MSG_PEEK)`. Nonblocking/error/EOF behavior,
partial-write ownership and the existing `SO_NOSIGPIPE` setup are unchanged.
The relay's ARM64 listing calls the `_read`/`_write` stubs with three arguments
instead of the four-argument `_recv`/`_send` stubs, with no new allocation.

Release and ASan/UBSan runtime and TLS suites pass, including backpressure,
half-close, failed peers and independent readiness. A standalone header check
passes. Exact payloads and protocol responses match in all paired workloads.

| Proxy workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| proxy-latency | 3/7 | 1.0154 | 2/7 | 1.0224 |
| proxy-throughput | 7/7 | 0.9640 | 2/7 | 1.0309 |
| proxy-connect | 5/7 | 0.9786 | 1/7 | 1.2761 |

The throughput improvement is retained. Terminal controls against prior C++
win 3/7, 3/7 and 4/7; all ten terminal modes win 7/7 against Zig. This does
not establish overall proxy parity. CONNECT is particularly variable, with
C++/Zig ratios from 0.802 to 2.459; the cause is not established. No builds,
tests or profiles overlapped timing. Frozen sources, binaries, profiles and
assembly are under `/tmp/telar-cpp-proxy-io-v1`, and every pair is retained in
`proxy-io-v1-*.json`.

## Rejected paired readiness registration

The proxy-interest v1 experiment submitted the read and write filter changes
in one immediate `kevent` call. ARM64 inspection confirms one registration call
with two changes, and Release runtime/TLS tests pass. CONNECT nevertheless
wins only 3/7 against proxy-I/O v1 at median 1.0792. Small and large relay
controls win 4/7 and 2/7; against Zig CONNECT wins 0/7, latency 1/7 and large
relay 2/7. The target does not demonstrate an improvement, so all production
changes were reverted. The closed-descriptor rejection regression remains.
Profiles, source, binaries and assembly are under `/tmp/telar-cpp-proxy-interest-v1`;
`proxy-interest-v1-*.json` retains every pair and the rejection.

## History queue capacity correction

The history-capacity v1 binary separates pending requests, the active batch and
bounded replies. Frozen source and binaries are under
`/tmp/telar-cpp-history-capacity-v1`. Release, ASan/UBSan and focused TSan checks
pass, as do exact saturation, supersession, admission and disconnect/restart
fixtures. This is a compatibility correction, without a claimed speed gain.

| Control | Wins vs proxy-I/O v1 | Median ratio |
|---|---:|---:|
| history | 2/7 | 1.0171 |
| bulk | 2/7 | 1.0038 |
| sparse | 4/7 | 0.9965 |
| full | 2/7 | 1.0044 |

The history fixture wins 7/7 against Zig at 0.5933. All ten terminal modes
win 7/7 against Zig, with median ratios 0.4956–0.7744. The history fixture
executes a fixed twelve-request sequence, not a sustained queue throughput
benchmark. No builds, tests or profiles overlapped timing. The outstanding
proxy, decoder, graphics and latency gates remain open; these results do not
establish full runtime performance parity.

## Opaque relay buffer capacity

The proxy-buffer v1 opaque tunnel uses compile-time 32 KiB buffers per
direction, while TLS/HTTP relays retain 16 KiB. Each dispatch still moves at
most 128 KiB per direction. An instrumented 1,000-transfer diagnostic reduces
process read calls from 10,399 to 6,217 and write calls from 8,353 to 4,197;
these counts include 32 warmup transfers and runtime housekeeping. Payload
digests match. Instrumentation is excluded from timing.

The tunnel object grows from 32,840 to 65,608 bytes, charged to the injected
allocator: 32 KiB extra per opaque connection, or 8 MiB at the 256-connection
limit. No allocation is added to the relay loop. ARM64 inspection confirms
the 32 KiB read bound. Release and ASan/UBSan runtime/TLS tests pass, including
both capacities, partial writes, half-close, failed peers and the dispatch
bound. All five affected headers compile independently.

| Proxy workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| throughput | 6/7 | 0.9770 | 5/7 | 0.9983 |
| latency | 2/7 | 1.0279 | 4/7 | 0.9994 |
| CONNECT | 2/7 | 1.0441 | 2/7 | 1.0639 |

The throughput improvement is retained. Latency and CONNECT do not meet the
six-loss control threshold, but their median regressions against prior C++
remain recorded with cause not established. Terminal controls win 3/7, 3/7
and 4/7 against prior C++; all ten terminal modes win 7/7 against Zig. The
three final proxy gates remain open. All pairs, including the 0.132 throughput
outlier against Zig, are retained in `proxy-buffer-v1-*.json`. Binaries,
source, syscall instrumentation, object sizes and assembly are frozen under
`/tmp/telar-cpp-proxy-buffer-v1`.

## Pane input saturation correction

Input-capacity v1 preserves input admission boundaries and the reference's
resource-limit responses. Release and ASan/UBSan socket, runtime and diagnostics
checks pass. Frozen source/binaries are in `/tmp/telar-cpp-input-capacity-v1`.
This is a functional correction, with no speed improvement claimed.

| Terminal control | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| bulk | 5/7 | 0.9859 | 7/7 | 0.7336 |
| sparse | 3/7 | 1.0159 | 7/7 | 0.5572 |
| full | 1/7 | 1.0047 | 7/7 | 0.7271 |

All ten terminal modes win 7/7 against Zig, with medians 0.5239–0.7336.
The full-screen control consistently loses against the preceding C++ build;
its cause is not established. The separate input-layout experiment investigates
the location of the new limit ledger in the runtime model. No builds, tests or
profiles overlapped timing. The saturation fixture deliberately blocks a child
and measures functional behavior only.

The input-layout v1 experiment moved the 53,288-byte limit state to the end of
the model, restoring the earlier offsets of the other fields. Full-screen
wins only 3/7 at median 1.0150; bulk 3/7 and sparse 5/7. It is rejected and
the input-capacity v1 layout restored. Complete ARM64 publication listings,
field offsets and the rejected binary are under `/tmp/telar-cpp-input-layout-v1`.
The earlier full-screen regression against C++ remains unexplained.

## Graphics storage diagnostics

Graphics-storage v1 adds Debug storage gauges without changing the Release
text section: 5,341,532 bytes at address 0x100002580 and file offset 9,600 are
identical to input-capacity v1. SHA-256:
`6e9c8c293c295ce36ed5bdcb2fb6df3dc16534f4bfee6f4e1127e4c961ac6a0a`.
This checks code and placement, without claiming a new timing result. The
previous terminal results and outstanding runtime gates remain applicable.
Sources, binaries and the section comparison are frozen in
`/tmp/telar-cpp-graphics-storage-v1`.

## Rejected 64 KiB opaque relay buffers

Proxy-buffer v2 reduces instrumented read/write counts from 6,224/4,207 to
4,145/2,197 for the fixed large-payload diagnostic. Exact payloads match;
Release and ASan/UBSan runtime/TLS tests pass. The object grows from 65,608 to
131,144 bytes, adding 16 MiB at the 256-connection cap. ARM64 listings confirm
the read bound; the dispatch budget remains 128 KiB per direction.

| Proxy workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| throughput | 1/7 | 1.0172 | 6/7 | 0.9338 |
| latency | 6/7 | 0.9946 | 0/7 | 1.0422 |
| connect | 6/7 | 0.9570 | 2/7 | 1.0491 |

The throughput target fails the six-of-seven criterion against prior C++.
The variant is rejected and 32 KiB restored. The full measurements, including
outliers, remain in `proxy-buffer-v2-*.json`; source, binaries, syscall counts
and assembly are in `/tmp/telar-cpp-proxy-buffer-v2`. No builds, profiles or
tests overlapped timing. All ten terminal modes win seven pairs against Zig,
but that does not override the failed proxy gates.

## Command-capture diagnostics

Command-telemetry v1 leaves the complete Release executable byte-identical to
graphics-storage v1: SHA-256
`8f399281d4a6a867ea6128cab906c5f1a67b2c0f64b92110e774ff28ede6fc24`.
No timing rerun is claimed. Debug marker, submission, capture and completion
reason counters pass unit and live-shell checks under ASan/UBSan. Sources and
binaries are frozen in `/tmp/telar-cpp-command-telemetry-v1`.

## VT storage diagnostics

VT-storage v2 exposes page allocation through libghostty-vt and samples it only
in Debug. Release and ASan/UBSan tests pass, as do 60 filtered libghostty Debug
tests. The rebuilt dependency changes the Release binary; fresh paired timings
use frozen binaries under `/tmp/telar-cpp-vt-storage-v2`.

| Terminal control | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| bulk | 4/7 | 0.9901 | 7/7 | 0.7197 |
| sparse | 2/7 | 1.0495 | 7/7 | 0.5636 |
| full | 2/7 | 1.0159 | 7/7 | 0.7363 |

All ten terminal workloads win 7/7 against Zig; median ratios range from
0.5229 to 0.7363. Sparse/full controls regress against the preceding C++ build,
with cause not established. This is a diagnostic feature, with no speed
improvement or complete-runtime acceptance claimed. No builds, tests or
profiles overlapped timing.

The subsequent Brotli investigation has not changed the decoder. An eight-second
sample of the accepted buffered decoder records 2,372 top-of-stack samples in
SafeProcessCommands, 1,485 in platform memset and 760 in ReadHuffmanCode. Raw
profile and driver are under `/tmp/telar-cpp-brotli-profile-v2`. These sample
counts are diagnostic evidence, not paired performance results; secure erasure
remains unchanged.

## PTY response capacity correction

PTY-responses v2 replaces separate byte buffers with one bounded message queue
shared by ordinary VT and graphics producers. It preserves partial writes and
drops rejected messages without failing ingestion. The reference queue oracle,
real PTY saturation fixture, Release/ASan/UBSan suites and focused two-producer
ThreadSanitizer check pass. This is a functional correction, with no speed
improvement claimed.

| Workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| terminal bulk | 3/7 | 1.0244 | 7/7 | 0.7845 |
| terminal sparse | 3/7 | 1.0077 | 7/7 | 0.5091 |
| terminal full | 5/7 | 0.9984 | 7/7 | 0.7179 |
| graphics direct | 2/7 | 1.0208 | 7/7 | 0.7434 |
| graphics shared | 4/7 | 0.9915 | 7/7 | 0.7477 |
| graphics atomic file/shared | 5/7 | 0.9908 | 2/7 | 1.0347 |

All ten terminal workloads win 7/7 against Zig, with median ratios
0.5091–0.7845. Control median regressions in bulk, sparse and direct graphics
have cause not established. Atomic file/shared graphics and existing broader
gates remain open. All pairs, including its 1.426 outlier, are retained. No
builds, tests or profiles overlapped timing. Sources, binaries and the direct
oracle are frozen under `/tmp/telar-cpp-pty-responses-v2`. The live saturation
fixture includes deliberate waits and is used only for functional equivalence.

## Rejected full-buffer prefault

An eight-second diagnostic sample of 5,000 atomic file/shared transfers records
262 top-of-stack samples in pread and 109 in open. Raw data is under
`/tmp/telar-cpp-atomic-profile-v1`; its elapsed time is not a paired result.

Atomic-prefault v1 zeroed the destination before pread to resolve write faults
first. Release and ASan/UBSan unit tests, four exact atomic protocol oracles and
the standalone header pass. The target wins only 4/7 against prior C++ and 3/7
against Zig, so the change is rejected and removed. Full pairs and decision are
in `atomic-prefault-v1-*.json`; source/binaries and ARM64 listings remain under
`/tmp/telar-cpp-atomic-prefault-v1`. A separate variant touches one byte per OS
page, avoiding the extra full-buffer write; its rejection follows below.

The one-byte-per-page variant (`atomic-prefault-v2`) is also rejected. The
atomic file/shared target wins 5/7 against accepted C++ (median 0.986104) and
3/7 against Zig (1.065251). The full-screen control loses 7/7 against C++
(1.020314); its cause is not established. Release and ASan/UBSan tests, the
four atomic functional oracles and the standalone header pass. All pairs,
including outliers, remain in `atomic-prefault-v2-*.json`. Production source
is restored to pty-responses v2; no prefault optimization is retained.

## Media-boundary staging

Graphics-staging v1 separates reservation of a transfer from socket publication.
The runtime reserves at the completed media-batch boundary, as Zig does, and
can send the owned generation while the worker replaces live storage. This is
a functional parity correction; performance acceptance remains open.

| Workload | Wins vs preceding C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| graphics-file-atomic-shared | 0/7 | 1.043218 | 2/7 | 1.026693 |
| graphics-file-atomic | 3/7 | 1.003131 | 5/7 | 0.978838 |
| graphics-shm-atomic-shared | 4/7 | 0.997740 | 7/7 | 0.947304 |
| graphics-shm-atomic | 5/7 | 0.980433 | 7/7 | 0.885097 |
| graphics | 6/7 | 0.984886 | 7/7 | 0.723395 |
| graphics-shared | 4/7 | 0.991551 | 7/7 | 0.702446 |
| graphics-file | 5/7 | 0.988099 | 6/7 | 0.925290 |
| graphics-file-shared | 3/7 | 1.028120 | 7/7 | 0.976471 |
| graphics-shm | 3/7 | 1.000930 | 6/7 | 0.902573 |
| graphics-shm-shared | 5/7 | 0.978165 | 7/7 | 0.928830 |
| terminal bulk | 2/7 | 1.021300 | 7/7 | 0.729333 |
| terminal sparse | 4/7 | 0.989388 | 7/7 | 0.552844 |
| terminal full | 5/7 | 0.992710 | 7/7 | 0.735258 |

The atomic file/shared regression versus preceding C++ is consistent: zero
wins, median 1.043218. Its cause is not established. Bulk and file/shared
control median regressions also have cause not established. All ten terminal
modes win 7/7 against Zig, at median ratios 0.521402–0.735258. The two atomic
file output modes fail the graphics gate. All pairs and outliers are retained;
no builds, tests or profiles overlapped these timings.

The v2 construction experiment removes the full temporary-placement memcpy
and reduces the stage function's ARM64 stack allocation from 0x2930 to 0xb0
bytes. It does not establish an end-to-end improvement: atomic file/shared
wins only 3/7 against staging v1, and the bulk control wins only 1/7 against
the preceding accepted C++ binary. It is rejected and staging v1 restored.
The restored Release executable is byte-identical to the measured v1 binary;
the restored ASan text section and placement are also identical. No timing
rerun is claimed for restoration or the later test-only v3 concurrency checks.

Sources, binaries, ARM64 listings, decisions and full measurements remain under
`/tmp/telar-cpp-graphics-staging-v1`, `/tmp/telar-cpp-graphics-staging-v2` and
`measurements/experiments/graphics-staging-v*-*.json`. The final whole-runtime
performance claim remains open.

## Bounded client response delivery

Response-queue v2 adds the 128-pending-response bound, delivery priorities,
notification confirmation reservation and reference overflow policies. Its queue
oracle compares 496,473 operations with the actual Zig ResponseQueue. Release,
ASan/UBSan and live saturation/recovery checks pass. The initial v1 command
forwarding overflow incorrectly closed the recipient; v2 fixes that policy.

The final v2 executable is `2935dfb2c7c8438b9b22c388cfcd1f79971774fb7283488afae65d5807351504`.
Prior C++ below is graphics-staging v1, the preceding functional baseline.
It already has an open performance gate; it is not a fully accepted replacement.

| Workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| response-roundtrip | 2/7 | 1.002214 | 7/7 | 0.650669 |
| sparse | 6/7 | 0.777882 | 7/7 | 0.546967 |
| full | 4/7 | 0.994238 | 7/7 | 0.727351 |
| scroll | 2/7 | 1.005482 | 7/7 | 0.568010 |
| unicode | 4/7 | 0.994923 | 7/7 | 0.558258 |
| modes | 3/7 | 1.014902 | 7/7 | 0.500066 |
| links | 2/7 | 1.018211 | 7/7 | 0.668940 |
| colors | 4/7 | 0.989775 | 7/7 | 0.540005 |
| mixed | 2/7 | 1.017129 | 7/7 | 0.570825 |
| bulk | 2/7 | 1.008695 | 7/7 | 0.755845 |
| graphemes | 4/7 | 0.987719 | 7/7 | 0.592403 |
| graphics | 3/7 | 1.003493 | 7/7 | 0.735175 |
| graphics-shared | 1/7 | 1.018303 | 7/7 | 0.739477 |
| graphics-file | 5/7 | 0.992457 | 5/7 | 0.931694 |
| graphics-file-shared | 4/7 | 0.987539 | 6/7 | 0.941736 |
| graphics-shm | 2/7 | 1.020049 | 7/7 | 0.928412 |
| graphics-shm-shared | 3/7 | 1.005409 | 7/7 | 0.909205 |
| graphics-file-atomic | 2/7 | 1.001833 | 7/7 | 0.963778 |
| graphics-file-atomic-shared | 4/7 | 0.997651 | 4/7 | 0.973305 |
| graphics-shm-atomic | 2/7 | 1.012878 | 7/7 | 0.876266 |
| graphics-shm-atomic-shared | 5/7 | 0.971171 | 7/7 | 0.946204 |

All ten terminal workloads and the unsaturated notification roundtrip win 7/7
against Zig. Graphics-file wins only 5/7 and atomic file/shared 4/7, so their
six-of-seven gates remain open even though their median ratios are below one.
Against preceding C++, shared graphics wins only 1/7 with median 1.018303.
Other control median regressions and this shared regression have cause not
established. This functional correction is retained; no speed improvement or
whole-runtime acceptance is claimed.

ARM64 selection uses `rbit`/`clz` over the pending-lane mask. The normal head
path consumes bytes; out-of-order removal uses memmove over the retained suffix.
The current writer batches contiguous frames only within the same lane.
Listings and immutable source/binary manifests are under
`/tmp/telar-cpp-response-queue-v2`. All pairs and outliers remain in
`response-queue-v2-*.json`. No builds, tests or profiles overlapped timing.

The superseded v1 executable measured 7/7 terminal and notification wins against
Zig, but atomic file/shared won only 1/7 with median 1.032008. Its notification
roundtrip versus prior C++ won 2/7 with median 1.001135. Those results remain
under `response-queue-v1-*.json`; they do not replace the corrected v2 results.

## Rejected mixed-priority batching

Response-queue v3 tried to batch contiguous frames across priority lanes when
their order matched the current pending-lane order. The corrected variant
preserves the FIFO order within each lane, including earlier frames skipped
before a higher-priority response. Its first version violated that rule; the
randomized partial-write test caught it. Initial source and failure logs remain.

The corrected variant passes Release and ASan/UBSan tests, the same 496,473
operations against Zig, standalone-header compilation and live saturation and
graphics checks. A mixed-lane fixture can prepare five messages in one write.
ARM64 prepare stack space grows from 0x50 to 0x60 bytes.

| Workload | Wins vs retained v2 | Median ratio |
|---|---:|---:|
| graphics-shared | 2/7 | 1.003210 |
| graphics | 4/7 | 0.995527 |
| graphics-file-atomic-shared | 5/7 | 0.971827 |
| bulk | 4/7 | 0.971047 |
| sparse | 4/7 | 0.981150 |
| full | 4/7 | 0.999665 |
| response-roundtrip | 3/7 | 1.002104 |

The shared-graphics target wins only 2/7, so v3 is rejected. Reducing writes in
a fixture does not establish a runtime improvement. V2 is restored; its measured
regressions and open graphics gates remain. No builds, tests or profiles
overlapped paired timing, and all pairs are retained.

The preceding eight-second sample of v2, taken during 20,000 shared graphics
transfers, includes 19 samples in the client socket write and two in its queue
prepare path. It does not establish the cause of the shared-graphics regression.
The driver completed normally. Raw profile, logs and driver are under
`/tmp/telar-cpp-response-queue-profile-v1`; the profile is not a paired timing.
The experiment, listings and decision are under `/tmp/telar-cpp-response-queue-v3`
and `response-queue-v3-*.json`.

After rejecting v3, v2 production source and tests are restored. The rebuilt
Release executable is byte-identical to the measured v2 binary. ASan's text
section, address and offset match the frozen v2 binary; its whole-file hash
changes on relink. Release/ASan runtime and diagnostic suites pass after
restoration. Actual Desktop connection, screen and reconnect flows match Zig
with sh, bash and zsh in both builds. These are functional checks, with no
new timing claim for the restored binaries.

## Deferred response projection

The runtime retains typed ReadPane, RequestTabSnapshot,
RequestWorkspaceSnapshot and QueryLimits requests until the writer selects
one. A constrained template encoder projects the current stores at that point.
The allocator-injected metadata queue records positions between encoded frames;
there are no internal placeholder bytes in the protocol buffer. Deferred and
encoded replies share the 128-response bound and FIFO management order.
Started frames remain immutable across short or blocked writes.

The previous response-queue-v2 build fails the blocked-client current-state
fixture. The corrected build matches Zig for changed text, added panes, renamed
tabs/workspaces and newly recorded limits; queued reads also follow pane exit,
and a closed workspace returns the reference failure without disconnecting.
Unit tests cover stale generations, exited-text eviction and allocation failure;
20,000 randomized operations mix deferred/encoded replies, priorities and
partial/zero-byte writes. The existing actual-Zig queue oracle still matches
496,473 operations. Release/ASan runtime and diagnostic suites, ten standalone
headers and actual Desktop lifecycle/reconnect with sh/bash/zsh pass.

The first ASan socket comparison exposed a fixture race: the long child basename
could change from its launch name to macOS's abbreviated process name before
snapshot delivery. Both binaries and mismatching bytes remain. The fixture now
uses `deferred-probe`; three alternated pairs of each blocked-state scenario
match in Release and ASan. Only limit timestamps are normalized. Debug tracing
records 13 `runtime.projectResponse` scopes on the runtime thread, with no drops
and a mode-0600 trace. Production runtime binaries are unchanged by this fixture
rename.

Seven alternated pairs use frozen response-queue-v2 as preceding C++ (already
performance-open) and the frozen Zig reference. Ratios below one favor the new
C++ binary. No builds, tests or profiles overlap timing.

| Workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| deferred-roundtrip | 7/7 | 0.963232 | 7/7 | 0.715528 |
| response-roundtrip | 6/7 | 0.996214 | 7/7 | 0.639698 |
| sparse | 3/7 | 1.011811 | 7/7 | 0.540345 |
| full | 5/7 | 0.984928 | 7/7 | 0.719590 |
| scroll | 4/7 | 0.987078 | 7/7 | 0.568392 |
| unicode | 3/7 | 1.001545 | 7/7 | 0.581238 |
| modes | 3/7 | 1.000774 | 7/7 | 0.577508 |
| links | 4/7 | 0.962144 | 7/7 | 0.654686 |
| colors | 1/7 | 1.080841 | 7/7 | 0.527910 |
| mixed | 4/7 | 0.997967 | 7/7 | 0.565501 |
| bulk | 5/7 | 0.993016 | 7/7 | 0.754993 |
| graphemes | 5/7 | 0.986366 | 7/7 | 0.596700 |
| graphics | 4/7 | 0.998016 | 7/7 | 0.748470 |
| graphics-shared | 4/7 | 0.996426 | 7/7 | 0.739948 |
| graphics-file | 5/7 | 0.970574 | 5/7 | 0.928963 |
| graphics-file-shared | 3/7 | 1.000524 | 6/7 | 0.962983 |
| graphics-shm | 3/7 | 1.009523 | 7/7 | 0.918654 |
| graphics-shm-shared | 4/7 | 0.993533 | 7/7 | 0.948169 |
| graphics-file-atomic | 2/7 | 1.010750 | 5/7 | 0.973100 |
| graphics-file-atomic-shared | 1/7 | 1.014643 | 2/7 | 1.009898 |
| graphics-shm-atomic | 3/7 | 1.007162 | 7/7 | 0.871721 |
| graphics-shm-atomic-shared | 2/7 | 1.004772 | 7/7 | 0.937163 |

Deferred query roundtrips win 7/7 against both references. All ten terminal
workloads and notification roundtrips win 7/7 against Zig. Graphics-file and
atomic file each win only 5/7; atomic file/shared wins 2/7, median 1.009898.
Against preceding C++, colors wins 1/7 (1.080841) and atomic file/shared wins
1/7 (1.014643). Other control ratios above one remain recorded in the table.
This functional correction is retained; these regressions prevent accepting
it as an optimization or claiming whole-runtime performance parity.

An eight-second sample during 500,000 color iterations includes seven samples
in queue preparation and five in queue consumption; screen refresh dominates
those paths in the sample. This does not establish the cause of the regression.
The probe finishes normally. Profile, logs and driver remain in
`/tmp/telar-cpp-deferred-colors-profile-v1`. ARM64 queue prepare retains an
80-byte stack frame and `rbit`/`clz` priority selection. Request metadata adds
bounded work while deferred responses exist; insertion/removal may move the
retained encoded suffix. Sources, executables and assembly are frozen under
`/tmp/telar-cpp-deferred-responses-v2`. All raw pairs and validation evidence
are in `deferred-responses-v2-*.json`; the initial fixture failure is preserved
in `deferred-responses-v1-asan.json`.

## Current-state delivery and attachment rotation

State delivery selects one current projection when the writer can start its
next frame. The previous C++ build fails the blocked-state and shared-rotation
fixtures; three alternated pairs match Zig in Release and ASan/UBSan after the
correction. Late process observations no longer erase new OSC progress reports.
Allocation-failure replacement, slot reuse, partial writes and exit completion
with a viewport have unit coverage. Actual Desktop sh/bash/zsh reconnect flows,
eleven standalone headers and existing deferred/saturation fixtures pass.
Debug delivery tracing remains on the runtime thread with no dropped records.

Seven alternated pairs compare frozen binaries without concurrent builds,
tests or profiles. Ratios below one favor current C++. The preceding build is
deferred-responses-v2, which already has open performance issues.

| Workload | Wins vs prior C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| sparse | 2/7 | 1.024436 | 7/7 | 0.544590 |
| full | 3/7 | 1.002128 | 7/7 | 0.695783 |
| scroll | 5/7 | 0.983995 | 7/7 | 0.560185 |
| unicode | 1/7 | 1.011825 | 7/7 | 0.563842 |
| modes | 4/7 | 0.996805 | 7/7 | 0.549638 |
| links | 4/7 | 0.991168 | 7/7 | 0.645060 |
| colors | 3/7 | 1.009298 | 7/7 | 0.535097 |
| mixed | 2/7 | 1.001883 | 7/7 | 0.588839 |
| bulk | 2/7 | 1.016766 | 7/7 | 0.771798 |
| graphemes | 2/7 | 1.011297 | 7/7 | 0.600926 |
| graphics | 4/7 | 0.999637 | 7/7 | 0.758226 |
| graphics-shared | 6/7 | 0.963889 | 7/7 | 0.748234 |
| graphics-file | 6/7 | 0.968925 | 7/7 | 0.903736 |
| graphics-file-shared | 3/7 | 1.020858 | 5/7 | 0.938553 |
| graphics-shm | 5/7 | 0.988793 | 6/7 | 0.920091 |
| graphics-shm-shared | 2/7 | 1.005690 | 7/7 | 0.939643 |
| graphics-file-atomic | 5/7 | 0.978141 | 7/7 | 0.927993 |
| graphics-file-atomic-shared | 5/7 | 0.997842 | 4/7 | 0.990606 |
| graphics-shm-atomic | 4/7 | 0.987921 | 7/7 | 0.837400 |
| graphics-shm-atomic-shared | 4/7 | 0.892102 | 7/7 | 0.931525 |
| deferred-roundtrip | 3/7 | 1.002924 | 7/7 | 0.730724 |
| response-roundtrip | 7/7 | 0.986403 | 7/7 | 0.670365 |

All terminal workloads and both query/notification roundtrips win 7/7
against Zig. File/shared graphics wins 5/7 and atomic file/shared wins 4/7,
so neither passes the six-of-seven gate. Unicode wins only 1/7 against prior
C++, with a median ratio of 1.011825; its cause is not established. This is a
retained functional correction, not an accepted performance optimization.
Other control ratios above one remain visible in the table.

ARM64 state selection uses a 1,696-byte stack frame and bounded slot scans;
rotation lowers to `ror`, `rbit` and `clz`. Cell preparation uses 128 stack
bytes and graphics delivery 96. These findings do not establish the cause of
the Unicode regression. The new selector adds no heap allocation. Clipboard
replacement owns a bounded copy, and selected protocol projections retain
their existing allocator behavior. Frozen sources, binaries and assembly are
under `/tmp/telar-cpp-state-delivery-v1`; raw pairs and validation are recorded
in `state-delivery-v1-*.json`.

### Graphics completion before observation delivery

The final v2 correction continues the graphics walk after releasing a completed
frozen transfer when live storage is available. Previously that internal step
returned without a message and allowed queued history to overtake the snapshot
end. The deterministic direct/shared unit fixture fails on v1 with an unexpected
message tag and passes on v2. This follows the actual Zig transfer-completion
branch. While the media worker owns live storage, completion still yields.

An attempted live priority fixture was invalid: snapshot begin does not imply
that image preparation is ready, and Zig legitimately delivers history while
waiting. Its failed reference report is preserved in `state-delivery-v2-before.json`
and excluded from acceptance. The isolated test queues history after the image
and its placements, directly exercising the completed-transfer boundary.

Release and ASan/UBSan runtime/diagnostic tests pass. Current-state and rotation
fixtures again match Zig in three alternated pairs per build. All ten graphics
modes have equivalent outputs under ASan/UBSan; actual Desktop reconnect flows
pass with sh/bash/zsh in both builds. The three affected headers compile alone.
The final Debug trace records 261 delivery scopes and 122 graphics scopes on the
runtime thread, with no dropped records and mode 0600.

Fresh timings compare v2 with v1 and Zig. No builds, tests or profiles overlap.

| Workload | Wins vs v1 C++ | Median ratio | Wins vs Zig | Median ratio |
|---|---:|---:|---:|---:|
| sparse | 5/7 | 0.990502 | 7/7 | 0.489835 |
| full | 5/7 | 0.995912 | 7/7 | 0.720997 |
| scroll | 1/7 | 1.061729 | 7/7 | 0.553265 |
| unicode | 6/7 | 0.980425 | 7/7 | 0.587327 |
| modes | 3/7 | 1.010220 | 7/7 | 0.497599 |
| links | 4/7 | 0.983230 | 7/7 | 0.638984 |
| colors | 6/7 | 0.978469 | 7/7 | 0.530849 |
| mixed | 2/7 | 1.028497 | 7/7 | 0.566352 |
| bulk | 4/7 | 0.992409 | 7/7 | 0.733358 |
| graphemes | 2/7 | 1.015763 | 7/7 | 0.610225 |
| graphics | 4/7 | 0.996164 | 7/7 | 0.742809 |
| graphics-shared | 3/7 | 1.008403 | 7/7 | 0.706470 |
| graphics-file | 2/7 | 1.032466 | 5/7 | 0.925888 |
| graphics-file-shared | 3/7 | 1.004944 | 7/7 | 0.950828 |
| graphics-shm | 6/7 | 0.984458 | 7/7 | 0.936465 |
| graphics-shm-shared | 6/7 | 0.993952 | 5/7 | 0.931227 |
| graphics-file-atomic | 5/7 | 0.994425 | 7/7 | 0.921551 |
| graphics-file-atomic-shared | 5/7 | 0.991989 | 2/7 | 1.034935 |
| graphics-shm-atomic | 4/7 | 0.977885 | 7/7 | 0.877119 |
| graphics-shm-atomic-shared | 4/7 | 0.993408 | 7/7 | 0.948434 |
| deferred-roundtrip | 5/7 | 0.990475 | 7/7 | 0.724387 |
| response-roundtrip | 6/7 | 0.995701 | 7/7 | 0.668095 |

Nineteen of twenty-two workloads pass the Zig six-of-seven gate. File graphics
and shared-memory/shared transport win 5/7; atomic file/shared wins 2/7 with a
1.034935 median. Scroll wins only 1/7 against v1, median 1.061729. Its cause is
not established. V1's earlier Unicode regression is not declared resolved by
this differently paired comparison. These corrections remain performance-open;
none establishes whole-runtime performance parity.

The selector, cell and graphics stack sizes remain 1,696, 128 and 96 bytes.
Only `graphics/synchronizer.hpp` and its tests differ from v1's frozen source.
All final source hashes match `/tmp/telar-cpp-state-delivery-v2/sources.json`.
That prefix contains the final binaries, assembly and validation logs; complete
pairs are retained in `state-delivery-v2-*.json`.

An eight-second diagnostic sample during 500,000 scroll iterations records
576 top-of-stack samples in `CellProjection::copyRow`, 333 in
`FrameSync::appendDamage`, eleven in `AttachmentDelivery::cells` and five in
`ClientDelivery::prepare`. Both sampling and the driver complete normally.
This does not establish the cause of the paired scroll regression. The raw
profile, driver and logs remain under `/tmp/telar-cpp-state-scroll-profile-v1`;
no optimization is accepted on the basis of those sample counts.


## Branch integration and HoldTab (2026-10-25)

The runtime is merged into `feat/desktop-lua-ui` at `f5a4323dd`. The branch
added `HoldTab` and changed the wire schema after the original `23c87dfcb`
reference. This integration implements the new request, bringing dispatch to
62 tags. The current branch's Zig build is the reference for this section;
older sections retain their original binaries and conclusions.

The change stores at most 64 tab locations inline per client and shares empty-tab
removal between pane collection and hold release. Holds survive the final pane,
allow an empty snapshot and a replacement terminal, and end on explicit release
or disconnect. An explicit tab close overrides holds. Debug builds trace
`runtime.holdTab`; Release removes that tracing. The ARM64 handler uses an
80-byte stack frame and inlines the bounded hold lookup and insertion. The hold
container does not allocate; replies use the existing connection queue.

Frozen binaries are under `/tmp/telar-cpp-branch-integration-v2`. Release SHA-256
is `ac59d9ccbdf7f67409e76ccec9ecfdd2f74c522ec0d48ae00fe4bbb45749288b`;
ASan/UBSan is `9b3ddc58d6c1df26ccd14ba7c2c7081a53ffe6a96e48bd92b0785c864dd3ddec`.
The preceding C++ build, with the branch's serializers but without HoldTab,
is `bfa251e1f250d27d789704795fe66d10122a1e4a53db038015966cb44b0c120e`.
Current Zig SHA-256 is
`26bdd754a1d745929ed2c61c0325cd22cd7d39f515e339c6100dea77424f1f45`.

Release and ASan/UBSan runtime/diagnostic suites pass. Three alternating live
pairs per build match exact normalized reply bytes for multiple holders,
last-pane closure, empty snapshots, replacement panes, release, disconnect and
explicit tab closure. Six standalone headers pass. A freshly built probe using
this branch's Desktop connection and screen code passes with sh, bash and zsh
against both runtimes in Release and ASan/UBSan. The initial five-suite Release
integration run also passes runtime, diagnostics, TLS, hooks and integrations.

Seven alternating pairs measure 3,000 hold/release exchanges or 160 terminal
iterations per process. Every paired terminal output matches byte for byte.
Builds, tests and assembly inspection run outside the timed sessions.

| Workload | Wins vs preceding C++ | Median ratio | Wins vs current Zig | Median ratio |
| --- | ---: | ---: | ---: | ---: |
| `sparse` | 7/7 | 0.824495 | 7/7 | 0.559151 |
| `full` | 3/7 | 1.002214 | 7/7 | 0.710959 |
| `scroll` | 2/7 | 1.018314 | 7/7 | 0.551503 |
| `unicode` | 3/7 | 1.057037 | 7/7 | 0.589280 |
| `modes` | 5/7 | 0.989460 | 7/7 | 0.547172 |
| `links` | 3/7 | 1.012825 | 7/7 | 0.644479 |
| `colors` | 2/7 | 1.008043 | 7/7 | 0.529978 |
| `mixed` | 3/7 | 1.004097 | 7/7 | 0.560493 |
| `bulk` | 5/7 | 0.972600 | 7/7 | 0.731742 |
| `graphemes` | 4/7 | 0.995732 | 7/7 | 0.582095 |
| `tab-hold-roundtrip` | unavailable | unavailable | 7/7 | 0.679402 |

The eleven measured workloads pass the six-of-seven Zig gate. The C++ controls
remain mixed: Unicode is 5.70% slower by median with 3/7 wins, scroll 1.83%
slower with 2/7, and colors 0.80% slower with 2/7. Causes are not established.
The new functionality is retained for compatibility with the branch. These
results do not establish a general performance improvement over preceding C++,
or close the earlier graphics, proxy, Brotli, concurrency or provider gates.

Evidence: `measurements/experiments/branch-integration-v2-*.json`, with the
source manifest, binary fingerprints, raw pairs, functional reports and suite
logs. The disassembly is `branch-integration-v2-hold-tab-0.asm`.
