# Global direct-operation refactor

Branch: `refactor/client-world-storage`. Local validation on macOS arm64 with
Zig 0.16.0. This extends the earlier host and split migrations across the shared
client, GUI/TUI event consumers and runtime requests/completions.

## Result to review

- `Runtime.update`, `GuiClient.update` and TUI `events.update` are the event
  entrypoints. Runtime requests and client replies use exhaustive concrete
  switches. Follow [the entrypoint map](../../entrypoints.md).
- Client `operations/` groups request, confirmation, recovery and delivery.
  Internal handler/executor/effects assemblies are removed. GUI/TUI, OS, VM,
  transport and actual asynchronous worker interfaces retain their boundaries.
- Runtime `application/operations/` owns concrete wire-request behavior;
  completion policy calls concrete state and scheduling operations.
- `Runtime.deinit` lists teardown in dependency order, with cancellation and
  worker joins before releasing borrowed state.
- Agent threads/history, change review, clipboard, configuration, Lua/plugins,
  notifications, pane/tab/workspace lifecycle and presentation are included.
- The headless fixture embeds a real `AttachedClient` and uses production
  dispatch, input, outbox and presentation-delivery operations.

This changes organization and call paths. It does not convert storage to SoA,
merge the two processes, alter the protocol or demonstrate a performance gain.

## Behavioral coverage

[Client coverage](client-coverage.md) maps removed handler families to current
model, GUI/TUI and concrete-operation tests. Tests of artificial callbacks and
externally constructed delivery commits are removed with those interfaces.
Actual asynchronous stale identities, full queues, allocation/launch failures,
committed state after delivery errors and resource ownership remain test cases.
Test counts therefore cannot be interpreted as a one-to-one coverage metric.

[Runtime coverage](runtime-coverage.md) maps request and completion families to
real runtime tests. A separate comparison of the client reply dispatcher found
the same 50 message tags and branch behavior after resolving the old adapter's
compile-time capabilities. Presentation retains the same token, location,
attachment-generation and frame validation before releasing graphics credit.

The teardown audit also found that `Select.cancelDiscard` could lose resource-
owning results already transferred out of a service queue. Cancellation now
drains completions and releases accepted sockets, history results, proxy
captures and plugin results; application-owned jobs remain with their owners.
Event capacity is derived from the bounded producer slots for every event tag
(563 slots, previously 480).
A closing client retains its slot until a scheduled search completion retires,
as it already does for outstanding reads and writes.

The real-process checks use temporary directories, private runtime sockets,
isolated data/config paths and `/bin/sh`. They stop their runtime and TUI during
cleanup and do not connect to the user's existing session.

- `runtime_smoke.py`: runtime status/metrics/proxy observation, workspace and tab
  creation/rename, PTY input/read/search/watch, diagnostics, closure and stop.
- `tui_smoke.py`: real PTY-attached TUI, sidebar, workspace list, config reload,
  plugin enable/run/disable, focus, fullscreen, layout, horizontal and vertical
  splits, close and detach.

Run after `zig build`:

```sh
python3 docs/validation/global-direct-operations/runtime_smoke.py
python3 docs/validation/global-direct-operations/tui_smoke.py
```

## Verification

Final checks on 2026-09-21, macOS arm64, Zig 0.16.0:

| Check | Result |
| --- | --- |
| `zig build -j4 test test-gui cross check-programs --summary all` | 143/143 build steps; 3,751 tests passed, two skipped, zero failures. Includes source style, shared-client boundaries and executable analysis. |
| `zig build -j4 --summary all` | 51/51 build steps; final executable built. |
| `zig build test-gui-window --summary all` | 3/3 steps; native macOS window, input and frame completion checks passed. |
| `python3 docs/validation/global-direct-operations/runtime_smoke.py` | Passed against the final executable. |
| `python3 docs/validation/global-direct-operations/tui_smoke.py` | Passed against the final executable, including both split axes. |
| `git diff --check` | Passed. |

The combined run includes 543 shared-client, 627 TUI, 746 GUI and 979 passing
runtime tests. The runtime suite has one additional skipped test. Six new
teardown regressions cover resource-owning queued results, a full event queue
during cancellation, model-retained jobs, and search completion/close/failure.

`cross` checks platform-dependent code for Linux x86_64, Linux arm64 and Windows
x86_64; it does not run Telar natively on those systems. No full manual GUI
session or comparative performance benchmark is implied by these checks.

Smoke scripts retain local `*.log` diagnostics beside themselves, excluded from
Git. All test-owned runtime, TUI and native-window processes were closed.
