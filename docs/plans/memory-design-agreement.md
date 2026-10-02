# Memory design agreement

Technical recommendation reached by Codex coordinator, Telar pane 572, and
Fable, pane 585, on 2026-10-01 at Adrian's request. Two substantive rounds
examined the accounting and allocation mechanisms; Fable explicitly accepted
the written agreement in the [final review](../performance/record-placement/discussion/fable-final.md).
Product parameters listed
below remain proposals for Adrian; this is not an implemented memory guarantee.

Evidence: [access census](../performance/access-clusters/README.md),
[allocation census](../performance/memory-patterns/README.md),
[Fable's placement experiment](../performance/record-placement/README.md).
The [discussion](../performance/record-placement/discussion/) preserves both
authors' messages, including positions corrected during the debate. This
agreement is the resulting recommendation, not every claim in those messages.

## Three separate decisions

Capacity policy determines how many entities Telar can admit. Canonical layout
determines how fields are stored. Derived representations serve consumers with
different access patterns. These decisions interact through memory and update
cost, but configurable capacity is not a second representation of the same data.

Move fields into a suitable canonical table when that satisfies the readers.
Duplicate only for a concrete additional consumer with an explicit ownership,
revision, invalidation and lifetime contract. Measure reads saved against
rebuilds, write maintenance, copies, retained capacity and latency tails. A pool
supplies storage; an allocator does not silently transform arbitrary objects.

## Accounting

Recommend one CPU backing allowance per runtime and one per window. The window
covers all its machine replicas. Keep a bounded control reserve unavailable to
optional work so refusal, cancellation, teardown and recovery remain possible.

Charge each mapped writable segment in full, including padding, allocator
metadata, unused slots and retained free space. Charge it once at the owner;
domain subquotas classify that charge rather than adding it again. Slot reuse
inside charged backing does not consume another global backing charge.

Returning a slot creates reusable space, not free global budget. Credit returns
when backing is actually released. For the initial segmented design, that means
returning a whole empty segment through the allocator's platform release
operation. Retaining an empty segment retains its charge. Future partial
decommit requires a separately verified platform mechanism and accounting.

Track reserved virtual address space, charged writable backing, live payload
and RSS separately. GPU residency, shared mappings, native/foreign allocations
and child processes need explicit coverage and separate metrics; do not double
count shared CPU/GPU backing or advertise a full-process ceiling with unbounded
uncovered allocations.

Zig 0.16.0 `page_allocator.rawAlloc` uses a writable anonymous mapping on the
inspected macOS path. It is not an explicit reserve-then-commit API. First-touch
faults do not notify the ledger. Mapping a safety maximum with this API and
charging only touched slots would violate the proposed accounting rule.
Skipping safe-build initialization does not change that fact. Explicit virtual
reservation/activation/deactivation remains a separate mechanism to evaluate.

## Storage and lifetime

- Large independently lived records use typed pools made of stable segments.
  Map another segment only at an admission boundary and only after obtaining
  credit for the entire segment. Records never move while borrowed.
  Choose segment size per pool from churn measurements, including the first
  admission's full segment charge, release frequency and live-record page
  offsets at each size. A larger segment increases both admission and release
  granularity; no default segment size is selected by this agreement.
- Slots are reusable through a bitmap or free structure. Prefer existing
  non-full segments before growing; compare occupancy-aware selection policies
  under churn. A policy that concentrates occupancy can let other segments
  become empty, but its locality and allocation costs must be measured.
- Small hot columns may reserve their validated effective maximum at startup,
  charged in full, so their scans stay contiguous. At current bounds that may
  be the safety maximum. The inventory must establish affordability per table;
  this is not a rule to preallocate every product maximum or large payload.
- Stable IDs and generations identify rows and asynchronous work. Hot-column
  structural edits belong to the owning event loop. Large cold records,
  asynchronous borrows and graphics leases keep their existing lifetime rules.
- Reserve/address placement and field grouping are separate experimental
  factors. Placement policy is per pool and considers global slots across
  segments. Repeating identical offsets at every segment boundary must be
  visible in reports; do not inspect only the first segment.

Natural-stride packing and padded placement are candidates, not guaranteed
optimizations. Padding one 16 KiB page is 1.96% of the measured `Pane` size and
38.52% of `Attachment`, before allocator rounding. They need not use the same
policy. Do not hardcode M3 cache geometry as a universal production rule.

## Admission and guarantees

Recommend protected mandatory resources plus a flexible remainder. A fixed
total allowance permits redistribution during execution without promising an
unbounded entity count. Fixed domain partitions remain an alternative product
policy; a memory budget does not require them.

Before spawning a child or publishing a new entity, reserve its complete
mandatory resources and any transaction/replacement peak. Reserve pane and
attachment costs separately. Initialize required interactive storage before
admission, measure its first-touch cost, and refuse transactionally if it does
not fit. Prefaulting is not a guarantee against later OS paging.

An admitted entity keeps its mandatory reservation. More panes or optional
features cannot take it away. Steady key, byte and frame loops do not grow pool
backing, rebuild whole tables to expand capacity, or perform blocking budget
reclamation. An optional cache miss uses bounded existing storage or its
reference path; growth is scheduled at a preparation/admission boundary.

Optional data must declare its reclaimability and outstanding leases. Data
that cannot be released within the admission boundary's bounded work cannot
be counted as immediately available credit. Expensive reclamation may finish
asynchronously before a later admission attempt. Dropping a cache object does
not help global admission unless it releases backing or makes already charged
storage reusable by the requesting owner/domain. No live-record compaction is
assumed for partially occupied segments.

Numerical guarantees require the inline-payload inventory first. The current
`Pane.media`, large session records and array of 17 inline clients can dominate
startup reservations. Moving optional payloads into shared pools is a candidate
that must preserve ownership, bounds and performance, not an automatic saving.

Wire, ID and platform bounds remain explicit until revised. Current integer
masks are replaceable implementation choices, not immutable product maxima.
A larger budget cannot silently widen a message, identifier or negotiated
schema. Changing effective capacities within existing bounds and raising those
bounds are separate changes.

## Experiment order

1. Preserve Fable's source, pairing scripts and results. Completed in the
   [placement archive](../performance/record-placement/README.md), without
   modifying production code or installing the benchmark wrapper.
2. Complete event/dereference counts and real workload CPU/frequency traces,
   alongside the inline-payload inventory. Include pane and attachment visits,
   empty-slot scans, first-touch costs and large reservations per owner.
3. Cross layout and placement. Minimum matrix: current/dense layout ×
   current/staggered placement. Extend with the previously rejected hot grouping
   and natural packing. Test idle, active output, mixed activity, hidden panes
   and independent clients. Never add independently reported percentage gains.
   Test pending-set scheduling as a separate factor.
4. Exercise pool churn, reuse, segment growth and release. Report live-record
   page offsets, mapped/retained backing, metadata/padding, peak overlap and
   admission latency. Include partially occupied segments and cross-domain
   pressure; no claim that every freed slot immediately returns backing.
5. Seek PMU evidence for the cache-conflict hypothesis where available; unknown
   causality is reported honestly and does not by itself invalidate repeatable
   timing gains. Validate target-specific policies on native Linux and x86-64
   before platform-wide claims.

Repeated review-search work, label shaping and renderer row/emission clusters
remain in the [access roadmap](access-clusters.md). Live CPU contribution and
reuse determine their priority relative to runtime placement. Idle-flush gains
are not a prediction of interactive FPS or perceptible keystroke latency.

## Product parameters still open

- Whether to adopt the recommended flexible remainder or fixed partitions;
  minimum guaranteed entities and geometry, if any, and default allowances.
- Guaranteed scrollback tail and behavior when resize requires more backing.
- Whether reclaimable optional data is evicted for new entities, and the order.
- How eagerly empty segments are released versus retained for fast reuse.
- Which current maxima to raise and the compatibility changes that entails.
- Whether to support changing the owner allowance without restart. The first
  budget plan recommends startup configuration; no live resizing or restart
  behavior is implemented or authorized by this discussion.

Counting retained backing is **not** an open product parameter. It follows from
the ceiling being a backing-memory ceiling.
