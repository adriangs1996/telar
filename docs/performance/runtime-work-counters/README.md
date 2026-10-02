# Runtime work counters

Stage 0 of the [access-cluster roadmap](../../plans/access-clusters.md) asks
for runtime event, flush, pane-slot, eligibility and delivery counts before any
delivery layout or scheduling experiment. These counters add that evidence to
the existing optional profiler (`-Dprofile-counts`). They change no traversal,
scheduling, layout, allocator, protocol or agent/session state.

Counts establish work performed. They do not establish frequency, CPU time,
cache misses or a speedup. A rate needs the scenario and its elapsed wall-clock
interval next to it; a ratio between two counts of the same run (work per
flush, slots per live pane) needs neither.

## Where the counts come from

The catalog is [`profiling.zig`](../../../src/core/profiling.zig), catalog
version 2. Each thread writes its own fixed bank
([`ProfileCounters`](../../../src/core/ProfileCounters.zig)) inside the root's
[`ProfileStore`](../../../src/core/ProfileStore.zig); a process built with
`-Dprofile-counts=true` and run with `TELAR_PROFILE_DIR=<absolute existing
directory>` writes `<pid>.profile.jsonl` when it exits. Every row names its
metric, unit, source and coverage. Nothing else was added: no second metrics
framework, no model field, no allocation.

All runtime work counters are written by the runtime's event-loop thread. In a
dump, sum a metric over all `count` rows: other threads leave these at zero.

Without `-Dprofile-counts` (and in every Zig test binary, whose root is the
compiler's test runner) `core.profiling.enabled` is `false`. Every new site is
either `core.profiling.add` with a constant, which is an inline function whose
body is behind `comptime enabled`, or a block behind
`if (comptime core.profiling.enabled)`, so the argument computations are never
analyzed either. The only code that remains in a disabled build is a
`comptime` block in `Runtime.zig` that fails compilation when an event tag has
no metric.

Counts are accumulated at loop boundaries from values the loop already has:
the pane and attachment tables' `count`, a mask's population count, and the
loop index where a scan returns. No counter is incremented per slot, cell or
byte, and none is atomic.

## Counters

### Events

| Metric | Unit | Exact meaning |
| --- | --- | --- |
| `runtime_event_<tag>`, one per `runtime_event.Event` tag (34) | events | Calls of `Runtime.update` with that tag, counted at entry before dispatch. Includes events whose procedure stops at a limit. `runtime_event_stopped` is counted before the stop completes; no flush follows it. |

A new event tag without its metric fails to compile.

### Flush

| Metric | Unit | Exact meaning |
| --- | --- | --- |
| `runtime_flush` | calls | Entries to `client_delivery.flush`. The runtime calls it once after every non-stop event; `IdleDelivery` fixtures and benchmarks call it directly. |
| `runtime_flush_passes` | passes | Delivery passes inside those flushes. A pass repeats only when a client was dropped during the previous one, at most `max_clients + 1` (33) per flush. |
| `runtime_pane_slots` | slots | Pane slots visited by the flush's media-and-damage pass, empty slots included: `PaneStore.capacity` (256) per flush. |
| `runtime_live_panes` | panes | Panes that pass reaches, read from `PaneStore.count` before it. The pass adds and removes no pane. Each reached pane gets `pane_graphics.startMedia` and `settleDamage`. |

### Delivery preparation

| Metric | Unit | Exact meaning |
| --- | --- | --- |
| `runtime_prepare` | calls | Entries to `Delivery.prepare`, including those that stage nothing. In the runtime only `client_delivery.pump` calls it, for each active client without a write in flight. |
| `runtime_pending_scans` | calls | Calls of `pendingAttachments`: the prepares that got past the stop, response, resync, clipboard, layout and proxy-status lanes to the cell lane. |
| `runtime_attachment_slots` | slots | Attachment slots those scans visited, empty slots included: `Attachments.capacity` (128) per scan. |
| `runtime_eligibility_checks` | calls | `Attachment.hasDelivery` calls in those scans: one per live attachment of the scanned client. |
| `runtime_eligible_attachments` | attachments | Checks that answered true, i.e. bits set in the pending mask. |
| `runtime_lane_offers` | calls | `Delivery.candidate` calls made by `prepareAttachment` on pending attachments, over every lane (cells, cwd, foreground, title, progress, exit, graphics), productive or not. Counted by the mask bits the lane cleared, so an offer whose preparation fails is still counted. |
| `runtime_foreground_slots` | slots | Pane slots `prepareForeground` scanned looking for an unattached pane's foreground, empty slots included: `index + 1` when it stages one, otherwise 256. Reached only by clients that requested runtime state, when every earlier lane staged nothing. |

### Commits

| Metric | Unit | Exact meaning |
| --- | --- | --- |
| `runtime_commits` | messages | `Delivery.commit` calls: staged messages committed immediately before their socket write, every effect (responses, layout, metrics, foreground, attachments). |
| `runtime_attachment_commits` | messages | Commits of an attachment lane: cells, cwd, foreground, title, progress, exit or graphics. These are the productive deliveries the eligibility scan exists for. |
| `runtime_cell_commits` | frames | Attachment commits that carry a cell frame or snapshot. |

A commit is not a completed write. A write that later fails closes its client;
its commit stays counted.

## Relationships

These hold exactly for any interval in a running runtime and are what the
fixture checks:

```text
Σ runtime_event_* − runtime_event_stopped = runtime_flush          (runtime only)
runtime_flush ≤ runtime_flush_passes ≤ 33 × runtime_flush
runtime_pane_slots       = 256 × runtime_flush
runtime_attachment_slots = 128 × runtime_pending_scans
runtime_pending_scans    ≤ runtime_prepare
runtime_eligible_attachments ≤ runtime_eligibility_checks
runtime_cell_commits ≤ runtime_attachment_commits ≤ runtime_commits
```

`runtime_eligibility_checks` equals the sum of live attachments over the
scanned clients. With every client attached to every pane, it is
`runtime_pending_scans × panes`.

## Interpreting a run

- **Flushes per event.** In the runtime it is 1 by construction. What matters
  is which tags produce them: `runtime_event_pane_output`,
  `runtime_event_pane_ingested`, `runtime_event_client_sent` and
  `runtime_event_cell_publication_due` are the interactive ones; ticks,
  completions and observation events are the rest. Each of them pays one flush.
- **Empty pane slots.** `runtime_pane_slots − runtime_live_panes` is the slot
  visits a dense pane list would skip in the media-and-damage pass.
  `runtime_foreground_slots` is a second pane-slot scan per prepared client and
  can dominate the first with several clients.
- **Eligibility yield.** `runtime_eligible_attachments / runtime_eligibility_checks`
  is how often asking an attachment finds work. A pending set maintained by
  transitions (roadmap stage 2) would replace the checks that answer no; this
  ratio bounds what it can save in checks, not in time.
- **Offer yield.** `runtime_attachment_commits / runtime_lane_offers` is how many
  offers to pending attachments end in a message. An eligible attachment is
  offered to each lane in order until one stages; offers to the cell lane that
  return null still projected and diffed cells (see `runtime_damage`,
  `runtime_scanned_cells`).
- **Idle cost.** In an idle runtime every event still costs one flush of 256
  pane slots, one prepare and eligibility scan per subscribed client, and one
  256-slot foreground scan per client that requested runtime state.

Never add percentages derived from different runs, and never read a count as
CPU time. Pair counts with uninstrumented ReleaseFast timing runs for that.

## What the counters do not cover

Reverified loops reached from `client_delivery.flush` that have no counter in
this change:

- `pumpClients`, `scheduleCellPublication` and `agent_snapshot.wanted` each
  visit the 32 client slots.
- `reportDroppedLinks` visits 128 attachment slots after every prepare, and
  `Attachments.cellDeadline` another 128 when the prepare stages nothing.
- `pane_closure.collect` scans pane slots only while an exited pane exists.
- `settleDamage` walks a dirty pane's observers.
- Safe builds run `Delivery.assertIdle`, which calls every lane's candidate
  for every non-pending attachment. It is excluded from
  `runtime_lane_offers` by construction, and absent from ReleaseFast.
- GUI, client and renderer work. They are the next task; the existing
  `gui_*`, `client_*` and `mesh_*` counters are unchanged.

## Validation

### Exact fixture, counts enabled

[`src/runtime_work_counters_main.zig`](../../../src/runtime_work_counters_main.zig)
is a program whose root opts into profile counts. It starts an `IdleDelivery`
runtime with two clients attached to the same three `/bin/sleep` panes and
checks, against `core.profiling.snapshot()` differences on the loop thread:

| Fixture | Stimulus | Checked |
| --- | --- | --- |
| idle flushes | 8 flushes, nothing pending | every flush and delivery counter: 2 prepares and scans per flush, 3 checks per scan, 0 eligible, 0 offers, 0 commits, 256 foreground slots per prepare |
| productive flush | a title change on one pane; the second client also owes that attachment a cell snapshot | 2 eligible, 5 offers (4 lanes to the title, 1 for the snapshot), 2 commits, 2 attachment commits, 1 cell commit, 256 foreground slots (first client only) |
| flush while sending | both writes in flight | 0 prepares and scans; the pane pass still visits 256 slots for 3 live panes |
| runtime events | the loop's real events through `Runtime.update` until both writes complete | every `runtime_event_*` equals the fixture's own tally; flushes and passes equal updates; slot identities above |

A mismatch prints each differing metric with its expected and counted value
and exits nonzero.

```sh
zig build test-runtime-work-counters -j1
```

The `test` step runs it too, after the parallel suites, because it spawns PTY
children. `check-programs` analyzes it with the other executables.

### Counts disabled

```sh
zig build test-runtime -j1
```

The backend suite runs the instrumented files with counting compiled out, so
existing delivery, ACK, generation and lifecycle tests cover the unchanged
behavior. A default `zig build` of `telar` checks the disabled program; a
`-Dprofile-counts=true` build checks the enabled one.

### Results

The original delivery was unvalidated. On the authoring machine (macOS 26.6.2 arm64, Xcode SDK,
Zig 0.16.0, rustc 1.88.0 as the rustup default), inside the agent's sandboxed
shell, every build that imports the backend failed before reaching the new
code, the unmodified `telar` program included:

- `zig build test-runtime-work-counters -j1` and `zig build -Dgui=false -j1`:
  `@cImport` of `libproc.h` in `lib/proclineage/darwin.zig` translated the
  `mach_msg_*_descriptor_t` structs as opaque and failed their size
  assertions, and the libc++ sub-compilation failed (`INFINITY` undeclared).
- `zig build test-runtime -j1`: the suite imports `telar-gui`, whose syntax
  highlighter needs a newer rustc than the installed 1.88.0.

These failures were not reproduced against the base commit, and running the
build outside the sandbox was not permitted, so their cause is not
established. The integration validation below supersedes that limitation.

### Integration validation (2026-10-02)

After retiring Reviews, remove its event metric and lane from the fixture:
there are 34 event tags and the productive flush offers 5 lanes in total.
On the coordinator's native macOS AArch64 toolchain (Zig 0.16.0):

```sh
zig build test-runtime-work-counters test-bench-placement test-runtime check-programs codestyle build-bench -j2 --summary all
```

71/71 build steps and 677/677 Zig tests passed. The counter executable matched
all four fixtures; the placement runner passed its 14 Python tests. Runtime
tests and the normal benchmark/program graph use counting disabled; the counter
fixture explicitly enables it. No application or runtime was reinstalled.

## Scenario commands

None of these are timing measurements. Use separate uninstrumented
ReleaseFast builds for time, alternate their order, and follow the
[measurement rules](../../../.agents/skills/perf-pass/measurement.md).
Choose `OUT` as an absolute scratch directory; the profile directory must exist.

### Idle flush, fixed shapes

The benchmark's two `IdleDelivery` shapes (2 clients × 8 panes and 1 × 32).
The benchmark picks its own iteration count, so normalize every counter by
`runtime_flush`.

```sh
zig build build-bench -Doptimize=ReleaseFast -Dprofile-counts=true --prefix "$OUT/bench" -j1
mkdir -p "$OUT/bench-profile"
TELAR_PROFILE_DIR="$OUT/bench-profile" "$OUT/bench/bin/telar-benchmarks" \
  --filter backend.delivery.flush_idle_2x8 --samples 1 --sample-ms 1
```

### Output flood with a headless client, and detached

The existing PTY workload in an isolated runtime
([`terminal_runtime_bench.py`](../../../tools/terminal_runtime_bench.py)). It
sets `TELAR_PROFILE_DIR` to its output directory, so the runtime's dump lands
there when the tool stops it. `--detach` repeats the workload with no client
attached.

```sh
zig build install headless -Doptimize=ReleaseFast -Dprofile-counts=true --prefix "$OUT/app" -j1
python3 tools/terminal_runtime_bench.py --binary "$OUT/app/bin/telar" --output "$OUT/flood" --mib 8
python3 tools/terminal_runtime_bench.py --binary "$OUT/app/bin/telar" --output "$OUT/flood-detached" --mib 8 --detach
```

The dump covers the runtime's whole life, from its start to `server stop`,
including startup and the handshake. Before turning a total into a rate,
record that interval for the same run (for example `ps -o etime= -p "$(cat
"$OUT/flood/runtime.pid")"` just before the tool stops it) and report it with
the scenario.

### Reducing a dump

```sh
python3 - "$OUT/flood"/*.profile.jsonl <<'EOF'
import collections, json, sys
totals = collections.Counter()
for path in sys.argv[1:]:
    for line in open(path):
        row = json.loads(line)
        if row["type"] == "count" and row["metric"].startswith("runtime_"):
            totals[row["metric"]] += row["value"]
events = sum(v for k, v in totals.items() if k.startswith("runtime_event_"))
flushes = totals["runtime_flush"] or 1
for metric, value in sorted(totals.items()):
    if value:
        print(f"{metric:40} {value:>14} {value / flushes:>12.2f}/flush")
print(f"{'events':40} {events:>14}")
EOF
```

Pass one process's dump at a time: the client's dump has no runtime counters,
but a directory may hold dumps of several runtimes.

## Next steps

1. Run the scenarios above with the agreed scenario set of the roadmap (idle,
   typing, sparse output, 1/4/8 visible panes, 8/64 live mostly hidden, two
   clients) and record counts per flush and per event, with elapsed intervals.
2. Pair them with uninstrumented ReleaseFast timing of the same scenarios.
3. Add the GUI, client and renderer counters the roadmap lists, in the same
   catalog.
