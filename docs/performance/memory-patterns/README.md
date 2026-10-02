# Telar memory patterns

The current code needs several allocation lifetimes. The proposed backing pool
should support bounded slabs for independently freed small blocks and page spans
for large contiguous buffers. Keep retained arrays, FIFO queues and scoped arenas
at their existing owners. A global circular allocator cannot express all these
lifetimes without retaining unrelated dead allocations behind live ones.

This is a source audit with current-build allocation measurements, not an accepted
allocator optimization. No production code or `slabheap.zig` was changed. Tests
ran offline; they did not start the user's application or contact Personal.
The startup allowance proposal is in [memory budget](../../plans/memory-budget.md).

The subsequent [access-cluster roadmap](../../plans/access-clusters.md) puts
consumer layouts and their update/read costs before allocator implementation.
The lifetimes here constrain backing storage; they do not establish the fastest
layout or allocation policy.

The [Codex–Fable agreement](../../plans/memory-design-agreement.md) further
distinguishes page backing from object placement. A page-backed segment can
contain multiple naturally aligned records; it need not put every large record
at page offset zero. Conversely, carving records contiguously is not a proven
universal placement policy. Compare natural packing and explicit placement with
reuse across segments, and count shared boundary pages, padding and retained
empty capacity. The [placement archive](../record-placement/README.md) preserves
Fable's idle-flush measurements; it does not measure production pool reclamation.

## Current measurements

[measurements.json](measurements.json) contains the executable hashes, commands,
source revision, fixture results and limitations. The baseline is `43567b04`,
Zig 0.16.0, ReleaseFast, macOS 26.6.2, AArch64. Existing dirty files are planning
documents and the standalone prototype; neither is a probe dependency.

Build into an isolated prefix:

```sh
zig build build-dod-probe build-bench -Doptimize=ReleaseFast --prefix /tmp/telar-memory-patterns.fnZXsC/A -j2
```

The existing [storage fixture](../../../benchmarks/client_storage.zig) reports:

| Measurement | Requested bytes | Live allocations |
| --- | ---: | ---: |
| Inline `client.Client` | 2,909,536 | Not applicable |
| Inline `ClientModel` | 2,087,088 | Not applicable |
| Model with no panes | 2,087,088 | 1 |
| Model with one 1x1 pane | 2,175,200 | 6 |
| Model with eight 1x1 panes | 2,791,984 | 41 |
| Model with 64 1x1 panes | 7,726,256 | 321 |

In this fixture each pane adds five allocations and 88,112 requested bytes.
The 1x1 geometry deliberately isolates much of the metadata cost. It is not a
real terminal memory estimate. Do not add `ClientModel` to `Client`: the latter
contains the former.

[GuiAdapter](../../../src/gui/GuiAdapter.zig) allocates an array of 17 clients.
Using this build's measured size, the array requests 49,462,112 bytes, about
47.17 MiB, before dynamic client payloads. This calculation describes reserved
inline storage, not touched pages, active clients or process RSS.

The existing [renderer probe](../../../src/gui/profiling_main.zig) produced:

| Fixture | Measured iterations | Warm allocations |
| --- | ---: | ---: |
| 22 terminal fixtures: retained, sparse, full, cursor, focus, theme, reattach, two-pane updates, one-pixel resize and image placements; two geometries each | 128 each, after 64 warmup iterations | 0 each |
| Two image-placement resolution fixtures | 128 each, after 64 warmup iterations | 0 each |
| Two font-change fixtures | 4 each, after 2 warmup iterations | 20 each |

There were 3,072 measured iterations across the zero-allocation fixtures.
The retained terminal fixture requested 25,222,486 live bytes at 73x40 and
40,595,286 at 153x40. It initializes two panes even for single-pane modes;
these totals include the renderer and both panes, and exclude native/GPU heaps.
The actual cell geometries differ from the requested 80/160-column viewport
widths because the renderer subtracts chrome.

The resize stimulus changes height by one pixel. Its zero count does not prove
that changing cell-grid dimensions allocates nothing. The image fixtures resolve
placements; they do not exercise decoding or runtime image transfers. No timing,
cache-miss improvement or whole-process zero-allocation claim follows from this
campaign.

## Patterns verified in source

| Work | Allocation shape and lifetime | Ownership and reclamation | Suitable structure |
| --- | --- | --- | --- |
| Process models and fixed tables | Large startup allocation; lifetime of runtime or client | Released at owner teardown | Startup reservation; compact columns for fields accessed together |
| Screen cells and damage | Contiguous arrays sized by geometry; kept across updates | Individual panes and attachments resize and die independently | Retained contiguous buffers backed by page spans |
| Render geometry, quads and shaping | Arrays reserve capacity; frames reuse it; font/geometry changes may replace it | Window-owned, with explicit resource rebuilds | Keep current retained storage; no new per-frame allocator |
| Input and PTY replies | Bytes/messages produced and consumed in order, within fixed capacity | Reader borrows a chunk until consumption | Existing bounded rings |
| History records | Header plus variable text/output copied into owned storage | Producer transfers to history worker; persistence releases it | Size-segregated allocations, or a whole-record allocation as already implemented |
| History query results | Variable arrays and strings; survive the query worker | Ownership transfers through a response to the consumer | Owned result storage; a result-scoped arena only if all references share its lifetime |
| Proxy capture | Body grows geometrically as fragments arrive; exchanges overlap | Tunnel workers transfer halves; join, timeout, cancellation and processing release them | Contiguous growable buffers under quota, with independent frees |
| Images | Large buffers or mappings; generations overlap | Retirement waits for outstanding leases/upload references | Page spans or shared mappings with explicit leases |
| VT scrollback | Page-granular growth and oldest-page recycling; reflow also reuses pages | VT owns page nodes, pins, backing and compression state | Preserve emulator page pools and integrate their backing into the budget |
| CLI catalog/scratch | Many strings are replaced or discarded together | Scope ends at catalog replacement or command teardown | Existing arenas, bounded by the operation's allowance |
| C libraries and Lua | Mixed sizes and reallocations; allocator must honor arbitrary lifetimes | C headers recover block length; hooks have process/VM lifetime | General bounded size classes plus large-block support |
| I/O task records | Short asynchronous work with completion-dependent lifetime | `std.Io` owns scheduler allocations outside the runtime heap wrapper | Audit the I/O allocator separately; no reset before tasks finish |

Evidence for the ownership transitions:

- [cell buffers](../../../lib/cellgrid/Buffer.zig) allocate a replacement before
  freeing the old geometry. [CellSync](../../../src/backend/runtime/attachment/CellSync.zig)
  retains acknowledged and projected buffers per attachment. One pane may have
  several viewers, each with independently retained storage.
- [RetainedCells](../../../src/gui/render/RetainedCells.zig) reserves separate
  metadata, primary and overflow arrays when geometry changes. Steady frames
  reuse them. The storage split already separates frequently compared metadata
  from bulk quad payloads.
- [history request construction](../../../src/backend/history/request_factory.zig)
  puts each `CommandFinished` header and all its byte slices into one aligned
  allocation. [Channel](../../../src/backend/history/Channel.zig) transfers the
  request; [Worker](../../../src/backend/history/Worker.zig) destroys it after
  persistence. Queue rejection instead frees it on the producer's path.
- [capture Buffer](../../../lib/exchangecapture/Buffer.zig) doubles capacity
  starting at 256 bytes, bounded by its maximum. Growth allocates and copies
  while both buffers coexist. [GenericHalf](../../../lib/exchangecapture/GenericHalf.zig)
  charges that overlap. [capture Channel](../../../src/backend/proxy/capture/Channel.zig)
  transfers ownership between workers and the consumer; FIFO delivery does not
  make all exchange lifetimes FIFO.
- [retained graphics](../../../src/client/graphics/retained.zig) releases an image
  only after its last lease. [GenericResourceStore](../../../src/client/graphics/GenericResourceStore.zig)
  can retain an obsolete generation while another is admitted.
- [WorktreeCatalog](../../../src/cli/WorktreeCatalog.zig) already uses an arena
  and resets it on catalog replacement. A reset is safe because this owner
  defines the lifetime; the same reasoning does not apply to the entire runtime.
- [C allocation blocks](../../../lib/cblocks/blocks.zig) add a length header and
  support `realloc`. [SQLite routing](../../../lib/sqlite/memory.zig) is available,
  but [main](../../../src/main.zig) currently installs it for musl release startup.
- [pane output](../../../src/backend/runtime/pane_output.zig) uses
  `std.Io.Select.concurrent`. [Heap](../../../src/core/Heap.zig) tracks allocations
  passed through its wrapper, not all scheduler or foreign-library storage.

The dependency pinned in [build.zig.zon](../../../build.zig.zon) was inspected
locally in `zig-pkg/ghostty-1.3.2-dev-5UdBC84MRwUm4UZ8gcDZ-4vBiye_KqGyGJpht6KayFbZ`.
Its `src/terminal/PageList.zig` has separate node, page and pin pools, preheats
four page nodes, and reuses the oldest standard page when scrollback reaches
its byte bound. Nonstandard pages need separate handling. `pageAllocator` uses
an OS allocator, while `src/terminal/page.zig` also provides direct mapping and
unmapping. Those backing allocations bypass an ordinary Telar GPA wrapper.
Compression retains virtual mappings while changing physical backing, so live
payload, reserved address space and resident bytes must remain separate metrics.

## Proposed pool structure

Start with a bounded page backing store whose charges survive object frees while
the pages remain retained. Keep metadata for allocation class, occupancy and
owner separately from application payload. Obtain pages from this store for:

1. Slabs divided into fixed-size slots for small and medium independent
   allocations. Each size class has available slabs; each slab keeps a free-list.
   LIFO is the initial reuse policy, matching the existing
   [SlabHeap](../../../lib/slabheap/SlabHeap.zig). Returning an empty slab to the
   backing store permits another class to use it.
2. Contiguous page spans for large buffers. Track lengths and release individual
   spans. Do not force image pixels and large geometry arrays through tiny-slot
   slabs. In-place growth is optional; moving growth must reserve its peak first.
3. Scoped arenas only for owners with proven collective teardown. These arenas
   obtain bounded backing from the same budget; they do not introduce another
   uncharged allowance.

This gives the prototype a role as backing storage rather than a global
append-only allocator. The structures for locating free contiguous spans and
the size-class boundaries remain measurement decisions. The current evidence
does not choose a buddy allocator, TLSF or a linear bitmap scan as the winner.

The existing slab heap puts a freed block into the freeing thread's slot and
searches other slots when allocation finds its own empty. Cross-worker frees
are a supported Telar flow, not an exceptional misuse. Any replacement must
reuse those blocks without accumulating a budget per transient worker. Compare
a bounded shared implementation first; introduce owner-local caches and batched
remote returns only if contention measurements justify them. Returning memory
must never fail by dropping a free when a transfer queue fills.

## Cache locality and LRU

There are two costs to measure separately: finding a free block, and accessing
the resulting application data. The renderer fixtures mostly reuse live arrays;
changing free-list order alone does not change how those arrays are traversed.
Preserving contiguous cells and the metadata/quad split matters to that access
pattern.

LIFO may favor recently touched free blocks, but free time is only a proxy for
cache residency. It does not establish hits. Compare an intrusive free-list
against a compact stack of free slot indices for the same slab workload before
adding separate index storage. Do not pad every small object to a cache line.
That trades payload density for separation whether the object needs it or not.

Actual LRU belongs to caches that know their access events. The GUI's
[texture eviction](../../../src/gui/image/pane_images.zig) already considers
last use and evicts only eligible textures. A general allocator cannot discover
an object's last read by the application. It also cannot overwrite a live
allocation just because that allocation is old.

Prior work illustrates why layout needs evidence. The nested hot-field grouping
in [DoD pass 3](../dod-pass-3/README.md) improved one idle-flush shape and regressed
another, so it was rejected. Cache-set conflicts were a hypothesis, not an
established cause. Repeating equal page-relative offsets across objects should
be tested rather than assumed to improve cache behavior.

## What still needs a trace

The ownership audit establishes independent frees, geometric growth,
cross-worker transfer and retained capacity. The current measurements do not
establish how often each occurs in a full session. Before fixing class sizes,
slab size, owner-cache depth or large-span policy, collect a bounded diagnostic
trace with request size/alignment, alloc/free/resize kind, allocation identity,
allocating/freeing worker, lifetime and backing retained at release. Record
metadata only, never captured terminal or model payloads. Disable tracing for
timing; instrumentation changes the allocation cost.

Exercise pane creation/closure, true geometry changes, long scrollback, history
commands and queries, overlapping captures, image replacement with delayed
leases, font reloads and disconnect/reconnect. Replay matching lifetimes against
the existing allocator and each candidate. Compare correctness, peak backing,
fragmentation, cross-worker reuse, allocation latency and supported cache/TLB
counters. Test macOS/Linux and AArch64/x86-64 before accepting an optimization.

The present recommendation is therefore structural: bounded slabs plus large
spans, with rings and arenas reserved for their proven lifetimes. Choosing the
fastest free-list representation or span allocator needs that trace and paired
measurements.
