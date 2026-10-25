# Runtime parity work

Reference: Telar `23c87dfcb14d0a0524808c4ca46c3d9d17056ad1` on macOS ARM64.
Only libghostty-vt may reuse Zig implementation code. Existing C++ protocol
code and non-Zig services may be reused. Compatibility means equivalent
observable behavior, including failure, restart and resource-limit paths.
Handling a request tag alone does not establish compatibility.


The service is now integrated into `feat/desktop-lua-ui` as an opt-in executable.
That branch added `HoldTab` and changed the schema after the original reference.
The C++ runtime handles all 62 tags, including per-client tab holds, empty held
tab snapshots, terminal recreation, last-holder release and disconnect cleanup.
Release and ASan/UBSan unit tests and three live pairs per build pass against the
current branch's Zig runtime. Desktop connection/screen checks pass with sh,
bash and zsh. See the branch integration section of [performance.md](performance.md)
and `measurements/experiments/branch-integration-v2-validation.json` for the exact
binaries, source manifest and remaining performance limits. Earlier unresolved
contracts below remain open.

History saturation now matches the reference's separate bounds: 64 pending
requests, a drained batch of at most 64, and four queued responses. Admission
does not count an active batch or responses. The fixed queues allocate through
the injected allocator at construction; exchanging the pending batch swaps
storage without allocating. Import acknowledgements do not occupy the response
queue. Refusal codes and messages match Zig.

`history-capacity-v1-before.json` reproduces the former difference. The corrected
Release and ASan/UBSan socket fixtures produce the same 4,373 response bytes as
Zig with SQLite writes held, including full-queue errors and persisted imports.
The fixture allows 100 ms for the initial write to enter SQLite's busy wait;
separate condition-variable tests deterministically verify 64 queued requests
behind a blocked active job, reuse of the full capacity after a batch drain,
four-response backpressure, cancellation in both pending and active batches,
and shutdown with a full response queue and 64 durable imports. Focused
ThreadSanitizer tests pass. Supersession, immediate admission and disconnected
import/restart oracles still match. This fixes the history queue boundary only;
the wider outstanding contracts below remain.

Debug telemetry now reports multimedia queue events/bytes, their high-water
marks, dropped events/bytes, held PTY reads, per-pane media allocation usage,
and the main SQLite file size. Queue observations run on the owning runtime
thread; SQLite size is sampled at most once per second on the history worker
and published atomically. Missing files, directories, symlinks and in-memory
databases report zero. The SQLite gauge excludes WAL and SHM files.

Release and ASan/UBSan runtime/diagnostic tests and eight standalone headers
pass. A live ASan/UBSan fixture retains a graphics pane while sampling and
records positive allocation/high-water values; a separate fixture verifies
default Release writes no telemetry. The Release executable remains byte for
byte identical to history-capacity v1, preserving those performance results.
Evidence is in `storage-telemetry-v1-validation.json` and
`storage-telemetry-v2-live-asan.json`. Queue/storage field coverage is still
incomplete, including terminal scrollback allocation and graphics staging.

The actual Desktop terminal also passes IME, keyboard, styled Unicode output
and resize in native Cocoa windows with a verified Metal device, against both
Release and ASan/UBSan runtimes (`desktop-metal-v2-*.json`). Terminal cell and
style snapshots are byte-exact. Native pixel readbacks allow at most one RGB
level per channel, with exact alpha and dimensions. The initial strict pixel
comparison and a same-C++/same-C++ control reproduce one-level differences in
one or two pixels; both failed strict reports and all PNGs remain in
`desktop-metal-v1-*.json`. The passing v2 comparisons differ in zero to two
channels out of 6,144,000/8,294,400 channels. Offscreen software rendering keeps
its exact pixel requirement. Native Spaces switching is not exercised.

Pane input saturation now follows the reference's all-or-nothing policy. A
full 128 KiB queue discards a complete keystroke message, counts its bytes and
reports `panes.input_queue_capacity` without issuing a spurious request failure.
Control text returns the reference's exact resource-limit message; rejected
prompt framing and interrupt keys never reach history or agent observation.
The shared limit ledger belongs to the runtime model. Input-origin sequence
wrap resets client ordering and resumes at one.

The blocked-reader socket fixture passes in Release and ASan/UBSan with 251
identical normalized response bytes. It checks a second usable pane, exact
accepted byte delivery after unblocking, and subsequent input. Unit tests
cover queue boundaries, dropped-byte saturation, interrupt behavior and sequence
wrap. Both runtime/diagnostic suites and seven standalone headers pass.
`input-capacity-v1-validation.json` records scope and evidence. These tests
cover pane input exhaustion, not all client-output backpressure contracts.

Graphics storage telemetry now distinguishes resident images on both screens,
incomplete uploads, prepared/staged frozen payloads and active attachment
transfers. Atomic mapped images report their pixel length rather than the
one-byte ownership placeholder. Worker-owned state is omitted while busy;
`graphics_busy_panes` makes that omission visible. The resident total includes
active transfer bytes, while preparation gauges remain separate.

Release and ASan/UBSan tests cover screen switching, incomplete upload
completion, adoption, deletion and mapped input. A retained live image reports
262,144 resident bytes, one image and one placement. Default Release emits no
telemetry. Its entire 5,341,532-byte ARM64 text section is byte-identical to
input-capacity v1 at the same address and file offset; the executable hash
changes with diagnostic source locations. No fresh timing is claimed for this
diagnostic-only change. See `graphics-storage-v1-validation.json` for evidence
and the remaining telemetry fields.

Debug command-capture telemetry now counts OSC sequences and shell markers,
submissions, successful and failed rendered captures, and completions caused by
foreground recovery, subsequent input or shell markers. Workers drain counters
once per observation batch. Fragmentation, cancellation, erased input and batch
accounting pass Release and ASan/UBSan tests; a live shell reports submissions
and captures. All five affected headers compile independently. The Release
executable is byte-identical to graphics-storage v1. Evidence is in
`command-telemetry-v1-validation.json`; existing performance gaps remain.

Debug telemetry now reads actual VT page allocation through a small
libghostty-vt C API extension. `vt_scrollback_bytes` sums both screens, including
active cells, as the reference does; `vt_screen_bytes` measures the projected
active cell array. Queries allocate nothing and leave the active screen intact.
Tests cover null arguments, history growth/clear, alternate-screen retention
and resize. The filtered libghostty Debug build passes 60 tests, followed by
Release and ASan/UBSan runtime/diagnostic suites and three standalone headers.
A live sample reports 409,600 page bytes and 61,440 projected screen bytes.
Default Release emits no telemetry. See `vt-storage-v2-validation.json`.

The new Release binary passes all ten terminal workloads against Zig with 7/7
wins each. Sparse/full median ratios against the preceding C++ build are
1.0495/1.0159 with 2/7 wins each; their cause is not established. Existing proxy,
capture and other performance acceptance gaps remain open.

The PTY response queue now admits 64 messages of at most 1 KiB, shared by
ordinary VT and graphics producers. Its storage uses the injected allocator.
Rejected messages count as drops without failing VT ingestion; partial writes
retain the head until completion. A single consumer borrows stable slots while
producers append under a mutex. Diagnostics report messages, bytes and drops
separately, correcting the former byte-valued queue-depth field.

The original Zig queue and C++ agree across 1,005 cases and 150,143 operations.
Release and ASan/UBSan tests pass; a focused ThreadSanitizer fixture checks two
producers and one consumer delivering 20,000 messages. Eight affected headers
compile independently. A real PTY fixture reproduces the former 65-versus-64
reply difference, then matches Zig in Release and ASan/UBSan through saturation,
a subsequent query, repeated saturation and usable input. Its single-write
burst exercises live integration; the direct oracle independently fixes queue
boundaries without scheduling assumptions. See `pty-responses-v2-validation.json`.

After the correction, all ten terminal workloads and direct/shared graphics win
7/7 against Zig. Atomic file/shared graphics wins 2/7 at median 1.0347, leaving
that acceptance gate open. Client response priority/admission and other stated
contracts still need work.

Graphics transfers are now staged at the completed media-batch boundary,
matching the reference's eager reservation point. The synchronizer separates
reservation from message publication and owns frozen pixels and placements
while the next media batch runs. Client credit still gates adoption. Debug
telemetry distinguishes prepared, staged, adopted, credit-blocked and
worker-deferred transfers. The runtime-thread freeze timing stays zero because
pixel freezing remains on the media worker.

Release/ASan/UBSan tests and six standalone headers pass. All ten graphics
input/output modes match the reference under ASan/UBSan. A retained live image
records two staged and two adopted transfers; atomic shared objects do not
increment the separate eager-copy preparation counter. Default Release emits
no diagnostic log. `graphics-staging-v1-validation.json` records the frozen
binaries and the initial fixture correction.

This functional correction is retained, but its performance is not accepted:
atomic file/shared loses 7/7 against the preceding C++ build. An in-place
construction variant reduces stack/copy work but fails its paired gate and is
reverted. Complete-runtime performance acceptance remains open. The separate
v3 validation expands the retained implementation's tests to concurrent media
replacement and one/128 placements without changing the Release executable.
Release, ASan/UBSan and focused ThreadSanitizer checks pass. The TSan run
instruments the C++ code; Ghostty and system dependencies remain uninstrumented.
`graphics-staging-v3-validation.json` records the checks and source hashes.

Client response delivery now admits 128 pending replies in total, shared by
management and history-observation responses. Screen, graphics and state
messages use separate priority lanes. One started frame remains indivisible
through partial writes; its response slot is released when writing starts.
Same-lane contiguous frames share a write without releasing unsent slots.
The injected byte storage retains its existing total byte bound. Choosing an
out-of-order frame scans headers, and removing it moves the retained suffix;
normal head delivery consumes bytes without moving them.

Notification confirmation is reserved before synchronous publication, including
self-publication that can fill the requester's queue. Optional notifications,
agent sounds and limit notices count drops without closing recipients. Lost
tab closures request workspace resynchronization. Background history and
suggestion results preserve Zig's uncounted overflow behavior; path results
and required replies retain their disconnect policy. A saturated command
target stays connected and the requester receives `ResponseQueueFull`.

The actual frozen Zig ResponseQueue matches 1,005 cases and 496,473 operations
in `response-queue-v1-oracle.json`. The final v2 changes only connection policy;
its queue and oracle sources are byte-identical. Release/ASan/UBSan suites
cover 20,000 randomized partial-write operations, allocation failure, reserved
confirmation relocation, a full queue plus one started response, resync and
counter values. Live fixtures cover optional drops, reader recovery, saturated
command routing and mandatory-response disconnection against Zig in both
builds. Nine touched standalone headers pass across v1/v2. Three live ASan
telemetry samples include the new queue gauges. The actual Desktop Qt
connection/screen lifecycle and reconnect match Zig with sh, bash and zsh in
Release and ASan/UBSan (`response-queue-v2-desktop-*.json`).

The first v1 fixture had too little allocator budget for geometric growth and
omitted a required notification title; both failures and corrections remain in
the experiment logs. The v1 implementation also closed a saturated command
target. `response-queue-v2-before.json` reproduces the resulting disconnect;
v2 leaves queue overflow handling to the request flow. The generic transport
test now sends a server protocol reply after validating fragmented input;
handshake admission is owned by its separate state machine.

`response-queue-v2-validation.json` identifies the final binaries and sources.
This completes queue admission, ordering and these overflow paths. Late-bound
pane text and workspace/tab/limit snapshots are addressed in the follow-up
below. State coalescing and attachment rotation are addressed in the next
follow-up. A mixed-priority batching experiment
passed the corrected oracles but failed its shared-graphics performance gate
and was reverted. Performance results belong to the
frozen binaries in `response-queue-v2-*.json`; global acceptance remains open.

Deferred response projection now reads pane text, tab/workspace snapshots and
limits when delivery selects the response. Typed requests and encoded replies
share the 128-entry admission bound and management FIFO order. An
allocator-injected metadata queue preserves byte positions; an encoder concept
resolves dependencies at compile time. No internal wire placeholders are used.
Generation checks, exited-text fallback, closed-workspace errors and live-pane
filtering match the reference. Once writing begins, bytes stay fixed.

The blocked-client fixture reproduces the former stale response in
`deferred-responses-v1-before.json`. Three alternated pairs of changed-state and
closed-state scenarios match Zig in both Release and ASan/UBSan. The initial
ASan mismatch was the fixture child's long process name changing during OS
inspection; the corrected short executable name removes that race without
changing the runtime. Original bytes and failed report are preserved.
The queue oracle still passes 496,473 operations, while 20,000 randomized
operations now include deferred responses. Unit tests cover stale generations,
cache eviction, current limits and allocation failure. Both runtime/diagnostic
suites, ten standalone headers and Desktop sh/bash/zsh lifecycle pass.
`runtime.projectResponse` tracing is verified on the runtime thread.

`deferred-responses-v2-validation.json` identifies sources, binaries and evidence.
Deferred roundtrips and ten terminal workloads win 7/7 against Zig; three file
transfer variants fail the six-of-seven gate. Colors and atomic file/shared
regress against preceding C++; their cause is not established. This functional
correction remains performance-open. State coalescing and attachment rotation
are addressed below; the other contract rows still require work.

Client state delivery now selects one current projection only when the transport
has no active frame and no higher-priority reply. Layout/proxy startup state,
requested agent snapshots, metrics, workspaces, clipboard, resync and pane
metadata retain logical pending state while blocked. Once selected, a frame
stays immutable through partial writes. `ClientDelivery`, `StateProjection` and
`AttachmentDelivery` separate scheduling, service projections and terminal
publication. Dependencies use templates/concepts and clipboard ownership uses
the injected allocator with replacement before release.

Attachments retain stable slots across removal/reuse. Cells, CWD, foreground,
title, progress, exit and graphics share the reference's rotating cursor.
An exit completes before releasing its attachment; viewport projection and
unacknowledged frames are covered by unit tests. Initial title/progress
baselines now match Zig and avoid redundant empty metadata.

The three-pane live fixture also exposed late process observations clearing a
new OSC progress report. Progress now expires before the next PTY ingestion,
matching Zig, instead of being cleared by a later worker result. The original
failure is preserved in `state-delivery-v1-rotation-diagnostic.json`.
The preceding C++ binary fails both new blocked-state and rotation fixtures.
Three alternated pairs of each fixture match Zig in Release and ASan/UBSan.
The current-state comparison includes the final clipboard, requested agent
snapshot, workspace name, title and progress; only snapshot revision counters
are normalized. The rotation comparison preserves every message byte.

Both runtime/diagnostic suites, eleven standalone headers, existing deferred
read/queue-saturation fixtures and actual Desktop sh/bash/zsh reconnect flows
pass. A Debug trace records 650 `runtime.deliverClient` scopes on the runtime
thread, seven frame scopes, no dropped events and mode 0600. Sources, binaries
and the trace are frozen under `/tmp/telar-cpp-state-delivery-v1`.
Performance acceptance is recorded separately in `performance.md`.

The final v2 follow-up also prevents a completed graphics transfer from yielding
to queued history before the next available graphics message. Direct/shared
unit fixtures reproduce the former ordering and verify snapshot end before
history. A live fixture that assumed image preparation was immediately ready
failed on Zig and is explicitly excluded. All ten graphics modes match under
ASan/UBSan, and Desktop plus the state/rotation fixtures pass again. Final
sources and binaries are frozen under `/tmp/telar-cpp-state-delivery-v2`.

Nineteen of twenty-two final timing workloads pass the Zig gate. File graphics,
shared-memory/shared output and atomic file/shared remain below six wins;
atomic file/shared has a 1.034935 median ratio. Scroll regresses against v1
with a 1.061729 median and one win. Causes are not established. The corrections
are retained for behavior; performance parity remains open. See
`state-delivery-v2-validation.json` and `performance.md`.


| Contract | Status | Required evidence |
| --- | --- | --- |
| Checkpoint versions 1–10, atomic writes, quarantine, restart and resume | In progress | Version 10 Zig→C++→Zig, C++→Zig→C++, repeated C++ restart, truncation, capacity, atomic replacement and ID collision tests pass. Versions 1–10 and pane IDs above 2^63 pass restoration, I/O and a second restart against Zig. Twenty-five provider resume scenarios pass both restart directions in Release and ASan/UBSan. Eight exhausted workspace/tab/pane/generation counters match Zig in Release and ASan/UBSan. Both implementations discard checkpoints whose counters wrapped to zero; this shared defect is recorded below. Additional mixed-session cases remain. |
| Automatic shell command and output capture | In progress | Rendered selections, edit rebasing, right prompts, Unicode/wrapping, OSC 133, bounded output tails, next-input/foreground/exit completion, retired observer draining and ordered durable history writes implemented. Controlled CWD/output fixtures and a real interactive shell match Zig. Post-spawn launch failures are persisted and rollback is tested. Applying a process CWD snapshot before older queued input is corrected and regression-tested; broader unmarked-shell and batch-ordering fixtures remain. |
| Agent screen evidence, session-file watchers, manifests and descriptions | In progress | Built-in and custom manifest storage, process/screen/report precedence, bounded asynchronous terminal replay, expiry and provider screen fixtures implemented. Claude/Codex/Cursor notification snapshots match Zig. Configured manifests and JSON-backed declarations pass an exact custom-agent oracle. Claude, Codex and Cursor session-file renames match Zig. Generated descriptions, cancellation/editing, stale results and history titles pass nine exact cross-runtime scenarios. The actual Claude/Codex/Cursor scanners match 9,324 direct reference cases; live snapshots also pass under ASan/UBSan. Broader provider/lifecycle coverage remains. |
| Proxy service, capture and plugin effects | In progress | CONNECT and opaque forwarding, runtime status and pane environment match Zig. HTTP/1 framing matches 51,597 reference cases. HTTP/2 bytes, events and observation limits match 9,820 reference cases. HTTP/1 and HTTP/2 capture, background decoding, joining, isolated tap workers and authorized notifications are integrated. System trust records, rotation and runtime CA selection pass 62 cross-runtime cases; system command execution is tested through injection. Broader integration coverage and performance gates remain. |
| Configuration and child environment | In progress | Lua 5.5.1 with allocator injection, execution budgets, local modules, history/session/engine options and profile overlays implemented. Client fields, bindings/actions, panel/pick definitions, bars and static components are validated. Configuration notices and default-keymap capacity are checked separately. Graphics limits are wired to the media allocator; 18 configuration cases match Zig. Proxy configuration, plugin admission, pane environment and hook commands are connected. Integration installation/status/removal pass 68 scenarios and 336 commands per runtime; broader configuration coverage remains. |
| Host/process/runtime metrics | In progress | Host CPU/memory/battery sampler and two-second asynchronous delivery match Zig; failure retention and revision tests pass. Runtime JSON telemetry, asynchronous writes, rotation, orphan cleanup, request/PTY/frame counters, allocation categories and proxy counters are implemented. SQLite availability, write/query timing, failures and history queue metrics are also wired. Completed media batches, graphics delivery, process inspection, command observation and host-sample timing now expose counters. Client response depth/high-water/drop gauges and terminal/graphics storage gauges are implemented; complete field coverage remains. |
| Kitty file/shared input, asynchronous decoding, budgets and eviction | In progress | Dedicated worker, two bounded ordered batches, graphics backpressure, allocator budgets and independent cursor progression are integrated. Six input/output combinations, prepared transfers, both-screen eviction and incomplete-upload limits pass focused tests and exact protocol oracles. Atomic frame selection, mapped image ownership and file-query stripping are integrated; four atomic input/output combinations match Zig. Graphics performance gates and broader batch-boundary fixtures remain open. |
| Progressive path queries and large repository bounds | In progress | Independent per-client build/query workers publish immutable prefixes. Partial/final results, query replacement, root cancellation and unreadable roots match Zig. Four-index saturation, publication safety and storage bounds have focused tests. Large-query timing passes after bounded fuzzy alignment; broader Git fixtures remain. |
| Workspace/client lifecycle and asynchronous notifications | In progress | Rename replies, observer resync, geometry transfer and previous-workspace closure pass an exact cross-runtime oracle. Launch CWD authorization, default-tab reopening, asynchronous tab closure and handshake admission match Zig. Pending/active client saturation, invalid handshakes and response queue saturation have exact fixtures. Deferred text/snapshot/limit reads match blocked-client fixtures. Blocked-state coalescing and shared attachment rotation match Zig in Release/ASan, including deferred exit completion. Other lifecycle/resource boundaries remain. |
| Process and terminal metadata | In progress | Foreground/CWD inspection runs on a bounded worker. OSC 9;4, process-name projection and stale-generation guards implemented. Progress expiration follows PTY ingestion order and no longer races late process observations; broader protocol fixtures remain. |
| Workspace Git state and worktree discovery | In progress | Five-second branch/dirty refresh, retained state on failure, HEAD/gitdir handling and timeout streaks implemented. Workspace Git state and external-worktree discovery pass exact protocol oracles, including delayed duplicate prevention. Live hook registration, launch, closure and clean/dirty removal match Zig. Additional lifecycle/resource boundaries remain. |
| Startup, endpoint, background process, stop and bridge | In progress | Server CLI, authenticated endpoint discovery/autostart, background launch, stop, byte-preserving bridge, socket precedence, history defaults and fresh-checkpoint preservation pass both runtimes. Session cloning, private origin markers, restart without the source and background clone startup match Zig. Desktop's actual discovery code passes adjacent, bundle and login-shell PATH layouts in Release and ASan/UBSan. Actual Qt connection/screen lifecycle passes with sh/bash/zsh. Offscreen TerminalItem rendering, IME, keyboard and resize match Zig pixel for pixel in Release and ASan/UBSan. Native Cocoa/Metal input and resize pass in Release and ASan/UBSan with exact terminal state and a one-level RGB readback tolerance established by same-runtime controls; Spaces switching remains untested. |
| Build, packaging and CI integration | In progress | Fresh Release build, static external dependencies, system-only linkage and staged installation pass. Desktop selects the installed C++ runtime without Telar Zig runtime code. Manually dispatched Release/sanitizer CI workflow added and linted; hosted execution, signed archives, dependency notices and full Desktop bundle remain. |
| Final functional and performance acceptance | Pending | Existing 22 workloads plus new positive/concurrent cases; seven alternated pairs and equivalent results. |

The HTTP/2 capture oracle now covers 9,860 cases against the unchanged Zig
transport adapters, with no byte differences (`http2-capture-v4.json`). It
includes stream/queue limits, resets, partial HPACK output and informational
responses. All five component timing cases win 7/7; integrated proxy performance
is still pending.

The internal C++ `tap-worker` now implements the bounded framed protocol and
isolated Lua host. Its 64 MiB Lua budget, five-million-instruction budget,
read-only exchange projection, local modules, redaction, JSON and notification
effects have focused tests. Allocations are injected and erased before release.
`plugin-host-v4-zig.json` records 564 exact cases and six separate reference
crashes. LLDB locates the reference failure in `requireLocal` calling
`lua_rawget` with a null table; C++ loads or rejects those modules normally.
The reference's callback cleanup also clears error messages before framing;
the C++ error frames preserve the resulting `unknown Lua error` contract.

Release plugin tests and ASan/UBSan host tests pass. The first broader ASan run
exposed a capture test that assumed a readable worker descriptor meant its
nonblocking collect had already obtained the mutex. The corrected test waits
for consumption; the subsequent runtime/plugin sanitizer run passes. These
results preceded the later direct frame-read path; the v5 checks below cover it.

The v5 host keeps a bounded 512 KiB pool of erased small allocations. Release
and ASan/UBSan runtime/plugin tests pass, including frame fragmentation,
consecutive frames, pool retention, erasure and allocation failures. Of 392
standalone headers, one initially relied on an inherited `Byte` alias; its
explicit `std::uint8_t` fix passes a separate compile. The original failed
report and correction remain. Subsequent plugin configuration files are outside
that header snapshot. `plugin-host-validation-v5.json` records these checks.

`plugin-data-v3.json` records 4,048 exact manifest/trust cases, including unknown
and duplicate fields, escaped keys, Unicode, all limits and version coercions.
The schema-version reader preserves the reference's binary128 rounding bounds
and its long-hex truncation behavior; earlier mismatches remain in v1/v2.
Parsed grants retain the package identity, digest and capability set.

Package inspection and private snapshots pass 35 acceptance/digest comparisons
each (`plugin-package-v3.json`, `plugin-snapshot-v3.json`). Limits are exclusive
for file reads, as in Zig: exactly 64 KiB manifests, 1 MiB entry files and
16 MiB packages are rejected. The earlier two boundary differences remain in
v2. Snapshots reject symlinks and special files, bound entries and copied bytes,
recheck the copied digest, and remove their private tree on destruction.
Release and ASan/UBSan tests cover source changes, permissions, cleanup,
disabled packages, stale grants, duplicate IDs and the 16-worker limit.

The runtime now loads configured packages and digest-bound grants, prepares
snapshots, starts sequential worker actors and hands them shared captures.
Queues keep the newest 64 exchanges; results keep the oldest 64. Captures and
encoded frames share a 128 MiB budget. Callback errors retain the session;
invalid replies, closed pipes and timeouts restart it. Five failures within
ten minutes disable the worker. Cancellation interrupts blocked reads/writes;
workers release captures before the proxy's quota is destroyed. Notifications
require matching identity/digest/generation plus declared and granted
capabilities, then pass the reference's 512-byte wire validation before delivery.

`plugin-service-v12.json` records 53 exact service/worker cases against the
unchanged Zig Service, Worker, Session and protocol. The test adapter reconstructs
owned captures and the Zig worker executes the frozen reference binary. It is
not a complete live TLS-to-UI test. Earlier adapter failures are retained: v3
used an invalid notification level; v4 mishandled EOF and supplied a noncanonical
entry path, which Zig rejects when requiring a local module.
`plugin-startup-v7.json` records 21 matching startup admission outcomes.
Release and ASan/UBSan runtime/plugin tests pass for the initial service
integration (`plugin-service-validation-v6.json`). Later Release, ASan/UBSan
and focused TSan checks cover the queue changes. Three small-message service
performance gates remain open; further plugin work is deprioritized.

The earlier performance reports describe the executable whose SHA-256 they
record. They do not certify changes made during this parity pass. New final
reports must identify the final executable and retain every paired result.

Current parity evidence lives in `measurements/checkpoint-parity-macos-arm64.json`
and `measurements/experiments/model-parity.json`. Each report identifies its
executables; later source changes require rerunning it. Runtime unit tests pass
in Release and Debug with AddressSanitizer/UndefinedBehaviorSanitizer after the
checkpoint, client lifecycle, process worker and terminal progress additions.

Server configuration is loaded at startup in the Zig reference. Configuration
reload is a client feature, so runtime reload is not a parity requirement.

The observation worker now inspects foreground processes and replays ordered
input/output/resize batches against its own libghostty-vt terminal. Each pane
has two 128 KiB / 512-event buffers. A dropped batch resets the observer and
cannot turn a lost Codex/Cursor status row into completion evidence. Input and
resize alone do not refresh screen evidence; incomplete VT sequences and
synchronized-output frames are excluded. The same ordered replay now captures
commands from tracked terminal selections and queues typed events on the history
worker. Closing a pane retains its observer until pending events and the session
ending have been processed. Retired observers count against pane capacity.

`measurements/experiments/screen-events.json` records seven paired runs with
200 iterations per provider. Exact canonical notification snapshots match;
C++ wins 7/7 for Claude, 6/7 for Codex and 7/7 for Cursor. Median C++/Zig ratios
are 0.702, 0.788 and 0.750. This certifies those workloads only.
The separate one-millisecond polling workloads remain below the required
win-count gate, despite median ratios below one in the latest experiment.
Their reports are retained as `screen-inference.json`, `screen-selected-scans.json`,
`screen-immediate-dispatch.json` and `screen-reused-snapshots.json`.

Release and ASan/UBSan tests pass after the observation/evidence changes.
Final performance acceptance remains pending for the complete runtime.

Automatic capture now has a cross-runtime probe with a controlled shell: input
differs from rendered text, commands wrap and contain Unicode, human input
alternates with automation, and the final command completes when the child exits.
`capture-process-snapshots-history.json` passes seven of seven paired runs with
40 commands, with exact canonical history responses. A separate `capture-cwd`
fixture changes the process directory between acknowledged commands. Its smoke
comparison passes; the full paired run must be repeated after subsequent changes.

The first capture timing exposed a 100 ms child-exit polling delay. SIGCHLD now
wakes the event loop while preserving the exit status for waitpid. The phase
timings and rejected initial experiment remain in `capture-phase-timing.json`
and `capture-smoke.json`. Worker request/result separation also avoids copying
unused process snapshots; `capture-process-snapshots.json` passes sparse and
bulk output in seven of seven pairs. Each report applies only to its recorded
executable hash.

`host-metrics.json` checks the first sample and delivery of the retained sample
to a second subscriber. Used memory and battery charge are allowed to vary
between processes; stable hardware fields, revision and initial CPU match.
`server-cli.json` verifies server actions, default storage, endpoint precedence,
bridge handshake, fresh sessions and refusal to replace an active runtime.
Release and ASan/UBSan tests pass after these additions.

The latest `server-cli-terminal.json` passes sparse output but fails bulk output
(3/7 wins). The dependent history benchmark did not run. Performance acceptance
remains open; earlier passing measurements do not certify this binary.

`config-capture-output.json` verifies exact retained PTY output and history
metadata with Lua output capture enabled. C++ wins 7/7 pairs of 40 commands
(median ratio 0.810). The fixture waits for persisted completion before painting
the next prompt so the reference output does not vary with read coalescing.
`cwd-buffer-terminal.json` passes sparse and bulk 7/7 for an experimental
CWD-buffer change, but the controlled C++ A/B run wins only 5/7. That
optimization was rejected and reverted; its passing Zig comparison does not
certify the retained implementation.

`startup-config-parity.json` compares 24 startup cases, including local modules,
profile validation, malformed JSON, sandbox budgets, agent limits and relative
storage paths. `config-server-cli.json` reruns the server CLI contract and checks
invalid-option exit status 1. `config-custom-agent.json` verifies process identity,
manifest presentation and screen transitions from a JSON-configured custom agent;
all seven pairs match exactly and C++ wins 7/7 (median ratio 0.614).

`config-agents-json-terminal.json` passes sparse output 7/7 but bulk only 4/7
(median 0.976). The retained source is not yet accepted for overall performance.
A relative `--config` passed to Zig's background launcher is forwarded unchanged
after changing directory to `/`; C++ resolves the path before launch. The shared
background parity case uses an absolute config path and relative storage paths.

The later foreground-demand optimization passes controlled C++ A/B (bulk
7/7, sparse 6/7) and all ten terminal workloads against Zig at 7/7 each.
Capture, rapid CWD changes and configured output capture also pass 7/7.
See `foreground-demand-{ab,terminal,history,output}.json`; these identify the
frozen executable before the session-file additions. Overall acceptance and
the older polling workload gate remain open.

`session-files-parity.json` verifies Claude transcript seeding/appends, Codex
read-only thread-name queries, Cursor metadata and clearing titles. Canonical
agent snapshots match for all three providers. Its times include the mandated
one-second file polling interval and are diagnostic, not performance acceptance.
Unit tests cover partial lines, rewrites, missing files, malformed metadata,
UTF-8 truncation, read-only database behavior, stale watches and pane generations.
Release and ASan/UBSan pass after these additions. The read worker is separately
traced as `agents.readSessionTitle`.

`session-files-aligned-parity.json` aligns the Claude transcript polling phase
with an observed warmup rename; all three providers still match exactly.
`session-files-terminal.json` passes all ten terminal workloads in seven paired
runs (160 iterations). Each report identifies its executable hash.

Generated descriptions use a bounded sensitive input capture, an eight-job
queue, a single subprocess worker, bounded bidirectional pipe I/O and validated
history title events. Restored/reported titles invalidate outstanding jobs.
`descriptions-canonical-parity.json` compares nine scenarios, including editing,
bracketed paste, cancellation, malformed/oversized output, helper failure,
timeout and a reported title replacing a running generation. Successful and
failed SQL title states also match. The initial fixture's `/tmp` alias raced
with CWD observation; its mismatch dumps are retained under
`descriptions-parity.description-success.*.bin`. The retained fixture launches
from the canonical directory in both runtimes.

Release and ASan/UBSan unit tests pass after generated descriptions, including
queue saturation, generation/session/revision rejection, shutdown cancellation,
large stdin with concurrent stderr, secure clearing and SQL event ownership.
Overall parity and final performance acceptance remain open.

`descriptions-activity-parity.json` repeats all nine description scenarios twice.
The fixture emits terminal activity after its working report: Zig starts title
jobs from observation completion, so a silent fixture can otherwise leave a
queued job waiting indefinitely. The diagnostic run at
`/tmp/telar-description-diagnostic-1ym5cnee` confirmed that state. This is a
fixture synchronization correction, not a retry of a failed timing gate.
`descriptions-activity-performance.json` passes 6/7 paired runs of 12 successful
generations, median C++/Zig 0.931, with exact title and database output.

`descriptions-terminal.json` passes all ten terminal workloads 7/7;
`descriptions-history.json` passes capture 6/7 and CWD capture 7/7.
These predate the final provider-replacement title reset and identify their
own executable. `description-standalone-headers.json` passes 161 isolated
headers. `agent-background-trace.json` verifies separate worker threads for
both title generation and session-file reading, valid private trace files
and zero dropped trace records. New process-identification work requires
subsequent validation before its results can be accepted.


## Process identification and reporter verification

Foreground groups are identified through their leader and up to 64 members.
Node/Bun/Deno arguments are bounded to 16 KiB. Recognized groups are cached;
unknown groups receive six acquisition attempts. Explicit rechecks preserve the
previous provider when it still runs in the group. Codex session-host detection,
installed-hook hints and the five-second shared-server warning are implemented.
`process-cache-parity.json` matches five cross-runtime scenarios, including a
shell group leader, Node launch, shared-server warnings, `--no-daemon` and batch
commands.

Descent verification now has its own bounded worker and connection/generation
credentials. Reporter authorization reuses those credentials. A provider
conflict pauses that connection until a fresh identification or a two-second
deadline. Deferred reports own their payload and preserve arrival order and
observation time. A confirmed refusal is cached for the reporting process below
the identified agent; direct agent replacements remain eligible for recheck.
The components are `platform/descent_probe.hpp`, `runtime/descent_service.hpp`,
`runtime/deferred_reports.hpp` and `agents/reporter_state.hpp`.

`reporter-verified-rechecks-parity.json` compares actual `exec` replacements for
state, title, progress and command reports, plus nested-agent refusals. Queuing a
query behind the conflicting report preserves response order. The initial
fixture sent reports before its descent-verification reply; Zig can refuse such
reports. The corrected fixture awaits verification. That failure is recorded in
`reporter-unverified-pipeline-failure.json`.

Unit tests cover credential invalidation, stale pane generations, queued checks,
closing connections, deferred payload ownership, wrapping counters, rejection
caching, deadlines and receive-buffer suspension. Release and ASan/UBSan pass.
Performance remains open for several reporter workloads; see the retained
`credentials-*`, `process-cache-zig`, `reporter-rechecks-performance` and
`reporter-decisions-zig` reports rather than inferring acceptance from medians.


## Cloning, large identities and progressive paths

`session-clone-shutdown-parity.json` verifies fresh shells, retained structure
and layouts, source preservation, restart without the source, background startup,
private files, eight refusal cases and fresh-origin preservation. The earlier
`session-clone-background-parity.json` exposed a shutdown hang. Sampling found
`PtyProcess::~PtyProcess` waiting for a child with unread PTY output. Shutdown
now terminates the foreground group, flushes and closes the master before reaping;
`clone-shutdown-before.sample.txt` retains the diagnosis. An unread-output
regression and Release/ASan/UBSan tests pass.

`legacy-checkpoints-pane-identities.json` checks versions 1–10, IDs above 2^63
and IDs near UINT64_MAX, including terminal I/O and a second restart. Pane event
handles now identify a physical slot and its reuse generation independently of
the public pane ID. Tests reject stale handles after reuse. Restoring UINT64_MAX
itself remains unsupported because advancing its counter would overflow.

Process metadata now uses the Darwin kernel's command name and can identify
surviving group members after the leader exits. `process-metadata-parity.json`
checks kernel-name truncation, group identification and Node launchers.
`process-metadata-performance.json` still fails the group-report gate (2/7 wins);
the Node workload passes 6/7. The failure remains part of acceptance evidence.

Paths now separate fixed allocator-owned storage, filesystem/Git streaming,
ranking and service scheduling. One build and one query may run per client;
four clients can own indexes, and only idle indexes may be evicted. Refresh or
root replacement cancels the old build before its storage is reset. Disconnect
suppresses delivery and reclaims storage after workers finish. The shared worker
notification is emitted after publication; the worker's private notification stays
under its result lock so collection cannot leave a late unread signal.

`paths-progressive-directory-parity.json` holds Git output behind a gate and
requires a published partial answer before releasing it. Both runtimes return
identical final results, complete the newest query, cancel a blocked build when
the root changes and reject unreadable roots. The earlier
`paths-progressive-parity.json` failed in the Zig fixture: its Git wrapper ignored
`-C` and waited in the wrong directory. That failed report is retained.


`workspace-git-parity.json` records exact normalized workspace-list responses
for clean/dirty transitions, partial output followed by Git failure, recovery,
detached HEAD, relative `gitdir` pointers and FIFO refusal. `WorkspaceGitService`
uses a separate typed observation worker and selects the oldest due workspace.
Unit tests cover timeout streaks, unchanged revisions, removed workspaces and
multiple due workspaces. Release and ASan/UBSan tests pass for that frozen build.
The shared Git policy now inspects local/worktree configuration, disables every
known hook event and repository filter driver, and only checks for lazy-fetch
support when repository configuration can cause a fetch. Global filter drivers
retain the reference runtime's trusted treatment.

External worktree discovery now walks at most 64 parents on its own worker,
stops at the nearest `.git`, validates linked metadata without spawning Git,
and commits only for the same pane generation and CWD revision. Focused tests
cover nested repositories, malformed/FIFO metadata, stale results and the
16-slot reservation for Telar-created worktrees. The first discovery fixture
changed directory silently and stalled in Zig; its failed report is retained.
The OSC 7 fixture then exposed duplicate `/tmp` and `/private/tmp` entries in
C++, recorded in `worktree-detection-stability-failure.json`.

`worktree-detection-cadence-parity.json` passes discovery, ancestor selection,
source ownership, base discovery and delayed stability checks against Zig.
`git-observation-workspace-parity.json` repeats the workspace state oracle after
Git status reading was shared with worktree measurement. The corresponding
build passed Release and ASan/UBSan tests, plus 188 standalone header checks.
Process fixtures exposed a remaining observation scheduling issue after idle
polling was removed; its report is `git-observation-process-parity.json`.
Follow-up source changes observe process identity on every nonempty batch,
matching Zig, and require fresh validation.


The corrected event scheduling passes `observation-events-process-parity.json`
(group member, Node CLI identity and kernel process-name projection), all five
cases in `observation-events-reporters-parity.json`, command/CWD history in
`observation-events-capture-parity.json`, and the delayed external-worktree
oracle in `worktree-detection-events-parity.json`. These are equivalence-only
runs; their diagnostic timings are not performance acceptance. Nonempty batches
observe the process on every batch. Only an explicit agent recheck can submit
an empty batch; the runtime commits CWD from the ordered observation result.

## Launch directory and default-tab authority

`runtime/launch_directory.hpp` resolves inherited CWD only from a live pane
attached to the requesting client. Tab creation requires the same workspace;
splitting requires the same tab. Default opens and workspace creation accept
any attached live pane. Every refusal has Zig's exact failure code and text.
Explicit CWD directory creation is skipped when the launch inherits its CWD.

`launch-directory-default-parity.json` compares positive opens, tabs, splits
and workspace creation, plus foreign clients, other tabs/workspaces, detached,
closing and exited sources. It also keeps a closing default pane alive while
another tab runs: explicit workspace opening and splitting fail, and a default
open launches into the existing default tab. `launch-directory-model-parity.json`
retains the previous rename/resync/geometry/closure oracle.

The former C++ executable fails the authorization fixture while Zig passes
(`launch-cwd-authorization-regression.json`). Three earlier fixture failures
are retained; they used empty required wire fields or an incomplete close
request and are not runtime regressions. Focused unit tests additionally check
empty default tabs, stale attachments, lease refusal and releasing a lease
acquired before a failed launch. `runtime/geometry_lease.hpp` shares acquisition,
color application and release; disconnect releases all leases held by that
client, including workspaces it never attached. Release and ASan/UBSan pass.

## GUI and theme configuration validation

`config/gui_validator.hpp` validates native font, cursor, window, chrome,
sidebar and frame-rate preferences. Numeric GUI values require finite Lua
numbers; integer-only settings also reject fractions. Font strings retain
the reference's UTF-8, NUL and 256-byte rules. Legacy boolean background blur
is accepted. `config/theme_validator.hpp` validates preset aliases, chrome
colors, explicit terminal RGB colors, 16-color palettes, syntax styles and
appearance variants. Root and client theme declarations are mutually exclusive.
Both validators run for the base and every selected or unselected profile.

`appearance-config-parity.json` compares 38 valid/invalid startup cases with
Zig. This closes GUI/theme startup validation for those cases, not the remaining
client panels, picks, actions, bindings or plugin execution contracts. These
preferences stay client-owned; the runtime validates them without storing UI
state. Release unit tests pass for the corresponding frozen executable.
`appearance-full-config-parity.json` also passes all 62 cases when the original
startup/module/JSON/agent/configuration cases are included.


## Worktree and pane closure

Tab removal now requests process shutdown while retaining the pane until its
exit, final frame delivery and text retention complete. Closing a worktree
announces each removed tab in order to all observing clients. Empty workspace
views are released after retired panes are collected, including workspaces
already removed from the model. Shutdown is idempotent and follows the reference
SIGKILL/PTY-flush behavior for the foreground group and session leader.

`worktree-lifecycle-parity.json` verifies two-tab forget notifications, exits,
retained text, repeated-forget errors, direct/script/login-shell command labels
and UTF-8 truncation at 48 bytes. `worktree-lifecycle-launch-parity.json` and
`worktree-lifecycle-model-parity.json` retain CWD authority, default-tab, observer
and geometry equivalence. Focused Release tests cover deferred destruction,
attachment lifetime and empty-view cleanup.

`close-state-background-trace.json` verifies separate worker execution of
process inspection, terminal observation, descent verification, generated and
session-file titles, path construction/query and Git/worktree observation.
Every case has zero dropped events and private trace files. ASan/UBSan passed
for that pre-worktree-closure executable; later changes need their own checks.


## Client configuration validation

The runtime validates the shared client configuration before starting.
`client-config-values-parity.json` checks 52 startup outcomes: client options,
retired fields, strict booleans, printable text bounds, sequence timeouts,
history preferences, key chords and unused profiles. The initial
`client-config-parity.json` retains a rejected fixture that incorrectly treated
`notifications.terminal` as a retired field; only the `delivery = "terminal"`
value is retired in the reference.

`binding-values-parity.json` checks built-in and structured actions, key sequences,
Lua/expression callbacks, inherited panel references, notifications, command-tab
argv and limit notices. `binding-config-parity.json` retains the initial fixture
with a missing closing brace. Client bars, panel/pick definitions and complete
component validation were still pending for that executable.

`client-definitions-parity.json` adds 62 cases for panel/pick definitions,
sorted name retention, title fitting, command arguments, static pick items,
swatches and text/item saturation. `client-bars-budget-parity.json` adds 75
cases for bar sources, component placement, priority-based staging, typed
fields, URLs, deferred action validation and the shared command-tab pool.
`client-bars-parity.json` retains a failed fixture whose commands were shorter
than intended; fixed-width identifiers make the saturation case precise.

`client-complete-config-parity.json` passes all 305 startup cases before exact
notice comparison was added. Release and ASan/UBSan pass for that source;
`client-config-standalone-headers.json` passes 215 isolated headers. The stricter
`client-config-notices-parity.json` exposed missing default-keymap capacity
notices. Subsequent code counts retained bindings against the 43 unoverridden
defaults, canonicalizes key identities and restores keymap/command-pool state
after validating unused profiles. New reports must certify that later code.

`client-config-keymap-parity.json` passes 313 cases with exact limit text,
amounts and order as well as startup outcomes. It adds default-key overrides,
canonical chords, selected-prefix changes and unused-profile rollback.
`client-keymap-asan-parity.json` repeats the eight keymap cases with the sanitized
runtime. Release and ASan/UBSan pass, and
`client-keymap-standalone-headers.json` passes all 218 headers.

## Media worker, cursor and file inputs

The runtime now injects a bounded media allocator into a separate Ghostty
terminal per pane. A dedicated worker consumes two 64 KiB/64-event buffers;
adjacent output and resize events coalesce without changing their ordering.
Graphics in flight hold that pane's PTY reads when the next batch would fill.
Plain-output overflow resets only the media terminal. Retired pipelines drain
before release. Image cursor movement remains on the interactive terminal and
does not depend on decoding succeeding.

The libghostty-vt patch exposes generic cursor/scroll-region operations and a
Kitty parser toggle. Telar's framing, control parsing, image sizing, scheduling,
allocation budgets and file validation are implemented in C++.

`media-files-inputs-parity.json` matches image bytes and placements for file
and child shared-memory input, each delivered inline and through shared memory.
The files include offset/size selections; the child checks that consumed shared
objects have been unlinked. `media-files-cursor-parity.json` matches screen,
text and selection output through failed images, puts, chunked uploads, PNG,
scroll regions, deletion, resizing and reconnecting. Eighteen cases in
`media-graphics-config-parity.json` match startup acceptance and rejection of
graphics limits, including profile overlays.

Release tests pass (1.28 s), as do ASan/UBSan (5.16 s) and all 236 standalone
headers (`media-files-standalone-headers.json`). `media-files-tsan.json` records
an isolated ThreadSanitizer run of the C++ queue/allocator/cursor/file tests;
the prebuilt Ghostty and runtime-core libraries were not instrumented.
`media-files-background-trace.json` verifies media execution on a worker,
alongside the other background services, with private trace files and no
dropped records. Whole-runtime performance acceptance remains pending.

Prepared inline/shared transfers now own their pixels independently of mutable
VT storage. The media worker prepares four shared images and eight deduplicated
pending transfers. RAII releases unpublished shared objects and pane/global
media reservations; published names become the client's responsibility. Credit
is bounded per attachment and per client, without the former 64-transfer count
restriction. Two clients have independent credit pools.

`media-transfers-inputs-parity.json` matches all six input/output combinations.
Release (1.25 s), ASan/UBSan (5.09 s), 239 standalone headers and the isolated
C++ ThreadSanitizer run pass. `media-transfers-background-trace.json` confirms
inline/shared image copies execute on the media worker. The prebuilt libraries
are outside the isolated ThreadSanitizer coverage.

`graphics-quotas-parity-v2.json` compares two successive rounds of snapshots:
80 images, offscreen-first placement eviction, partially visible placements,
alternate/primary screen retention, and an upload exceeding 43,690 chunks.
The image/placement payloads, explicit upload error and reported limit names
and values match Zig. The first report is retained: it caught a missing space
in the upload error text, corrected before the successful second run.

Storage enforcement now visits both existing screens, restores the original
screen even after exceptions, selects the oldest generation over all images,
and removes wholly offscreen placements before placements of older images.
The C API additions expose image iteration, counts, placement grid references,
loading state, aborting a load and selecting an existing screen; all quota
policy remains C++. Separate C++ upload tracking counts terminated commands
across input fragments, limits retained loading bytes, and removes an image
whose final chunk crosses the limit. Tests exercise byte/chunk precedence,
final-chunk removal, split terminators and mandatory errors for quiet uploads.

Release tests (1.58 s), ASan/UBSan (5.06 s), all 241 standalone headers and the
sanitized quota/upload protocol oracle pass. The six image input/output
combinations still match (`graphics-quotas-inputs-parity.json`). Performance
acceptance is separate from these functional measurements.

Remaining graphics work includes atomic frame coalescing, additional
malformed/file-query oracles and workload performance.


## Client admission

Pending connections now have a separate bounded handshake state machine. Public
client IDs and generations are assigned only after negotiation succeeds; slot
event handles reject stale events independently. Fragmented reads, partial
replies, pipelined requests, expiry and capacity refusals are bounded without
allocating a full client session for an unnegotiated connection.

`client-admission-parity.json` matches negotiation-order identities, malformed
and incompatible hellos, sixteen pending handshakes, thirty-two active clients,
expiry and capacity notices. `client-admission-identities-before.json` fails the
identity regression against the previous C++ executable. Release and ASan/UBSan
pass; `admission-standalone-headers.json` passes all 202 standalone headers.


Atomic frames now select the latest available resource for each placement,
consider at most eight recent candidates, preserve saved-cursor effects when
folding wrapped frames, and leave groups above 256 keys untouched. File queries
are answered and removed before grouping. Child shared names are consumed;
files remain owned by the child. A runtime-owned read-only mapping holds the
pixels, with a one-byte Ghostty placeholder whose allocator releases the
mapping and its full reservation. A parked shared name adds no reservation.
Files are copied with bounded pread rather than reading a mapping that could
be truncated by their owner. The generic image insertion ABI is the only new
Ghostty operation; all selection and ownership policy is C++.

`atomic-frame-inputs-parity.json` checks six frames in each of four atomic
input/output combinations against Zig, including exact pixel and placement
messages. `atomic-frame-asan-parity.json` repeats them under sanitizers.
`atomic-frame-quotas-parity.json` retains both-screen eviction and upload-limit
coverage. Release tests (1.28 s), ASan/UBSan (5.38 s), standalone headers and
worker-thread tracing pass. Focused tests cover a full 64-mapping registry,
reservation rollback, replacement/deletion, shared-name lifetime, query-induced
coalescing and saved-cursor restoration. Performance is measured separately
against frozen binaries; these functional checks do not establish speed.

## Editor and suggestion admission

`service-admission-parity-v4.json` and `service-admission-engine-parity-v4.json`
match exact responses for unknown panes, stale editor generations and live
suggestions with and without an engine. The configured fixture returns a
successful command through the same JSONL protocol as Zig. Sanitized runs
repeat both scenarios. Missing-engine requests return `unavailable` before
pane lookup; configured requests for unknown panes return a suggestion with
`failed` rather than a generic request failure. Zig's `resolveControl` itself
does not reject an existing exited or closing pane, so this lookup adds no
such restriction. The earlier fixture incorrectly assumed it did.

Editor admission filters candidates by editor kind and the cached foreground
process name before querying process identity. Closing source/target panes
are rejected, and one outstanding editor request is allowed across clients.
The worker's pending check includes results not yet collected. Positive
Neovim/Vim/Emacs remote-command unit fixtures and worker queue tests remain in
the release/sanitizer suite. Cross-client busy and closed-target protocol
oracles still need dedicated deterministic fixtures.

## Proxy foundations

Proxy configuration is not yet connected to runtime startup. The independent
C++ components currently cover bounded host policy, strict options, constant-
time credentials, Basic authorization, private secret persistence, preferred
port recovery and reservations, exclusive loopback listeners and bounded DNS.
The DNS backend has 64 process-lifetime rows, deduplicates hostnames, retains
at most 32 addresses and uses detached system resolver workers without
borrowing service storage. Notification subscriptions are removed before their
pipes can die. Saturation, abandonment, late completion and slot reuse are
covered; isolated ThreadSanitizer passes (`proxy-resolution-tsan.json`).
`proxy-foundations-standalone-headers.json` checks 273 headers independently.

The shared private-file writer now publishes checkpoint and proxy records
through a random private temporary file, fsync and atomic rename; exclusive
creation preserves pre-existing credentials. `private-writer-checkpoint-parity.json`
checks restoration in both directions with Zig after the extraction.
Transport, TLS authority/session handling, capture, child environment and
runtime status remain incomplete; these foundation tests do not establish
full proxy parity.

The CONNECT transport now has separate bounded header, origin connection,
handshake, relay direction, connection policy and counter components. Tests
cover every split of a CONNECT head, a head exactly at the 16 KiB bound,
pipelined tunnel bytes left unread, EOF, partial writes under backpressure,
a response after request EOF, failed destinations, IPv6-to-IPv4 fallback,
keepalive, exact 200/400/407/431/502 responses and eviction/expiry boundaries.
Release (1.28 s), ASan/UBSan (5.25 s) and all 281 standalone headers pass.
These components are not yet the complete proxy service and have not yet been
measured against Zig's proxy. TLS and application-protocol capture are still
required before enabling runtime proxy configuration.

TLS authority components now generate P-256/SHA-256 authorities and server
certificates, load existing private PEM files, reject partial/mismatched or
expired authorities, enforce the 30-day system-authority lifetime and preserve
the ten-year private-authority lifetime. Secret input buffers and PEM output
buffers are erased on release, including failed construction. Atomic private
publication reuses the checkpoint/credential writer. Unit tests also cover
maximum-length hostnames, encrypted-key rejection without prompting, invalid
names, owner-only permissions, bundle concatenation and allocation failure.

`proxy-authority-parity-v2.json` creates an authority with each implementation,
loads it with the other, verifies a C++-minted leaf using OpenSSL, restarts Zig
and verifies key/certificate bytes and fingerprint retention. A protocol probe
confirms Zig completed runtime initialization, beyond merely creating its
socket. `proxy-authority-asan-parity.json` repeats this with the sanitized C++
probe. Release runtime/TLS tests pass in 1.61 s; ASan/UBSan pass in 5.22 s.
The TLS allocation test requires zero retained budget bytes after cleanup.

OpenSSL 4 was rejected after this ownership check exposed its deferred global
cleanup. The retained diagnostic and official contract are recorded in
`tls-openssl4-rejected.json`. CMake and a compile-time check require OpenSSL 3;
its callbacks are installed before initialization and global cleanup completes
before the injected allocator is destroyed. The current verified library is
3.6.5. The authority code is not yet wired into runtime proxy startup, TLS
connection negotiation or capture.

All 286 authority-era headers compile independently
(`tls-authority-standalone-headers.json`). The following ALPN component is tested
with real OpenSSL ClientHello messages: HTTP/1.1, HTTP/2, both offers in either
order, unknown/absent protocols, truncated records and fragmented peeks that
consume no bytes. The first ALPN build failed because the test omitted its algorithm header;
the shell command incorrectly continued with the previous executable. Those
old-binary test times are not ALPN coverage. The corrected build and fresh
validation must pass before this component is accepted. This selects the upstream offer; it does not yet establish either
TLS connection.

The pinned TLS reference was inspected at commit
`8092ca3fa136a48a11f08a245f6fddfeb23d4a1c`: its upstream `fromSystem` delegates to
Zig's certificate bundle rescan, which reads the system root and system
keychains on macOS. The separate child bundle in `localca/ca.zig` reads the
bounded PEM root files. These sources must remain distinct during C++ TLS
integration. No code from that TLS implementation is linked or reused.

The corrected ALPN/trust validation is recorded in `tls-trust-validation.json`.
Fresh builds stop on compilation failure. Release TLS tests pass in 0.34 s,
ASan/UBSan in 0.43 s, and all 290 headers compile independently. These runs
include the actual ALPN tests omitted from the invalidated runs above. They
also verify subject-based root deduplication, expired/invalid certificate
handling, system keychain enumeration, the separate bounded PEM bundle and
zero allocator bytes retained after OpenSSL cleanup.

`SystemCertificates` reads only the two system keychains through macOS APIs;
`SystemRootBundle` reads the PEM search paths used for child environment
bundles. Neither changes platform trust. TLS handshake/relay and runtime
proxy integration remain pending.


### Proxy actor and HTTP/1 integration

The proxy actor owns its sockets, bounded connection slots and event queue.
Readiness-directed forwarding avoids speculative reads in the opposite
connection direction; occupied-slot indexes avoid scanning empty slots.
Authenticated CONNECT, status and all eleven pane environment variables match
Zig in `proxy-runtime-functional-v4.json`. Admission, DNS-independent shutdown,
TCP half-close and 512 KiB TLS transfers under backpressure have focused tests.
Only pane launches receive proxy credentials, matching the reference;
administrative execution requests do not. Environment storage uses the injected
erasing allocator and `Command` cannot copy its internal allocator reference.

The first integrated service passed Release, ASan/UBSan and 307 independent
headers. Subsequent changes require fresh sanitizer and header validation.
The socket-watch batching experiment was rejected and removed; its frozen
binary, sources and failed paired reports remain under the v5 experiment.

HTTP/1 now separates head semantics, delimited reads, message/body progression
and connection ordering. It preserves complete headers before semantic errors,
limits heads to 64 KiB, chunk lines to 1 KiB and trailer lines to 8 KiB, and
preserves consumed framing prefixes on line failure. Request bodies and
responses advance independently for `100 Continue` and early rejection.
Informational responses, HEAD/bodyless responses, pipelined exchanges,
connection close, upgrade and idle/inflight admission state are handled.

`http1-framing-parity-v2.json` compares 29,240 heads, 20,032 length strings and
2,325 complete/truncated messages against the unmodified Zig HTTP library.
Wire bytes, deframed payloads, consumed lengths and limit/error outcomes match.
The reference is compiled into a test-only shared library in a temporary
package. No Zig HTTP implementation is linked into the C++ runtime.

`tls-half-close-before.json` reproduces a response write failing after the
client half-closes TCP. The Zig TLS library leaves writes available after
receive EOF. `tls-half-close-after.json` verifies the correction in TLS 1.2 and
1.3. The OpenSSL unexpected-EOF option preserves the independent send direction;
HTTP framing remains responsible for detecting incomplete bodies. See the
[OpenSSL option contract](https://docs.openssl.org/3.6/man3/SSL_CTX_set_options/).
This does not relax certificate or hostname verification.

### HTTP/2 observation and relay

HTTP/2 separates frame decoding, payload/padding extraction, HPACK allocation,
header metadata, bounded stream tracking, directional observation and proxy
connection lifetime. Each direction has its own 128 KiB header block and
inflater, 128 request/response tracking slots, and a shared 256-entry inflight
set. Requests are observed before forwarding; responses only after the whole
read has been written. The response direction owns connection termination.
Decoder failures stop header inspection while raw forwarding and DATA/end/reset
events continue. Counters are recorded once at settlement. Debug traces include
`proxy.http2Exchange`.

`http2-observer-functional-v1.json` and `http2-observer-erasure-v2.json` compare
9,820 deterministic inputs against the unchanged Zig relay: fragmented and
truncated prefaces/frames, continuations, padding/priority/push prefixes, HPACK
dynamic-table reuse, stream exhaustion, oversized blocks, status/SSE metadata,
resets, GOAWAY, malformed input and write failures. Wire and serialized event
bytes match exactly. The reference library is test-only; production links C
nghttp2 through callbacks backed by the injected allocator.

Initial tests found a dangling nghttp2 callback-table pointer. The table now
belongs to the nonmovable decoder and outlives inflater destruction. This
matches [nghttp2 1.70's implementation](https://github.com/nghttp2/nghttp2/blob/v1.70.0/lib/nghttp2_hd.c#L684-L686),
which retains that pointer despite the public header claiming otherwise.
Isolated ASan/UBSan tests pass, including zero-budget allocation failure.
Integrated Release tests also pass two-stream TLS transfers in both directions
with 512 KiB bodies and socket backpressure, including forwarding after HPACK
failure and once-only failure counts. Full sanitizer/header validation and
performance controls are tracked separately from these functional results.

The v2 integrated build passes all 337 independent headers and the complete
focused Release/ASan/UBSan suites. The v3 request-side lookup correction again
passes Release (6.42 s total) and ASan/UBSan (10.75 s). Debug tracing records
2,131 HTTP/2 scopes on the proxy actor threads, alongside HTTP/1 and handshake
scopes, with a private 0600 file and empty sanitizer stderr. That report did
not retain the trace footer, so it does not establish zero dropped records.

### Launch environment and identity transactions

Default-pane lookup now precedes command preparation, so an existing pane can
be reused even when the unused launch contains an unavailable executable or
custom environment. New panes reject replacement environments and explicit
entries with Zig's exact `invalid_request` message. Validation lives in pane
launch, leaving configured helpers' independent environment contract intact.

Pane identities/generations are consumed when launch begins, including failed
environment validation and command preparation. Workspace/tab identities commit
only after successful launch. Worktree workspace proposals follow the same
rule. CreateWorkspace and CreatePane responses preserve the reference's zero
generation field; OpenPane, CreateTab and background launches report it.

`launch-environment-parity-before.json` reproduces premature executable lookup.
The v1 fixture itself included an invalid pane-target/launch combination and is
retained as rejected evidence. The v2 comparison exposed a response generation
difference. `launch-environment-parity-v3.json` matches all bytes after 18
rejected launches, repeated reuse and subsequent successful pane/tab/workspace/
worktree creation, including their unnormalized identities. CWD-authority and
default-tab comparisons also pass. `launch-environment-asan-v2.json` repeats
them under ASan/UBSan; `launch-parity-worktrees.json` passes forget and label
lifecycle comparisons.

The default-tab fixture now retains an unacknowledged frame on a second client
while reopening the tab. Its earlier timing-dependent version could race pane
retirement under sanitizers; the failed report is retained. The sanitizer unit
suite passes in 4.92 seconds. Reuse performance and independent controls are
measured separately from these functional-only fixtures.

Repeated OpenPane requests now retain the existing attachment without forcing
a snapshot or resizing an unchanged terminal. Pixel dimensions remain part of
the resize comparison. New panes, including background panes, receive the
workspace geometry owner's colors at launch. `unchanged-pane-functional-v1.json`
and `unchanged-pane-asan.json` preserve the launch oracle; the sanitizer unit
suite passes in 5.01 seconds. `unchanged-pane-terminal-parity.json` also matches
colors, graphics cursor movement, sparse/full/bulk output, resizing and reconnect.
The sparse-output performance control regressed and remains open.

### Capture storage

Independent C++ capture components now separate the shared atomic byte quota,
erased buffers, directional metadata, owned exchanges and the bounded join table.
Buffer growth charges old and replacement allocations simultaneously. Idle
halves reserve no bytes; failed allocation preserves retained bytes and returns
unused quota. The joiner owns waiting halves and transfers complete, duplicate,
capacity-refused and expired exchanges without copying their buffers.

`capture-storage-v1.json` matches 4,529 operation sequences against the unchanged
Zig capture library, including allocator failures, shared quota contention,
part/exchange/total truncation precedence, resets and oversized metadata.
Every sequence checks buffer capacities, retained bytes and flags, and finishes
with zero owned allocations and zero reserved quota. Release unit tests pass,
including four concurrent quota users, full joiner ownership and verified
erasure before deallocation. Transport publication, content decoding and plugin
delivery are still being implemented; these tests do not establish full capture
parity.

Content decoding uses separate gzip/zlib envelope handling, raw DEFLATE,
Brotli and Zstd components. It applies at most two content codings in reverse
order, retains the original bytes on unsupported or failed decoding, and
preserves the reference's output-boundary behavior. Zstd validates declared
sizes, rejects dictionary flags and windows above 8 MiB, and retains whole-block
reservation semantics. Decoding allocations and temporary output are erased.

`capture-decode-v9-extended.json` matches 3,452 cases: valid and truncated
streams, mutated inputs, coding chains, concatenated/skippable Zstd frames,
literal-only blocks and capture-boundary crossings. One additional malformed
gzip input crashes Zig 0.16.0's reference DEFLATE decoder; C++ returns a
controlled failed decode. It is recorded as a reference failure, excluded from
the equivalence count and retained separately. The test harness now isolates
both libraries in subprocesses. Earlier mismatch reports v1–v7 remain available;
v8 and v9 pass the original 3,136 non-crashing cases.

The 256-entry publication queue transfers ownership without waiting on a
contended/full queue, counts rejected transfers and releases their quota.
Closing frees buffered halves and wakes receivers. Producer counters distinguish
part/exchange/total truncation, allocation refusal, queue drops and decode
failure. Focused tests cover four publishers with one consumer, saturation,
shutdown, decoding-induced truncation and zero-budget allocation failure.
Release passes in 1.35 seconds and ASan/UBSan in 5.26 seconds. These component
tests precede HTTP transport integration and do not certify its performance.

### Capture transport and delivery

`capture-pipeline-validation-v1.json` records the integrated executable and its
source hashes. HTTP/1 policies preserve capture publication at successful body
completion, failed exchange outcomes, informational head resets, early-response
discard and keep-alive reuse. HTTP/2 policies retain partially decoded headers,
separate 128-stream directional tables, status outcomes and reset publication
on directional shutdown. Both policies use concepts and injected allocators;
clock injection makes lifecycle tests deterministic.

TLS service fixtures test capture enabled and disabled for HTTP/1, multiplexed
HTTP/2 and HPACK failure, with 512 KiB transfers and socket backpressure. Captured
bytes, metadata, outcomes and final quota release match the fixture expectations.
These are integration tests, not yet a cross-runtime capture oracle. Release
runtime/TLS suites pass in 2.32/9.98 seconds; ASan/UBSan pass in 5.35/10.71 seconds.

The existing observation worker now receives and optionally decodes one half
off the main event loop. It feeds the bounded joiner and a compile-time tap
interface. Duplicate halves, 256 pending exchanges, full-table delivery, expiry,
shutdown and transfer ownership are tested. The runtime reports join-table
capacity through its limit service. With no configured tap, decoding is skipped
and joined captures are released. Configured Lua loading, isolation and
authorized notification effects were subsequently added; see the service
evidence near the beginning of this report.

The integrated capture pipeline also passes ThreadSanitizer with receive,
expiry and shutdown exercised (`capture-pipeline-tsan-v2.json`), and 368
standalone headers pass. `capture-pipeline-runtime-functional-v1.json` confirms
exact proxy status/environment/opaque behavior with capture configuration
enabled in both runtimes. No Lua tap is configured in that fixture.


## Launch failure persistence and shell capture

`history/launch_writer.hpp` persists post-spawn failures independently of
session/command writes. `PaneService` receives a `HistoryEventSink` template
argument and reuses the durable background queue. A rejected diagnostic does
not prevent rollback. Tests force event-registration failures and duplicate
pane registration, check child reaping and PTY closure, preserve an existing
pane, and prove that failed launches create no session rows. Pre-spawn errors
remain outside `launch_attempt`, as in Zig. The C++ event loop has no separate
wait-actor admission step; its output registration maps to `output_actor`.

`launch-history-v2.json` compares the unchanged Zig history store with the C++
store: 193 insert/duplicate operations, 97 persisted rows and no differences.
It covers all three stored phase values, both location kinds, signed SQL
identity bounds, negative timestamps, Unicode and embedded NUL text. The first
adapter build used an incorrect C++ enum name; its build log is retained.
This is a persistence oracle, not a Zig fault-injection test for every launch
failure cause. Native C++ registration failures retain their own error causes.

History filters now reject excluded commands before queue admission and output
copying. A focused test submits 4,096 excluded events with 4 KiB output tails,
checks zero additional allocator calls and an empty worker queue, then persists
an accepted command. OSC 133 exit parsing now accepts interior underscores and
preserves signed 32-bit overflow rules; `command-exit-v1.json` matches 29,376
inputs against Zig's unchanged parser.

The real `/bin/sh -i` fixture exercises command echo, next-input completion,
leading-space exclusion, automation and process exit without OSC 133 markers.
`shell-capture-asan-v3.json` matches the reference with the ASan/UBSan daemon.
Its directory-changing variant remains available as `shell-capture-cwd` and
is not accepted: `shell-capture-asan-v2.json` records a submitted `cd` command
associated with the destination directory. Both implementations read native
CWD before replaying an asynchronous event batch, so scheduling can assign
that later CWD to earlier input. The passing Release run in v2 does not close
this race. The initial v1 fixture also expected automation attribution before
a filtered preceding command; the reference consumes that submission earlier.

`core-v4-capture-asan.json` separately passes controlled command/CWD fixtures;
`core-v4-launch-scopes-asan.json` passes launch authority, default-tab and
custom-environment refusal. The earlier `core-v4-launch-asan.json` invoked an
unsupported probe workload and is retained as a harness failure. Release and
ASan/UBSan runtime tests pass for core v4, as do 432 standalone headers.
`core-v4-history-trace.json` verifies history input/output, observation replay
and persistence on background threads: 39 matching scopes, six trace threads,
no dropped records and private file permissions. Initial trace checks used
configuration without the required API version and are retained in their logs.

Plugin CLI inspection, installation and trust updates were completed before
plugin work was deprioritized. `plugin-cli-v1.json` compares nine command steps,
stdout, generated files and permissions against Zig. Installation copies a
validated package into private staging and publishes it with an exclusive
rename; a matching existing installation is idempotent. `plugin-tracing-v9.json`
verifies separate runtime/worker traces. No complete TLS-to-plugin-to-UI oracle
is claimed.

## Agent hook commands

The C++ executable accepts `hook claude|codex|pi|cursor|opencode`. Parsing,
provider mappings, session-file lookup, worktree operations and typed runtime
exchange are separate modules under `cli/hooks/`. Owned containers receive the
allocator through template dependencies. The hook connects to an existing
runtime, verifies pane ancestry, then sends progress, lifecycle, title and
command observations in reference order. Ordinary report failures are best
effort; Claude worktree errors return a failing status.

`hooks-v10-cli-release.json` and `hooks-v10-cli-asan.json` each compare 324
cases against Zig, including malformed and duplicate fields, Unicode, numeric
bounds, provider session files and input exceeding 16 MiB. No differences
remain in those cases. Bounded input handling drains standard input and keeps
complete earlier top-level fields when the tail is truncated or malformed.
`hook-tests` verifies allocator exhaustion without retained allocations and
oversized input consumption in Release and ASan/UBSan.

The five live-pane scenarios in `hooks-v10-integration-release.json` and its
ASan counterpart execute the hook binary through the pane's `TELAR_BIN_PATH`,
then compare serialized agent snapshots after three provider events. They
require actual lifecycle-report authority. These functional runs are separate
from timing acceptance.

Worktree checks cover fourteen real-Git observations and eight registration
cases in both builds. They include nested checkout placement, branch reuse,
dirty checkout retention, ancestry refusal, registration refusal and invalid
pane context. The registration fixture acknowledges the real wire protocol;
the separate live-runtime lifecycle fixture is described below.
The v8 failure report is retained; it exposed the generation-zero error and
refusal diagnostics corrected in v9.

There is one intentional safety difference. The isolated NUL-path oracle
shows Zig creating a checkout from a truncated `cwd` and removing the checkout
at the prefix of an embedded-NUL path. C++ rejects both inputs before invoking
Git and preserves the checkout. `hooks-v10-null-paths-release.json` and its
ASan counterpart retain both observed behaviors. This difference is not counted
as exact parity.

`hooks-v10-trace.json` checks Debug input, mapping and report scopes: six events,
no dropped records and mode `0600`. Release ignores `TELAR_HOOK_TRACE`.
`hooks-v10-validation.json` records commands, statuses and binary hashes.
Provider integration installation and deeper JSON boundaries remain outside
this evidence.

`hook-worktree-live-v6.json` and its ASan counterpart run all five lifecycle
providers plus clean and dirty worktree scenarios against real runtimes. The
Claude fixture runs inside a pane, creates and registers a checkout through
the hook CLI, launches a process there, attaches an observer and invokes the
removal hook. Both runtimes close the process with SIGKILL and remove the
catalogue/workspace entry. Clean checkout removal and unchanged dirty-file
retention match. These are functional checks, not timing acceptance. The
earlier v3/v4 fixture timeouts are retained; they waited for exit notifications
without attaching to the background pane. The v5 correction attaches first.

The first two live attempts omitted `cwd`. The isolated
`hook-worktree-inherited-cwd.json` confirms that Zig fails with `FileNotFound`
when that field is absent even with a valid inherited repository directory.
C++ resolves the native current directory and succeeds. Both succeed with an
explicit `cwd`, which the accepted live fixture supplies. This observed
reference failure is documented separately from exact equivalence.

## Provider session restoration

`agent-resume-v2.json` and `agent-resume-v2-asan.json` each cover 25 scenarios
and 100 runtime launches. A native fixture replaces each provider executable
inside a private directory, records its actual argv and stays alive in the
restored PTY. The oracle compares Zig→C++ and C++→Zig restarts, checks the
persisted original launch, and compares agent snapshots after identification.
Normalization removes process/session identities, generations, revisions and
observation times. Pane identities, provider state, titles and other snapshot
fields remain in the byte comparison.

All five providers cover direct launch, shell resume, disabled restoration and
invalid session references. Additional cases cover Codex's in-pane flag,
disabled/invalid shell resumes and duplicate session references recorded out
of pane-ID order. Only the first pane resumes that duplicate session. Each
case retains the original launch arguments in the next checkpoint instead of
replacing them with the generated resume command. The native fixture does not
exercise the providers' external session databases or their own network work.

The v1 report is retained as a fixture failure: it used C++'s `--no-resume`
option, which Zig does not accept. v2 disables resume through the shared Lua
configuration contract. No production changes were required by these cases;
they validate the same hook v10 runtime binary measured above.

The final `agent-resume-v3.json` and `agent-resume-v3-asan.json` repeat all
25 scenarios with the later flate v2 runtime. The shell readiness command now
prints its marker in two pieces, so terminal echo cannot satisfy the check
before the shell actually executes it. All 100 launches per build pass.

## Small gzip and deflate captures

The decoder now uses `Z_FINISH` when the first DEFLATE block is also the last,
allowing zlib to omit its retained history window when decoding completes.
Multiple-block streams keep their block-boundary behavior. Small outputs use
the existing `SensitiveBuffer` for the 64 KiB validation window and allocate
only the returned prefix through the injected allocator. That temporary is
bounded stack storage; it and all heap allocations are erased before release.

`flate-final-v2-oracle.json` compares 3,452 cases with Zig. The separately
recorded reference crash is excluded from equivalence; C++ returns its bounded
failure result for that case. Tests cover allocator exhaustion and successful
small gzip/deflate decoding within a 32 KiB heap budget. The shared erasure
checker verifies zeroed allocations before upstream deallocation, including
decoder failures. Release and ASan/UBSan runtime/TLS suites pass, as do the
three touched standalone headers. `flate-final-v2-acceptance.json` records
the binary hashes and bounded performance decision.

## Installed runtime and Desktop discovery

The distribution configuration requires static non-system dependencies and
runs the existing `packaging/release/check-linkage.sh` after linking. Release
`94fccc6c4739fac80ed064c78f7760960a3ea99634cb6628131501a6a9109abc`
links only SDK/system libraries and frameworks and installs as `bin/telar`
when the explicit Desktop-command option is enabled. The default installation
still uses `bin/telar-runtime`. Dependency discovery lives in
`cmake/dependencies.cmake`; neither mode links Telar Zig runtime services.

`distribution-v1-desktop.json` and its ASan counterpart exercise Desktop's
unchanged endpoint and login-shell sources against both runtimes. Each checks
adjacent, bundle and login-shell PATH layouts under directories with spaces,
automatic startup, socket reuse, private permissions, the actual wire handshake
and shutdown. Adjacent/bundle scenarios place a failing command on PATH to
catch accidental fallback. These checks cover discovery, not the full Qt GUI.

Release and ASan/UBSan runtime, TLS and hook suites pass. The sanitizer build
uses the same static OpenSSL/libpng archives but needs its compiler's dynamic
sanitizer runtime. Negative configuration checks reject cached dynamic PNG
when distribution is requested and reject combining distribution validation
with sanitizers. Commands, binary/source hashes and test logs are recorded in
`distribution-v1-validation.json`.

The macOS ARM64 CI workflow covers Release and Debug sanitizer builds, focused
suites and installed Desktop discovery. `actionlint` passes locally; the hosted
workflow has not run in this worktree. Signed archives, dependency notices and
a complete Desktop application bundle remain outside this acceptance.

After rejecting three follow-up performance experiments, the final Release
binary is byte-identical to the measured staged installation. Runtime/TLS/hook
suites pass again in Release and ASan/UBSan with the retained independent
socket-filter test. Final sanitizer discovery passes all three layouts.
`distribution-v1-final-validation.json` records this final state. Moving test
target declarations into `cmake/tests.cmake` leaves the build graph unchanged;
regeneration reports no compilation work.


## System trust management

The C++ CLI now implements `proxy trust install|uninstall|status` on macOS.
Records retain Zig's version, backend, uppercase SHA-1 fingerprint and keychain
path contract. Private file reads, CA validation and atomic publication reuse
existing C++ modules. The runtime rotates a recorded stale authority, selects
the system CA when its record is valid, publishes `system_trusted`, and passes
the selected certificate to child processes. Relative XDG data roots are ignored.

`system-trust-v2-parity.json` and `system-trust-v2-asan-parity.json` contain 62
matching cases each, including record coercions, missing/malformed/private
files, default paths and the runtime's status/environment. These tests never
alter OS trust. Unit tests inject the command executor and verify installation,
renewal, removal, command failure, record publication failure, temporary cleanup
and restoration of the previous certificate files. Release and ASan/UBSan
runtime/TLS/plugin tests pass; 12 standalone headers compile.

Two failure safeguards intentionally improve the reference behavior: repairing
directory permissions while retaining the same fingerprint does not delete that
certificate from the keychain; failed record publication restores the previous
on-disk authority. Actual keychain mutation has not been exercised on this host.
The first oracle report is retained: it found three version coercion differences
and a fixture that expected the proxy directory under another name. Both were
corrected before v2. Performance is tracked separately and remains open.

## Provider integration installation

The C++ CLI now installs, reports and removes hooks for Claude, Codex and Cursor,
and the bundled TypeScript integrations for Pi and OpenCode. Provider paths,
hook mutation, file operations, extension rendering and owned skills are separate
modules. The mutable JSON tree uses the injected allocator and checks duplicate
fields by sorting names, avoiding quadratic duplicate detection on large objects.
The production entry point is compiled in its own translation unit.

Settings preserve unrelated fields and commands, existing modes and symlinks to
dotfiles. Existing Telar commands are updated without overwriting their other
fields. Foreign skills/extensions are preserved. Legacy hook files, directory
variables, explicit paths and the Cursor home-directory rule follow the reference.
The TypeScript and Markdown assets are shared source assets; no Zig runtime code
is linked or executed for these commands.

`integration-v2-parity.json` and `integration-v3-asan-parity.json` pass 68 scenarios
and 336 commands per implementation. Paths and JSON formatting are normalized;
exit status, stdout, structured file contents, modes and symlinks match. Error
wording is retained but is not an equality criterion. Cases include 4 MiB read
boundaries, ten thousand unrelated fields, 120 nested arrays, invalid UTF-8,
missing HOME with a provider override, mixed hook groups and repeated operations.
Focused Release/ASan/UBSan tests and nine independent header compilations pass.
JSON nesting beyond 256 levels is rejected by the C++ installation parser; that
explicit bound has not been certified equivalent to Zig's parser.

The previously listed placement-eviction implementation gap was stale: the
existing C++ storage policy already performs the same offscreen-first and
oldest-image passes as Zig, covered by `graphics-quotas-parity-v2.json`. Further
graphics work concerns batch/lifecycle coverage and performance acceptance.

Packaging and hosted CI work are deferred at the user's request. Runtime
telemetry, remaining behavioral audits, broader lifecycle/resource fixtures and
whole-binary performance acceptance are still in progress.

## CWD observation ordering

Process snapshots are now applied after replaying the sealed history batch. The
previous order could attribute an already submitted `cd` to its destination.
The regression fixture fails before the change and passes afterward for both
full process inspection and directory-only probes: `cd /observed` belongs to
`/initial`, while the following `pwd` belongs to `/observed`. Release and
ASan/UBSan runtime suites pass. This is an intentional correction of a race also
present in the reference, not an assertion that every intermediate CWD can be
reconstructed without shell markers. Several commands or directory changes
between process observations still require broader fixtures.

## Runtime diagnostics

Debug builds now write `<endpoint>.runtime-<pid>.log`; Release can opt in with
`-DTELAR_RUNTIME_DIAGNOSTICS=ON`. Default Release compiles out instrumentation
and sampling. Startup orphan cleanup is available in every build. The log sink
uses exclusive private files, rotates at 4 MiB, retains one previous file and
examines at most 4,096 directory entries when cleaning abandoned logs. Cleanup
keeps active processes, symlinks, directories, unrelated filenames and the
runtime's startup/stderr logs. The existing observation worker writes at most
one borrowed 12,288-byte line at a time. Write failure disables further samples;
the runtime continues.

Formatting, sink ownership, asynchronous delivery, counters and allocation
classification have separate modules. Current fields cover runtime resources,
requests, input/PTY traffic, frame/diff work and timings, RSS, allocator totals
and interactive/media/observation categories, plus existing proxy/capture
counters. Allocator snapshots use the allocator's synchronization; terminal
allocations are marked at the libghostty-vt bridge. Sampling does not access
state owned by an active media or observation worker. Media/graphics, process inspection and command-observation counters now arrive as completed worker results. Host sampling records duration and age even when a failed probe retains its previous values. Detailed prepared-transfer, marker/completion-cause and queue/storage gauges remain; absent measurements are not emitted as fabricated zeros.

Release and Debug ASan/UBSan diagnostics/runtime suites pass. A Release test
initially timed out waiting for an interactive shell's foreground change; an
isolated run passed, and the fixture now waits for its actual prompt before
sending input. Both suites pass with that readiness condition. Live tests check
positive counters, monotonic cumulative values, private permissions and cleanup;
default Release produces no telemetry file. The filename parser matches 11,820
cases against the actual reference Zig module, including unsigned overflow,
underscore-separated process IDs and mutated byte strings. Thirteen headers
compile independently with diagnostics enabled. Reports are
`telemetry-v3-{names,headers,release-live,optin-live}.json` and
`telemetry-v4-asan-live.json`. Whole-binary performance acceptance remains open.

## Screen heuristic boundaries

The actual Zig Claude, Codex and Cursor scanners are now exercised through
`check_agent_screens.py`, with whole-stream, one-byte and seven-byte feeds.
The 9,324-case final oracle matches exactly (`screens-v2-parity.json`). It
covers lower draft prompts with earlier software cursors, missing Codex
manifests, Claude hardware-cursor inclusivity and the first visible cell beyond
the 1,024-byte row buffer. The preceding oracle retained 123 differences before
the cursor/row-boundary fixes. Release and ASan/UBSan runtime suites pass, and
`screens-v2-asan-live.json` checks provider transitions through the runtime
protocol. Its functional-only timings are not performance evidence.

The frozen Release binary at `/tmp/telar-cpp-screen-v2/release/telar-runtime`
passes the Cursor timing gate but still fails Claude and Codex. The broader
performance claim remains open.

## History availability and disconnected imports

The history worker retains a degraded service when SQLite cannot open or migrate
the database. Query, statistics and output requests return the reference
`internal` failure; deletion/pruning report zero; accepted imports and agent
commands keep their completion semantics. File preparation and permission
errors still prevent startup. The fallback stores filters in the same variant
as the database store, avoiding a second filter copy in the steady-state object.
SQLite operation counters use atomic snapshots; queue gauges are read under the
existing queue mutex. These counters and sampling are compiled out of default
Release.

`history-v5-{release,asan}-live.json` checks corrupt databases, incompatible
schemas, directory paths, invalid parents and successful recovery after restart.
The history responses and terminal output match Zig byte-for-byte in every
running case. ASan/UBSan also checks live availability, failures, accepted query
counts and queue high-water marks. Two initial harness errors (reference SIGTERM
exit handling and its leftover socket) and the rejected initial treatment of
invalid paths remain in the preceding reports.

A controlled SQLite write lock exposed a separate lifetime bug: the previous
C++ binary retained only one of three accepted imports after disconnect, while
Zig retained all three. Imports are now durable queued writes, like agent-command
reports and internal pane events. The deterministic worker test fails before
the fix. `history-disconnect-v1-{before,release,asan}.json` checks acceptance,
client loss and persistence across runtime restart. The fixed binaries produce
the same exact history rows as Zig. Release and ASan/UBSan runtime/diagnostics
suites pass, and eight touched headers compile independently with diagnostics
enabled (`history-v4-headers.json`). Binaries and sources are frozen under
`/tmp/telar-cpp-history-v4`.

## Bounded fuzzy alignment

Fuzzy ranking now skips alignment columns that cannot reach the current query
prefix or leave too few bytes for its remaining suffix. It reuses the existing
subsequence scan and keeps the same injected matrix allocation. The direct
actual-Zig oracle matches scores and highlight positions in 24,971 cases before
and after the change. Another 12,000 generated cases match the frozen baseline
under ASan/UBSan. Release and sanitized runtime suites pass.

The frozen `/tmp/telar-cpp-fuzzy-bounds-v1` binary passes both the 1,000-query
and the original 120-query large-index gates against Zig. Its terminal controls
show mixed wins against the prior C++ binary and 7/7 wins in every case against
Zig. The detailed decision and exact fingerprints are retained in
`fuzzy-bounds-v1-*.json`; unrelated performance gates remain open.

## Media and command diagnostics

Completed media batches now report bytes, atomic-frame forwarding/discarding,
direct/file loads, resets, failures and ingestion duration. The main thread
records graphics payload bytes, image metadata and placement deliveries only
after enqueue succeeds. Process inspections/misses and command candidate bytes,
accepted/dropped captures, observation resets/failures and host-sample duration/age
are also wired. Instrumentation is compiled out of default Release.

`media-telemetry-v1-{asan-live,release-live,headers}.json` verifies a real atomic
file-to-shared-image workload, absent default-Release logging and nine independent
headers. `observation-telemetry-v1-{asan-live,headers}.json` adds an interactive
shell, a CWD change and exit capture, and eight independent headers. The live
sample reports six accepted captures, 136 candidate input bytes and no observation
failures or dropped captures. Release and ASan/UBSan runtime/diagnostic suites
pass; worker tests cover sealed-batch isolation, overflow reset and rejected
history submissions. Source and executable fingerprints are frozen under
`/tmp/telar-cpp-{media,observation}-telemetry-v1`.

## Exhausted identity counters

`identity-boundaries-v2-{release,asan}.json` checks the last two workspace,
tab, pane and generation counters through real requests. All eight scenarios
now match Zig, including exact failure codes/messages and a subsequent client
query proving the runtime remains responsive. Slot storage accepts the final
nonzero identity and retains zero as an exhausted-counter sentinel. Restoring
an older counter cannot reopen an exhausted sequence. Tab allocation rejects
zero before mutating a workspace. The original report exposes a missing tab
response and premature pane/workspace exhaustion; v1 fixes tabs and generation
failures, and v2 completes the remaining four cases. Release and ASan/UBSan
runtime suites pass.

The restart check also records a reference limitation: after a counter wraps to
zero, both runtimes write a checkpoint that their reader rejects. Those extreme
workspace/tab/pane scenarios restart with an empty session. This is observed
parity with an existing defect, not a claim that exhausted sessions persist.
The reports retain the written counters and explicit restart result.

## Small Zstd decoding

The complete-frame allocation optimization passes 3,662 actual-Zig decoder
cases and the Release/ASan/UBSan runtime suites. Small Zstd now wins 7/7 against
both previous C++ and Zig; the other decoder controls have no consistent loss
against previous C++. The final binary retains 7/7 wins in all ten terminal
modes and the 1,000-query path workload against Zig. Reports and the explicit
acceptance decision are `zstd-capacity-v1-*.json`. Small Brotli and the remaining
whole-runtime performance gaps are still open.

## Actual Desktop session lifecycle

`check_desktop_session.py` compiles Desktop's actual `RuntimeConnection`,
`TerminalScreen` and login-shell selection with Qt Core/Network. Release and
ASan/UBSan runtime checks pass with `/bin/sh`, `/bin/bash` and `/bin/zsh`.
Hidden two-tab preload, styled Unicode input, resize, scrollback, tab switches,
hide/show, shell splits, shell tabs, closure and forced client reconnection all
pass; encoded owned-cell snapshots match Zig byte for byte. This does not
validate native windows, Spaces, Qt Quick or GPU rendering.

The first fixture exposed a shared Desktop defect: pending-tab lookup treated
the default target zero as a literal tab, closing preload after its first
snapshot. Zero now selects any target of the requested kind. Both runtimes
failed before the client fix and pass afterwards. Frozen probe sources and
hashes are under `/tmp/telar-cpp-desktop-session-v3`; reports retain the failed
v1/v2 runs and successful v3 runs.

## History queue ordering and import admission

Interactive first-page searches can be superseded by a later compatible search
from the same client in the current worker batch. Other requests and writes are
ordering barriers; pagination, snapshots, entry lookup, distinctness, repeated
request IDs and control clients retain their reference behavior. The metadata
is computed on admission without decoding queued payloads again. Fifteen
deterministic worker scenarios cover eligibility, barriers and active work.

A live SQLite-lock fixture submits nine searches with stats/import barriers.
The previous C++ binary differs; the corrected binary matches Zig's 595-byte
response stream exactly. Imports now acknowledge queue admission immediately,
without a second worker completion reply. The previous implementation waited
for a blocked write and lost the fixture's import; the corrected Release and
ASan/UBSan binaries acknowledge while the lock is held and persist after it is
released. Accepted imports also survive client disconnect and runtime restart.
These acknowledgements confirm admission, not durable commit.

Release and ASan/UBSan runtime suites and three standalone headers pass. Source
and binaries are frozen in `/tmp/telar-cpp-history-queue-v3`; reports are
`history-queue-v{2,3}-*.json` and `history-admission-v1-*.json`.

## Desktop rendering, IME and keyboard

The additional Qt Quick fixture instantiates the actual `TerminalItem` and
`terminal_input` implementation, routes IME commits and Return through the real
connection, and lets item geometry resize the runtime terminal. It renders styled
Latin/CJK/emoji text at 800×480 and again at 960×540 using Qt's offscreen software
backend. Release and ASan/UBSan runtime results match Zig for encoded cells and
every rendered RGBA pixel. The retained PNGs were visually inspected. Native
Spaces/window integration and Metal rendering remain outside this fixture.

The source is frozen in `/tmp/telar-cpp-desktop-render-v{1,2}`. Reports and PNGs
are `desktop-render-v1-release` and `desktop-render-v2-asan` under
`measurements/experiments`. The shared test helpers also pass the three-shell
session fixture in `desktop-session-v4-release.json`.
