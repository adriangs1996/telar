# Memory budget

The [access-cluster roadmap](access-clusters.md) now defines the measurement and
layout experiments that establish the pool's consumers and capacity needs.
Its [counter census](../performance/access-clusters/README.md) measures current
work per invocation; live execution rates remain a separate measurement step.

The [Codex–Fable design agreement](memory-design-agreement.md) recommends stable
segmented record pools, small preallocated hot columns and a flexible remainder
around protected mandatory resources. The total allowance and individual domain
capacities are separate decisions. Product defaults and admission guarantees
remain open; startup-fixed domain partitions are not an agreed requirement.

Status: draft, started with Adrian on 2026-10-01. The agreed scope is
Telar-owned memory; agent CLIs, shells, compilers and other child processes
are measured separately. Runtime and window budgets, admission guarantees,
pool layout and defaults below are proposals. This document assigns no
implementation work.

This resumes the pending discussion in `coordinator.md`, around lines
7598 and 11153. Follow [architecture](../architecture.md),
[invariants](../invariants.md), [naming](../naming.md) and
[source layout](../zig-source-layout.md). Add agreed domain terms to
[CONTEXT.md](../../CONTEXT.md) before implementation.

## Goal

A user chooses a memory budget at startup. Telar derives usable capacities,
reserves the resources needed to keep admitted work running, and reports
which budget prevents more work. Increasing a budget increases the relevant
capacity without editing unrelated constants.

An admitted pane must remain usable when optional media or observation work
exhausts its share. Closing a window must release its reservations without
affecting the runtime or its children.

## What to take from TigerBeetle

TigerBeetle computes worst-case object counts from startup arguments,
allocates those objects before the event loop, and relies on explicit bounds
throughout the system. Its architecture distinguishes this from a fixed
arena that can run out during normal operation.
[TigerBeetle architecture](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md#static-memory-allocation).

Its current CLI converts byte allowances into rounded object counts. The
experimental `--memory` option splits cache allowances; it is not presented
here as a verified cap on the whole process. Manifest and compaction memory
have separate options.
[TigerBeetle CLI source](https://github.com/tigerbeetle/tigerbeetle/blob/main/src/tigerbeetle/cli.zig).

For Telar, adopt startup capacity planning and resource guarantees for the
interactive path. Keep bounded worker allocations for media and observation,
as the existing invariants allow. Do not promise zero allocations throughout
Telar or copy TigerBeetle's cache sizes and percentages into a terminal.

## Current mechanisms and gaps

These are source observations, not measurements of a running instance.
The follow-up [memory pattern audit](../performance/memory-patterns/README.md)
records current-build offline allocation measurements and the ownership patterns
that determine which pools, retained buffers, rings and arenas fit each flow.

| Domain | Existing mechanism | Budget work |
| --- | --- | --- |
| Runtime tables, panes and attachments | [RuntimeModel](../../src/backend/runtime/RuntimeModel.zig), [PaneStore](../../src/backend/pane/PaneStore.zig), [CellSync](../../src/backend/runtime/attachment/CellSync.zig) | Count inline capacity, then include per-pane, per-client and per-attachment backing storage |
| Terminal screens and scrollback | [Pane](../../src/backend/pane/Pane.zig), [pane defaults](../../src/backend/pane/pane_namespace.zig) | Derive admitted pane capacity and aggregate scrollback allowance; account for supported geometry and resize peaks |
| Runtime graphics | [GraphicsLimits](../../src/backend/media/GraphicsLimits.zig), [GraphicsBudget](../../src/backend/media/GraphicsBudget.zig), [PaneMediaAllocator](../../src/backend/media/PaneMediaAllocator.zig) | Nest existing logical quotas inside the runtime budget; include retained allocator backing and outstanding image leases |
| Proxy capture | [Config](../../lib/exchangecapture/Config.zig), [Quota](../../lib/exchangecapture/Quota.zig) | Reuse reservations; count queues, working buffers and decoding as well as retained capture payloads |
| History and SQLite | [history runtime](../../src/backend/runtime/resources/HistoryRuntime.zig), [SQLite memory hooks](../../lib/sqlite/memory.zig) | Bound caches, queries and batches; verify allocator coverage on each platform and account for C block headers |
| Client replicas and GUI | [ClientModel](../../src/model/state/ClientModel.zig), [GuiAdapter](../../src/gui/GuiAdapter.zig) | One window allowance shared by its machine clients, retained frames, rendering buffers, fonts and review UI |
| Lua and plugins | [Lua limits](../../src/lua/Limits.zig), runtime resources | Include enabled instances and bounded results within their owner's allowance |
| Process heap | [SlabHeap](../../lib/slabheap/SlabHeap.zig), [entry point](../../src/main.zig) | Bound backing allocations and size-class retention, not only live requested bytes |
| Diagnostics | [runtime telemetry](../../src/backend/runtime/observability/telemetry.zig), [Limit](../../src/core/Limit.zig) | Extend existing metrics and stable limit reports instead of creating another reporting system |

The default scrollback bound is 10,000,000 bytes per pane. Combined with the
256-pane hard maximum, that permits 2.56 GB of scrollback alone. This is a
capacity calculation, not an observed allocation or RSS figure. Runtime
graphics has a separate default ceiling of 512 MiB. Neither limit currently
expresses a complete runtime budget.

The GUI allocates an array of `machine_slots` clients at initialization.
`machine_slots` is the 16 saved profiles plus the local client. Include all
17 inline client slots in the current fixed cost, even when most profiles
are unused. Measure that cost before deciding whether to change the storage.

`SlabHeap` reuses freed blocks but has no aggregate byte ceiling and retains
small-allocation slabs. It currently serves musl release processes; do not
assume it serves the macOS application. A quota wrapped around requested
bytes can return credit on free while the underlying allocator retains the
slab. That does not bound retained backing memory.

## Budget ownership and configuration

Propose one startup CPU-memory allowance per runtime instance and one per
GUI window. A headless client uses the same client-side accounting without
rendering allocations. Existing per-pane and per-feature limits become
subquotas where they describe memory; protocol and safety bounds remain.

Media and observation consume portions of the owner's allowance. They do
not receive additional memory outside it. Start with these two public
allowances and measured defaults. Add advanced overrides only when a real
workload needs them. Configuration names and values remain open.

Each fleet runtime enforces its own allowance on its own machine. The window
charges all its local and remote client replicas to one window allowance.
Remote runtime memory does not consume the local window's budget. A fleet
view may summarize each machine's usage without presenting the sum as one
local limit.

The initial proposal configures the owner allowance at startup. Whether changing
that total requires restart is a product/lifecycle decision still to settle.
Growing or releasing a domain's segments within an unchanged total does not
require a change of allowance. Ordinary configuration reload must not silently
restart a runtime or invalidate existing reservations.

## Account for backing memory

The budget ledger counts fixed owned storage plus allocated pool backing,
including alignment, metadata, fragmentation and retained free blocks.
Allocate backing only after obtaining credit. Release that credit only when
the backing is actually returned, not when one object inside a slab dies.
Preallocated pools keep their charge until teardown.

For each owner, report separately:

- Configured allowance, charged backing and peak charged backing.
- Live payload bytes, reusable pool space and pending reservations.
- Process RSS and reserved virtual address space.
- GPU resources, shared mappings and allocations outside routed allocators.
- Child-process memory, with its sampling scope and availability explicit.

Live bytes are part of backing bytes, not another quantity to add to them.
Each backing allocation has one charge; subquota usage classifies that
charge rather than adding it again to the parent's total. Distinct copies
in two processes are charged to their respective owners. Shared image
storage remains charged to its owning runtime until its last lease returns;
clients report their mapped view separately.

This bounds the storage under Telar's accounting. It does not make process
RSS equal the configured allowance. Audit stacks, I/O infrastructure, C
libraries, native window services and GPU resources explicitly. GPU
allocations need their own size and eviction accounting; report shared CPU
and GPU backing without counting it twice on unified-memory hardware.
List uncovered allocations until they have an enforceable bound. Do not
advertise a whole-process guarantee while that list contains unbounded work.

Reserving virtual address space can avoid moving a pool. It neither proves
physical memory is available nor prevents page faults. Decide separately
which admitted interactive buffers must be initialized and touched before
use. Mapping and fault costs belong in the latency validation.

## Derive capacities before admitting work

At startup, subtract fixed storage and a bounded control reserve from the
allowance. The control reserve covers limit reporting, teardown, cancellation
and recovery work. Optional features cannot borrow it.

The recommended hybrid protects mandatory reservations and any chosen startup
minimums, then shares the remainder between further admissions and optional
data. Fixed per-domain partitions are an alternative, not a consequence of
having a fixed total. Derive counts from complete per-item costs, including
indexes and allocator overhead, using checked arithmetic and allocation-granularity
rounding. Do not select arbitrary percentages before the inventory exists.

Large record pools grow in stable segments at admission boundaries; charge the
whole mapped segment before use. Slots are reusable, and only releasing backing
returns global credit. Small hot columns may reserve an inventory-validated
maximum at startup. The per-pool formula below applies to assigned capacity;
multiple flexible pools cannot each claim all remaining bytes simultaneously.

For a fixed-size resource:

```text
usable_bytes = pool_allowance - pool_metadata
capacity = min(safety_maximum, floor(usable_bytes / full_item_cost))
```

Variable payloads use aggregate byte pools instead of the largest possible
payload embedded in every row. Rows keep ids or offsets and lengths; worker
completions retain the existing id and generation rules. Reuse current
bounded storage and reservation mechanisms where their ownership fits.

Keep hard bounds for ids, parsers, message lengths and compatible wire
schemas. A larger memory allowance cannot silently widen the wire format.
Tables that remain fixed contribute a fixed cost; converting every constant
into a configuration option is not required.

Admitting a pane reserves its mandatory PTY queues, screen storage and the
resources needed for supported steady-state operations. Geometry and resize
rules must state what is guaranteed. A resize that needs more capacity
obtains it before replacing the old storage. If refused, keep the old screen
and report the limit. A larger scrollback target may use optional capacity;
its exhaustion removes only the oldest scrollback, not the live screen.

Plan attachments and reconnect snapshots alongside panes. Pane count alone
does not bound the cost of multiple clients viewing the same pane. Refuse
new admissions before spawning children or partially publishing a client.
A startup budget below the measured minimum fails with the required size.

## Exhaustion and concurrency

| Operation | Proposed result at its limit |
| --- | --- |
| New pane, attachment, machine client or worker job | Refuse that admission and release its partial reservations |
| Extra scrollback | Retain the allowed tail; report discarded history |
| New image or larger decode | Refuse optional media; keep text terminal operation |
| Capture or observation batch | Apply the existing truncation/drop policy and count the loss |
| Rebuild of a client frame or cache | Keep the last valid frame; reclaim disposable caches before retrying |
| Cancellation, limit reporting or teardown | Complete using the control reserve |

Reserve before allocating, roll back on failure, and transfer ownership
without losing or duplicating the charge. A moving reallocation may need
both old and new backing at once. Shrinking returns credit only if the
allocator releases that backing. Outstanding leases stay charged after an
image is retired.

Worker reservations must be race-safe. Multi-level reservations either
succeed together or undo every acquired share. Bound worker concurrency and
per-client usage so one slow client cannot consume all recovery capacity.
Keep reservation locks and blocking reclamation off the interactive path.

Use existing named limit notices and `resource_limit` responses.
`Limit.declare` already accepts a runtime value with a stable name. Budget
refusal must be distinguishable from actual host allocation failure; never
map every allocator `OutOfMemory` to `LimitError` or infer the cause from a
racy usage counter. Preserve the existing `SystemError` path.

Steady-state interactive work must keep the existing zero-allocation
contract. Provision rings, buffers and slots before admitting work; prove
the contract using the existing allocation counters. Bounded worker
allocations remain allowed. A general allocator with a byte cap alone does
not establish the interactive guarantee.

## Implementation sequence

1. Inventory and measure the current build. Extend the existing offline
   [layout probe](../../src/gui/profiling_main.zig) and runtime telemetry as
   described in [measurement](dod-measurement.md). Record executable hash,
   target, optimization mode, terminal geometry, enabled features, live panes,
   attachments and connected machines. Separate inline bytes, allocator
   backing and RSS; never sum nested `@sizeOf` results. Deliver a ranked
   ownership table, uncovered allocations and minimum viable budgets.
2. Define the startup sizing calculation and budget ledger. Reuse current
   quota mechanisms where possible, keeping policy in model fields and
   procedures. Prove backing accounting, rollback and host-error separation
   before changing admission. Keep existing feature limits during migration.
3. Migrate the largest measured costs first. Replace repeated variable
   payload arrays with bounded shared storage where justified. Reserve pane,
   attachment and recovery capacity together. Integrate graphics, capture,
   SQLite, Lua and client rendering without changing wire bounds by accident.
4. Expose startup configuration and diagnostics after the ledger covers the
   supported paths. Select defaults from measured workloads and document the
   minimum, resulting capacities and feature tradeoffs. Mark remaining
   platform-owned memory separately.

Do not begin with a process-wide allocator replacement or raise all limits.
The first deliverable is the measured ownership and capacity table.

## Acceptance evidence

Use isolated runtimes and test clients. Planning and measurement do not
require restarting the user's application or contacting Personal.

- Below-minimum startup fails before any children start. Checked arithmetic
  rejects overflow, and rounding never exceeds the allowance.
- Concurrent reservations, reallocations, cancellation and cross-thread
  frees never exceed charged backing. Allocation failure restores credit.
- Repeated create/destroy and history batches reach a bounded backing plateau,
  including retained slabs. Payload counters returning to zero are insufficient.
- Exhaust media and observation while typing and flooding terminal output.
  Interactive allocation counters remain zero and latency stays within the
  existing measured acceptance bounds.
- Exercise resize, disconnect, reconnect and slow clients at exhaustion.
  Existing panes remain valid; stale work releases its reservations exactly once.
- Exercise 1/4/8 visible panes, 8/64 live panes with most hidden, multiple
  attachments, and local plus remote client replicas. A window never grants
  a full new budget to each machine.
- Cover C allocator hooks, enabled plugins, shared image leases and native
  graphics resources on macOS and Linux. Record unavailable metrics explicitly.
- Changing budget configuration does not restart live runtimes. Teardown
  returns owned storage and leaves child lifetime under existing runtime rules.

## Decisions still needed

The scope is agreed. Review the proposed runtime/window split, startup-only
sizing and guaranteed interactive capacity before implementation. The
inventory determines default byte values, guaranteed pane/geometry capacity,
scrollback distribution and the first tables to migrate. Cache eviction and
fairness policies must be specified per flow rather than delegated to a
generic allocator.
