# Runtime coverage after direct operations

Runtime requests now enter `Runtime.update`, decode in `client_events.handleMessage`,
and dispatch through the exhaustive switch in `application/requests.zig`.
The operation modules call runtime capabilities directly. Actor completions enter
that same `Runtime.update` switch and call concrete event functions.

The refactor removes the previous internal controller/executor/handler paths and
the parallel generic event coordinators used by mock-only tests. The replacement
coverage exercises runtime state, real socket pairs and real children. It does
not claim a one-to-one correspondence with assertions about mock callback order.

## Coverage map

| Removed family | Current proof | Contracts checked |
| --- | --- | --- |
| Request controllers, erased executors, command/query handlers and router callback table | [requests_test.zig](../../../src/backend/runtime/tests/requests_test.zig) | Correlated failures; stale requests; post-commit reply backpressure; rollback on registration failure; geometry ownership; deferred resize; graphics credit and connection scope; first shutdown initiator; notification reservation; agent-control validation; owned command text and pending correlation. |
| Generic client admission and handshake coordinators/ports | [client_events_test.zig](../../../src/backend/runtime/tests/client_events_test.zig) | Rejected negotiation closes its socket and releases its slot; shutdown refuses admission; exhausted client identities; transfer before first read; stalled handshake interruption without replacing borrowed storage. |
| Generic client-send coordinator/port | [client_events_test.zig](../../../src/backend/runtime/tests/client_events_test.zig), [events_test.zig](../../../src/backend/runtime/tests/events_test.zig) | Closing waits for the final socket borrow; failed writes release ownership; one-shot replies complete before disconnect; pane exit detachment follows publication; shutdown delivery precedes retirement. |
| Generic history response controller/port | [events_test.zig](../../../src/backend/runtime/tests/events_test.zig) | Matching generation and available queue receive owned results; stale/full queues dispose them; worker failure is inert; failures retain request correlation. The testing allocator checks disposal. |
| Generic input/response pumps and ports | [pane_events_test.zig](../../../src/backend/runtime/tests/pane_events_test.zig), [events_test.zig](../../../src/backend/runtime/tests/events_test.zig) | Scheduler rejection rolls back borrows and retains queued bytes; successful prefix completion preserves a suffix whose admission fails; failed writes clear their queue; stale completions cannot release a new generation's borrow. |
| Generic output pipeline, ingest and exit coordinators/ports | [pane_events_test.zig](../../../src/backend/runtime/tests/pane_events_test.zig) | Read/ingest failure releases storage; deferred resize commits before the next read; next-read admission failure releases its borrow; output observation admission precedes ingest; exit retires agent evidence; wait failure becomes a synthetic exit; final observation failure preserves retirement. |
| Generic observation coordinator/port | [observation_events_test.zig](../../../src/backend/runtime/tests/observation_events_test.zig), [pane_events_test.zig](../../../src/backend/runtime/tests/pane_events_test.zig) | Process and cwd projection; revision wrap; shell foreground; queued resume; clearing unknown processes; root agent identity; delayed screen evidence; exact completion sounds across Codex Stop hooks and PTY frames; failed observation admission releases its sealed batch. |
| Generic media coordinator/port | [pane_events_test.zig](../../../src/backend/runtime/tests/pane_events_test.zig), retained [media_projection.zig](../../../src/backend/runtime/entrypoints/events/pane/media_projection.zig), [shared_frame_test.zig](../../../src/backend/runtime/tests/shared_frame_test.zig) | Media borrow release and metrics; stale completion rejection; actor admission rollback; bounded transfer slots; generation replacement; parked transfer ownership; quota release; shared-memory adoption and reset invalidation. |
| Generic agent description/maintenance coordinators and ports | [agent_events_test.zig](../../../src/backend/runtime/tests/agent_events_test.zig) | Disabled descriptions preserve queued work; admission failure releases the actor slot; every generator status and invalid titles; manual-title authority against stale results; retired aggregate completion; maintenance failure/rearm failure preserve evidence; successful maintenance expires it. |
| Generic proxy observation adapter/port | [agent_events_test.zig](../../../src/backend/runtime/tests/agent_events_test.zig), retained [proxy_observation.zig](../../../src/backend/runtime/entrypoints/events/proxy_observation.zig) | All protocol/phase translations retain identity; receive and real enabled-proxy rearm failure are inert; stale generations and auxiliary traffic cannot create agents; Claude completion across HTTP/1.1 and HTTP/2. |
| Generic system-metrics and telemetry coordinators/ports | [observability_events_test.zig](../../../src/backend/runtime/tests/observability_events_test.zig), [performance_isolation_test.zig](../../../src/backend/runtime/tests/performance_isolation_test.zig) | Timer/admission failure leaves sampling available; value-owned samples commit and release single-flight state; pending sampling is not repeated by 100 ticks; telemetry shutdown retains an in-flight buffer until completion. |
| Generic shutdown coordinator and enum-dispatched application teardown | [instance.zig](../../../src/backend/runtime/instance.zig), [runtime_tests.zig](../../../src/backend/runtime/runtime_tests.zig) | Existing real startup rollback, idempotent teardown, endpoint ownership and persisted-session restoration remain connected to the concrete runtime. |

`RequestFixture` owns a real runtime and socket pairs. `EventFixture` adds a real
child whose actor borrows can be acquired explicitly. Scheduler failure uses a
separate `std.Io.Select` with `std.Io.failing`; it does not replace application
operations with callbacks or run a second copy of their policy.

## Validation and limits

`PATH=/opt/homebrew/bin:$PATH zig build test-runtime codestyle --summary all`
completed with **974 passing runtime tests, one skipped test, zero failures** and
**50/50 build steps** on 2026-09-21. This run includes the concrete teardown and
pane creation simplification. The final repository-wide report records the later
combined build and smoke checks.

The assertions test observable state and ownership rather than every internal
call ordering permutation from the deleted captures. In particular, the new
completion fixtures do not separately inject every telemetry formatting failure,
plugin effect authorization outcome, proxy capture decoding failure or native
allocator failure. Their capability-level tests remain, and the concrete event
functions preserve their ordering, bounds and cleanup paths. No performance
improvement is claimed from these tests; the performance probes report timings
without correctness thresholds.

Resource lifetimes remain explicit. PTY, media, history and external workers
still own their asynchronous work and use bounded queues. The generic resource
owners that remain share resource algorithms across concrete worker types; they
are not alternative request/event dispatch paths.

## Teardown audit

The later audit replaced `Select.cancelDiscard` with joined cancellation and an
exhaustive disposal switch for transferred results. Event storage now accounts
for every bounded producer category (563 slots). Client search wakes retain
their session slot until consumed, including after disconnection, so a queued
completion cannot outlive and multiply its capacity reservation.

[teardown_test.zig](../../../src/backend/runtime/tests/teardown_test.zig) adds six
real-selector regressions: queued socket/history/plugin/capture cleanup;
cancellation with the queue at capacity; retained job ownership; delayed search
retirement; failed search wake; and rejected search scheduling. These tests
inspect socket closure, allocator/quota release and exact client generations.

The final combined run in [README.md](README.md) includes **979 passing runtime
tests and one skipped test**, after those six regressions and removal of the old
test that repeated the event-capacity formula.
