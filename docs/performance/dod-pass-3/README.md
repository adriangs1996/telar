# DOD pass 3: the flush after every update, and what the refactor cost

Measured on 2026-09-25 on `refactor/libraries`, Apple M3 (4P+4E, 128 KiB L1D
per P core), macOS 26.6.2, Zig 0.16.0, ReleaseFast. Timings are paired and
alternated; "wins" counts pairs where the candidate was faster. The host was
shared (load average 2 to 7), so pairs, not absolute values, are the evidence.

Builds:

- `P`: `4988caf5`, the tree the second pass left, before the procedural
  model and library refactor (134 commits).
- `A`: `3093b361`, the refactored tree this pass started from.
- `A3`: `56544450` plus the new delivery benchmark, the baseline for the
  flush work (the benchmark did not exist before).
- Final: `526ef693`.

## What the refactor cost

`P` against `A`, 6 pairs, every benchmark. Most cases were neutral or faster
(`schema.decode.*` -14%, `frontend.multiplexer.compose_four` -6.3%,
`patch_one_cell` -8.4%, 5/6 or 6/6). Three regressed in every pair:

| Case | P ns | A ns | Paired | Wins |
| --- | ---: | ---: | ---: | ---: |
| backend.damage.one_cell | 97 | 107 | +9.8% | 0/6 |
| backend.damage.fragmented | 3,432 | 3,701 | +7.7% | 0/6 |
| backend.frame.fragmented | 4,598 | 4,839 | +5.4% | 0/6 |

Cause, from the disassembly of `collectSpans` (278 instructions in `P`, 300
in `A`): moving the damage scan into `lib/vtgrid` turned the comparison
counter from a local that the disabled profiler let LLVM delete into a field
of the returned `Diff`, so the inner loop gained an `add` per compared cell
plus register moves. `collectSpans` now takes a comptime `Counting`; its inner
loop is again instruction for instruction the one in `P` (`a21922c3`):

| Case | A ns | B ns | Paired | Wins |
| --- | ---: | ---: | ---: | ---: |
| backend.damage.one_cell | 108 | 92 | -13.6% | 6/6 |
| backend.damage.fragmented | 3,720 | 3,466 | -7.1% | 6/6 |
| backend.frame.fragmented | 4,910 | 4,592 | -6.0% | 6/6 |

Against `P` the same build is at parity or better (`one_cell` -5.6%, 6/6).
A seeded test runs the scan with and without counting and requires identical
spans and statistics.

The GUI probe (`P` against `A`, 7 pairs) gave 2 to 5 wins in most modes on a
host at load 4 to 5 and supports no conclusion; this pass changed no GUI code.

## Correctness fixes

- **A scrolled client never saw rows it shares with the live screen**
  (`6df70975`). ghostty's `RenderState` states it is "the only consumer of
  dirty state" and clears the flags it reads. Each pane has two consumers:
  its own render state and the projected state of every client scrolled
  into scrollback. The pane renders first, so the new test showed a client
  scrolled one row up still reading `five` after the child rewrote it to
  `FIVE`. A pinned viewport now rebuilds whenever the pane rendered since
  its last projection (zeroing the state's row count forces the rebuild
  without reallocating rows).
- **Keys that ended the client** (`56544450`). Ctrl with a digit or
  punctuation (Ctrl+1, Ctrl+., Ctrl+=) returned `UnencodableControlKey` for a
  legacy child and `pane_input` propagated it until the client exited. The
  longest kitty key is 44 bytes and did not fit the 32-byte buffer. Legacy
  Ctrl now follows kitty's C0 table and sends other characters as text, as
  kitty and ghostty do; `keyinput.max_key_bytes` is computed from the field
  types; a key the protocol still cannot express is dropped.

## The flush after every update

`client_delivery.flush` runs after every runtime event, about seven times per
echoed keystroke, and no benchmark covered it. `backend.delivery.flush_idle_*`
(`879af7e2`) builds a real runtime whose clients subscribe to runtime state,
attach every pane and drain every delivery, so each flush walks the whole
path with nothing to send; the case fails if a flush starts a write.

Sampling the baseline put 70% of an idle flush in the eight attachment lanes
and 11% in hashing every pane's review owner.

| Change | Commit | 2x8 | 1x32 |
| --- | --- | ---: | ---: |
| One `hasDelivery` visit per attachment builds a mask the lanes follow | `7d586c14` | -17.9% (6/6) | -49.6% (6/6) |
| `prepareForeground` tests the observer bit instead of the index, and review discovery compares four revisions instead of hashing panes | `7d586c14`, `e022f523` | -11.7% (6/6) | -26.5% (6/6) |
| Rows iterated through pointers; lanes walk only the mask's set bits | `526ef693` | -39.0% (7/7) | -23.0% (7/7) |

Each row compares against the previous accepted build. The first row was
measured with the benchmark's first version, whose clients had not
subscribed to runtime state; subscribing them adds the agent, metrics and
foreground lanes a real TUI or GUI pays, and every later row and the final
comparison use that version. Against `A3`, the final build:

| Case | A3 ns | Final ns | Paired | Wins |
| --- | ---: | ---: | ---: | ---: |
| backend.delivery.flush_idle_2x8 | 1,090 | 476 | -55.4% | 6/6 |
| backend.delivery.flush_idle_1x32 | 3,023 | 1,179 | -60.7% | 6/6 |

Every other benchmark was neutral or faster; the cases with 0 or 1 wins have
identical medians and minimums at nanosecond resolution.

Oracles live in the code: safe builds (every runtime test) run each lane on
every attachment the mask skipped and assert it yields nothing; assert that
the observer bit agrees with the index; and still compute the review owner
hash, asserting it is unchanged whenever the four revisions are. The observer
assertion caught a test that attached one pane through two tables as the same
client; its fixture now uses another client slot.

## Disassembly findings

- `collectSpans`: a counter written to the returned struct cannot be
  eliminated; one kept in a local that only a disabled profiler reads can.
- `for (row) |slot|` over `record[client]` (a `[64]?*Attachment` reached
  through a pointer) copied the whole 512-byte row to the stack with
  `memcpy` before the loop; iterating `&record[client]` removes it. The
  telemetry loop copied all 4 KiB the same way.
- Scanning the probe binary for `memset`, `memcpy` and `bzero` of constant
  sizes of 16 KiB and up found only one-time lazy allocations (the 1 MiB atlas,
  the 675 KiB editor shaping cache), no per-frame copy.

## Rejected: the Pane's hot fields as one nested group

`Pane` is 705,112 bytes. The fields an idle flush reads for each pane sit in
about nine separate cache lines between offsets 4,376 and 705,108. Zig lays
out ordinary structs by alignment, so the only way to make them adjacent is
a nested group; `observers`, `dirty`, `render_pending`, `ingest_pending`,
`close_requested`, the cell, foreground, progress and graphics revisions,
`exit`, `agent_thread` and `launch_state` moved into `pane.hot` (about 260
access sites, rewritten from compiler errors). Against the previous accepted
build, 9 pairs:

| Case | Paired | Wins |
| --- | ---: | ---: |
| backend.delivery.flush_idle_2x8 | +11.5% | 0/9 |
| backend.delivery.flush_idle_1x32 | -10.2% | 9/9 |

The same split before the last lane change gave +5.6% (1/9) and -12.8% (9/9).
A consistent loss rejects it. The disassembly confirms the group works as
intended (the flush reads `pane+0xa8` to `pane+0xd6` instead of scattered
offsets), so the loss is not extra instructions. The suspected cause, not
established: `Pane` and `Attachment` are page-aligned large allocations, so
the grouped lines of every pane share the same L1 sets, where before they
spread over about nine. A dense column in `PaneStore` would give contiguous
lines instead and matches the table model; it needs the attachment to reach
the column without the pane record. The in-struct variant is kept outside
the tree as a patch.

`lib/vtgrid`'s search reads `pane.ingest_pending` by duck typing, so any split
of that field also has to change the library's contract rather than teach it
telar's layout.

## Findings left for a decision

- `tcgetpgrp` runs on every PTY output batch before ingest
  (`pane_output.zig:55`), not only per keystroke; the earlier pass measured
  it at 2.7 to 2.9 µs. Moving it changes which output counts as a shell
  command.
- Every `select.concurrent` allocates a task record, takes a mutex and may
  wake a worker: about three per keystroke in the runtime and two in the
  client. Persistent actors would remove them.
- GUI labels of 33 to 64 glyphs (a 40-character agent title) pass the shaping
  cache's byte limit but not its 32-glyph limit, so HarfBuzz shapes them on
  every frame they are drawn.
- Two `widget_interaction` GUI tests fail intermittently under the full suite
  and pass alone (5 of 5); cause not established.
- The tab layout snapshot cache keys on `(tab_id, revision, area)` and a
  rebuilt layout restarts at revision 1; returning to a workspace whose tab
  another client split may reuse stale geometry. Not reproduced yet.

## Validation

`zig build check test test-gui cross build-bench`: 282/282 steps,
3,571/3,572 tests (1 skipped) at `526ef693`; `codestyle` passes. New tests:
counting versus plain damage scans, the scrolled attachment, kitty's legacy
Ctrl table, every printable Ctrl key and the longest kitty key. `@ctz` and
`rotr` on `u64` are the only new target-dependent constructs; `cross`
type-checks Linux and Windows, and no x86 timing is claimed.
