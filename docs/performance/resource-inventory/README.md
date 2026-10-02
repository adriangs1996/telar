# Memory resource inventory

This is a source-backed inventory of the CPU memory that Telar owns for the
runtime's `Pane`, `Attachment` and `Session`, and for the client execution
`Client` and its `ClientModel`. It covers fixed inline bytes, external buffers,
geometry formulas, shared resources, ownership, allocation and free sites, and
replacement peaks. From those it derives what admitting one pane or one
attachment costs. It is the inventory that the
[memory budget](../../plans/memory-budget.md) and the
[design agreement](../../plans/memory-design-agreement.md) require before any
numeric quota.

Base commit `23e9afc6117d7a561b96849f180061e37024144d`, a documentation commit
on top of production `43567b04484cade06cbebb645acf56dba3042bfe`. Line references
point at that tree. The ghostty-vt dependency is
`ghostty-1.3.2-dev-5UdBC84MRwUm4UZ8gcDZ-4vBiye_KqGyGJpht6KayFbZ`
([build.zig.zon](../../../build.zig.zon) lines 20-22), read from the Zig package
cache tarball (sha256 `4161bf5d…227a`). Zig's standard library is 0.16.0.

**Method.** Only source reading and arithmetic went into this inventory. No
compiler, test binary, size probe, runtime probe or benchmark was run. Every
number carries a status:

| Status | Meaning |
| --- | --- |
| archived | Printed by an earlier build. Provenance P1–P3 below; not re-measured here. |
| exact | Follows from byte arrays, constants or asserted sizes in source. |
| derived | Computed from source rules, such as allocator growth or layout, without compiler confirmation. |
| estimate | Assumes a Zig auto-layout or union size; needs `@sizeOf`. |
| unknown | Source reading cannot resolve it; the [next measurements](#unknowns-and-the-next-isolated-measurements) list what can. |

The machine-readable [ledger.json](ledger.json) holds every item with its source,
lifetime, allocation and free sites, and classification. [verify.py](verify.py)
re-derives each reconciliation and formula below and fails if any changes.

### Inherited measurements

| Id | What | Provenance |
| --- | --- | --- |
| P1 | `Pane` 836,696 B, `Pane.media` 203,640 B, `Attachment` 42,536 B, `Session` 1,096,256 B | Fable, pane 585, 2026-10-01. `reportPlacement()` in [benchmark.patch](../record-placement/source/benchmark.patch) lines 117-127, quoted in [fable-round-1.md](../record-placement/discussion/fable-round-1.md) lines 43 and 100-102. Apple M3, macOS, ReleaseFast, `43567b04`. The raw printout is not archived. |
| P2 | `Client` 2,909,536 B, `ClientModel` 2,087,088 B, `Tabs` 210,192 B, `Panes` 6,664 B, model `Pane` 488 B, and live storage for 0/1/8/64 panes | Codex, [measurements.json](../memory-patterns/measurements.json) `storage[]`, from [client_storage.zig](../../../benchmarks/client_storage.zig). `43567b04`, Zig 0.16.0, ReleaseFast, macOS 26.6.2 AArch64. |
| P3 | Renderer fixture live requested bytes: 25,222,486 at 73x40, 40,595,286 at 153x40 | Codex, [measurements.json](../memory-patterns/measurements.json) `workloads[]`, from [profiling_main.zig](../../../src/gui/profiling_main.zig) lines 124-259. Same build as P2. |

All three report inline sizes or allocator-requested bytes on AArch64 macOS.
None of them reports RSS, mapped bytes or allocator backing.

## Four quantities that are never added together

- **Inline**: `@sizeOf` of a record, the bytes inside its one allocation.
- **Requested**: the bytes passed to an allocator. This is what
  [Heap](../../../src/core/Heap.zig) counts (lines 60-91), and what P2 and P3
  measured.
- **Mapped**: writable anonymous mappings taken from the OS: page-allocator
  pages, pthread stacks, GPU shared buffers. Under the agreed accounting rule a
  writable mapping is charged in full, whether its pages are touched or not.
- **RSS**: resident pages. Nothing in this inventory derives RSS.

**Inclusive and exclusive.** A record's inline size includes its inline fields.
So `Client` (2,909,536) contains `ClientModel` (2,087,088), and `Pane`
(836,696) contains `Pane.media` (203,640) and the history observer's batches.
External buffers are exclusive of the record that points at them. Table pointer
arrays in `RuntimeModel` (`PaneStore.items`, `Attachments.record`,
`Store.items`) belong to the runtime's fixed model cost, never to a pane's,
attachment's or session's cost. The GUI's 17-slot array (49,462,112 B) is the
inline storage of all 17 `Client` records, initialized or not. It is counted
once per window, not once more per connected machine.

## Who sees which allocation

| Route | Path | What [Heap](../../../src/core/Heap.zig) sees |
| --- | --- | --- |
| Process allocator | Debug builds use `DebugAllocator`. Release builds linked to libc use `c_allocator` (Zig `start.zig` lines 690-712; the application links libc, [Application.zig](../../../build/Application.zig) line 107). Release musl builds use `slabheap` ([main.zig](../../../src/main.zig) lines 123-137). | — |
| Runtime GPA | `Resources` wraps the process allocator in `core.Heap` ([Resources.zig](../../../src/backend/runtime/resources/Resources.zig) lines 23, 51-52). Counting happens only when diagnostics are on (Heap.zig lines 25-38; [diagnostics.zig](../../../src/core/diagnostics.zig) lines 18-19). | Requested bytes when diagnostics are on. Never backing. |
| Client GPA | `Client` and the GUI take the process allocator unwrapped. | Nothing |
| VT page pools | ghostty `PageList.pageAllocator()` ignores the allocator it is given. It uses `page_allocator` on Linux and a tagged Mach page allocator on macOS (ghostty `PageList.zig` lines 543-555). | Nothing; nor does the graphics budget for the media terminal |
| Pane media | `PaneMediaAllocator` charges `GraphicsBudget` before forwarding ([PaneMediaAllocator.zig](../../../src/backend/media/PaneMediaAllocator.zig) lines 1-25) | Through its child, the runtime GPA |
| I/O tasks | `std.Io.Threaded` creates a `Future` per concurrent task through the process allocator and spawns pool threads with 16 MiB stacks (`Io/Threaded.zig` lines 2130-2170; `Thread.zig` lines 307 and 766). Telar sets no `stack_size` (no match in `src` or `lib`). | Nothing |
| GPU | Metal shared buffers and textures ([TelarMetalRenderer.m](../../../src/gui/macos/TelarMetalRenderer.m) lines 210-221, 335-343, 519-532), and Vulkan memory ([vulkan_resources.c](../../../src/gui/linux/vulkan_resources.c) lines 79-82, 150-162) | Nothing |

So no current counter equals charged backing. Even in a diagnostics build,
`Heap.live_bytes` misses VT pages, thread stacks, I/O futures, libc rounding
and every client-side allocation.

## Runtime `Pane`

**Lifetime.** [pane_launch.zig](../../../src/backend/runtime/pane_launch.zig)
lines 173-188 create the pane and line 204 inserts it into `PaneStore`
([PaneStore.zig](../../../src/backend/pane/PaneStore.zig) line 289).
`Pane.destroy` (Pane.zig lines 643-661) runs through `removeAndDestroy`
(PaneStore.zig line 304), or `removeExitedAt` once `readyToDestroy` holds
(Pane.zig lines 1311-1319; [pane_closure.zig](../../../src/backend/runtime/pane_closure.zig)
line 100). Actors borrow the pane's address until they drain, so the record
cannot move while it lives.

### Inline: 836,696 B (P1)

| Field ([Pane.zig](../../../src/backend/pane/Pane.zig)) | Bytes | Status | Source |
| --- | ---: | --- | --- |
| `output_buffer` | 16,384 | exact | Pane.zig line 85; pane_namespace.zig line 23 |
| `pty_responses`: 64 × 1 KiB, plus lengths | 65,664 | exact | PtyResponseQueue.zig lines 7-8 |
| `input_queue` | 131,072 | exact | PaneInputQueue.zig lines 13-16 |
| `media`: two batches and scratch | 196,608 | exact | Pipeline.zig lines 19-21; Batch.zig line 6 |
| `media`: batch events, 2 × 64 | 1,536 | estimate | media.zig lines 59-62 (12 B event) |
| `history_observer`: two batches | 262,144 | exact | Observer.zig lines 23, 406-407 |
| `history_observer`: batch events, 2 × 512 | 40,960 | estimate | observer_support.zig lines 52-60 and 416-428 (40 B event) |
| `history_observer.tracker`: OSC and command buffers | 73,728 | exact | cmdcapture OscTracker.zig lines 12 and 15; osc.zig lines 7-8 |
| `history_observer.tracker`: two cwd paths | 2,048 | exact on macOS | OscTracker.zig line 18; TerminalTracker.zig line 32. `max_path_bytes` is 4,096 on Linux, so this is 8,192 there. |
| `history_observer.sample` | 16,384 | exact | history Sample.zig lines 8-10 |
| `cwd`, `title`, `kitty_cursor.sizes`, `media_allocator.mappings`, foreground name | 7,472 | 5,424 exact, 2,048 estimate | CwdState.zig line 6; TitleState.zig line 10; KittyCursor.zig lines 35 and 46-51; PaneMediaAllocator.zig line 21; process Cache.zig line 9 |
| **Itemized** | **814,000** | | |
| Residual: three `vt.Terminal`, three `vt.TerminalStream` (each with a 2 KiB OSC buffer, ghostty osc.zig line 321), `vt.RenderState`, `cellgrid.Buffer`, the text-metadata header, scalars and padding | 22,696 | unknown | |

A pane does not hold one emulator. It holds three:

- the interactive terminal (Pane.zig line 66);
- the graphics-only terminal inside `media`
  ([Pipeline.zig](../../../src/backend/media/Pipeline.zig) lines 13-14 and 55-60);
- the history observer's terminal
  ([Observer.zig](../../../src/backend/history/Observer.zig) lines 19-20 and 52).

All three parse all of the pane's output
([pane_output.zig](../../../src/backend/runtime/pane_output.zig) lines 60-69).
Fable's printed `media` size of 203,640 minus its exact arrays leaves 5,496 B
for one terminal, one stream and scalars. That is consistent with the 22,696 B
residual covering three of each.

Of the 836,696 B, 747,648 (89.4%) are exact worst-case fixed queues and
buffers, whether or not the pane shows graphics, records history or receives
input: the input queue, the PTY responses, the media pipeline's arrays, the
history batches, the tracker buffers and the sample. With their estimated event
arrays the share is 790,144 B (94.4%).

### External buffers per pane

| Item | Quantity | Formula (C cols, R rows) | Status | Allocated / freed |
| --- | --- | --- | --- | --- |
| Screen cells | requested | `32·C·R` (Cell is asserted 32 B, [Cell.zig](../../../lib/cellgrid/Cell.zig) line 61) | exact | Pane.zig lines 259 / 650 |
| Damage rows | requested | `R` | exact | Pane.zig lines 261 / 648 |
| Text metadata, current and scratch | requested | `2·(87,563 + R)` ([limits.zig](../../../src/core/text_metadata/limits.zig) lines 2-17) | exact | [TextMetadataCapture.zig](../../../src/backend/pane/TextMetadataCapture.zig) lines 23-27 / Pane.zig line 649 |
| Workspace path | requested | `W` | exact | Pane.zig lines 176 / 646 |
| Launch record | requested | `L ≤ 131,072 + count` | exact | pane_launch.zig line 190, [LaunchRecord.zig](../../../src/backend/pane/LaunchRecord.zig) line 38 / Pane.zig line 647 |
| History output tail | requested | 65,536 if output capture is on | exact | cmdcapture TerminalTracker.zig lines 59-62 |
| `render_state` | requested | about `R·(C·c_rs + row overhead)`. A cell is raw 8 B + grapheme slice 16 B + Style about 14-16 B (ghostty render.zig lines 204-280), plus per-row arenas. | unknown | Pane.zig lines 1444 / 651 |
| ghostty gpa structures, three terminals | requested | Screen struct, 4 nodes, 8 pins, tracked-pin set, tabstops | unknown | ghostty ScreenSet.zig line 44, PageList.zig lines 349-353 |
| **VT page pools** | **mapped** | **three primary screens × 4·S to about 5.5·S at admission; three more pools when the alternate screen is first used** | **derived** | Terminal.init at Pane.zig line 210, Pipeline.zig line 55 and Observer.zig line 52 / terminal deinit only |
| Main scrollback pages | mapped | up to 10,000,000 B logical `page_size` plus pool slack, held at high water | derived | Pane.zig line 214; PageList.zig lines 400-410 |
| Worker threads | mapped | up to 2 × 16 MiB stack (`readPane` and `waitPane` block their pool thread, pane_launch.zig lines 117-128) | derived | Threaded.zig lines 2130-2170 |
| Parser growth | requested | per stream: OSC up to 8 MiB, DCS up to 1 MiB while a long sequence is open | derived | ghostty osc.zig lines 301-321, dcs.zig line 19, stream.zig lines 515-519 |
| Images | requested and mapped | ≤ 256 MiB per pane, 512 MiB global, charged by `GraphicsBudget` | exact bound | [graphics.zig](../../../src/core/graphics.zig) lines 19-21 |

**VT page pools in detail.** `PageList.init` builds a `MemoryPool` with
`page_preheat = 4` (ghostty PageList.zig lines 39 and 603-618).
`PagePool.initCapacity` allocates four standard pages through an
`ArenaAllocator` over the page allocator (Zig `memory_pool.zig` lines 73-102 and
149-152). The arena sizes each new node as
`1.5 × (previous node + item + alignment + header)` (`ArenaAllocator.zig` lines
513-518). Four items therefore map about 5.5·S, not 4·S, where S is
`Page.layout(std_capacity).total_size`. ghostty's comment says S is 512 KiB, but
the test that asserted it is commented out (page.zig lines 2670-2671).

If S is 512 KiB, a pane maps roughly 6-8.3 MiB of writable page memory at
admission across its three terminals, before any scrollback. The arena never
returns individual items before the terminal is destroyed. None of this passes
through `Heap`. The media terminal's pages also bypass `GraphicsBudget`,
although its other allocations go through `PaneMediaAllocator` (Pane.zig
line 241). How much of this is resident is unknown (U2).

**Replacement peaks.** `applyPendingResize` (Pane.zig lines 1382-1412) resizes
the VT first, which is an opaque transient. It then calls
`resizeScreenStorage` ([pane_namespace.zig](../../../src/backend/pane/pane_namespace.zig)
lines 140-155), which allocates the new damage rows and the new cells before
freeing the old ones, so the peak extra is `32·C'·R' + R'`. `render` then grows
each text-metadata storage in turn ([Storage.zig](../../../src/core/text_metadata/Storage.zig)
lines 26-35), adding `87,563 + R'` at a time; this storage never shrinks. The
media and history terminals resize later, in their actors.

## Runtime `Attachment`

**Lifetime.** [pane_attachment.zig](../../../src/backend/runtime/pane_attachment.zig)
line 108 adds an attachment through `Attachments.add`
([Attachments.zig](../../../src/backend/runtime/attachment/Attachments.zig)
lines 50-66). Lines 133 and 166 remove one attachment or clear a client's.
The table holds pointers for 32 clients × 128 slots (Attachments.zig lines
15-20). An attachment points at its pane, so it must go before the pane does.

### Inline: 42,536 B (P1)

| Field ([GraphicsSync.zig](../../../src/backend/runtime/attachment/GraphicsSync.zig), [Transfer.zig](../../../src/backend/runtime/attachment/Transfer.zig)) | Bytes | Status |
| --- | ---: | --- |
| `graphics.known_placements`: 256 × `?Placement` (72 + tag) | 20,480 | estimate |
| `graphics.transfer`: `?Transfer.placements`, 256 × 72 | 18,432 | estimate |
| `graphics.known_images`: 64 × `?ImageKey` | 1,536 | estimate |
| Residual: `CellSync` with two inline buffers, `RenderState` and text-metadata header; pacer; revisions | 2,088 | unknown |

Kitty graphics state takes about 95% of every attachment, including attachments
to panes that never show an image. The 256-placement copy inside `?Transfer`
exists only to stage one transfer.

### External buffers per attachment

| Item | Formula | Status | Allocated / freed ([CellSync.zig](../../../src/backend/runtime/attachment/CellSync.zig)) |
| --- | --- | --- | --- |
| `acknowledged` cells | `32·C·R` | exact | lines 38 / 62 |
| `projected` cells | `32·C·R` | exact | lines 40 / 61 |
| `projected_damage` | `R` | exact | lines 42 / 60 |
| `projected_text_metadata` | `2·(87,563 + R)` | exact | lines 45 / 58 |
| `projected_state` RenderState | about `R·C·c_rs`, created by the first scrolled projection and kept until the attachment is destroyed | unknown | lines 188 / 59 |
| Viewport pin | one tracked pin in the pane's pin pool | small | line 137 |
| Transfer pixels | transient image copy, reserved against the pane's media allocator | exact | GraphicsSync.zig lines 49-62 |

Only a scrolled viewport reads the projected set (CellSync.zig lines 170-206).
An unscrolled attachment projects straight from `pane.screen` and the pane's
text metadata (lines 208-215). The projected set is still allocated for every
attachment at attach time: `32·C·R + R + 2·(87,563 + R)` bytes.

**Replacement peaks.** `resizeIfNeeded` (CellSync.zig lines 65-82) replaces
`acknowledged` and then the projected cells and damage, each allocating before
it frees. The peak extra is `32·C'·R' + R'`.

## Runtime `Session`

**Lifetime.** `Session.create` ([Session.zig](../../../src/backend/runtime/client/Session.zig)
lines 129-148) is called from [Store.zig](../../../src/backend/runtime/client/Store.zig)
line 60. `deinit` and `destroy` happen at Store.zig lines 117-118 and 137-138.
At most 32 sessions exist at once, with 16 handshakes pending
([store_support.zig](../../../src/backend/runtime/client/store_support.zig)
lines 8 and 13).

### Inline: 1,096,256 B (P1)

| Field | Bytes | Status |
| --- | ---: | --- |
| `delivery.responses.items`: 128 × `PendingResponse` ([response_queue.zig](../../../src/backend/runtime/delivery/response_queue.zig) lines 26-60) | 1,077,248 | estimate |
| `delivery.foregrounds_sent`: 256 × `?ForegroundProjection` | 10,240 | estimate |
| Residual: parked message, pending search, hook lineage, pending commands | 8,768 | unknown |

Each queue slot is the size of the largest union member, `core.ExecutionReply`,
which carries two 4 KiB output chunks inline
([ExecutionReply.zig](../../../src/core/schema/messages/ExecutionReply.zig)
lines 6-23). So every session reserves 128 execution-reply-sized slots, about
98% of its record.

### External buffers per session

| Item | Bytes | Status | Allocated / freed |
| --- | ---: | --- | --- |
| Receive buffer, `max_frame_size` ([transport.zig](../../../lib/localsocket/transport.zig) line 13) | 4,194,304 | exact | Session.zig lines 130 / 170 |
| Read buffer (transport.zig line 71) | 65,536 | exact | Session.zig lines 132 / 171 |
| Send buffer | 4,194,304 | exact | [Delivery.zig](../../../src/backend/runtime/delivery/Delivery.zig) lines 49-51 / 56 |
| Clipboard copy | selection size | exact | Delivery.zig lines 45 and 55 |
| History, review and path results owned by queued responses | variable | unknown | response_queue.zig lines 46-57 |

## Client, `ClientModel` and the window

**Lifetime.** [GuiAdapter.zig](../../../src/gui/GuiAdapter.zig) line 190
allocates one array of `machine_slots = 17` clients (line 74). It initializes the
local slot at startup (line 219) and a remote slot when its machine connects
([window_machines.zig](../../../src/gui/window_machines.zig) line 418). It
frees the array at teardown (GuiAdapter.zig lines 301-308). A headless adapter
embeds one `Client`.

**Inline.** `Client` is 2,909,536 B and includes `ClientModel` at 2,087,088 B
(P2). That leaves 822,448 B exclusive to `Client`, not yet attributed by field.
Candidates are the job rings (32 `BackgroundJob`s that carry kilobytes,
[Client.zig](../../../src/client/execution/Client.zig) lines 53 and 81-86), the
received `RuntimeMessage`, the plugin result, and the path and edit buffers.
Inside `ClientModel`, `Tabs` (210,192) and `Panes` (6,664) are known, and
1,870,232 B are unattributed. The 17 slots request 49,462,112 B in total.

**External per initialized client** (Client.zig lines 161-218):

| Item | Bytes | Status | Source |
| --- | ---: | --- | --- |
| Transport: receive and send (4 MiB each), read (64 KiB) | 8,454,144 | exact | [RuntimeTransportState.zig](../../../src/client/connection/RuntimeTransportState.zig) lines 89-103 |
| Outbox payloads: 80 × 8 KiB | 655,360 | exact | Client.zig line 220; [Outbox.zig](../../../src/model/connection/Outbox.zig) lines 20 and 38-42; [outbox_support.zig](../../../src/model/connection/outbox_support.zig) line 19 |
| History palette storage: 768 KiB + 64 KiB + 64 KiB | 917,504 | exact | Client.zig line 219; [HistoryPaletteState.zig](../../../src/model/state/HistoryPaletteState.zig) lines 52-59; [Storage.zig](../../../src/model/state/Storage.zig) lines 5-7 |
| **Total** | **10,027,008** | exact | |

**Per pane replica** ([Pane.zig](../../../src/model/panes/Pane.zig) lines 41-57;
[Panes.zig](../../../src/model/panes/Panes.zig) line 58): the 488 B record, plus
cells `32·C·R`, damage rows `4·R`, the 24 B `TextMetadata` header and its
`87,563 + R` B buffer. That is `88,075 + 32·C·R + 5·R` in five allocations. The
formula reproduces every P2 row exactly: 2,087,088 + n × 88,112 bytes and
1 + 5n allocations for n = 0, 1, 8 and 64. A resize in `applyFrame` (lines
96-140) holds the new damage rows and the new cells next to the old ones, a peak
extra of `32·C'·R' + 4·R'`.

**Window geometry** grows with the window's workbench cells N, not with its
panes:

- `RetainedCells` takes 1,972 B per cell: 52 B metadata, 2 primary quads and 22
  overflow quads of 80 B each ([RetainedCells.zig](../../../src/gui/render/RetainedCells.zig)
  lines 20-22 and 38-53; [CellMesh.zig](../../../src/gui/render/CellMesh.zig)
  lines 19-22).
- The scene `QuadList` reserves 80 × Q(N) B, where
  `Q(N) = 24·(N + min(N,4200) + min(N,384) + min(N,1544)) + N + 17,664 + ImageDraw.capacity`
  ([frame_budget.zig](../../../src/gui/render/frame_budget.zig) lines 9-19;
  [TerminalRenderer.zig](../../../src/gui/render/TerminalRenderer.zig) lines
  207-208).

Together with the fixture's two 32 B-per-cell panes, this explains P3's
geometry delta exactly:
80 × 110,720 + 1,972 × 3,200 + 2 × 32 × 3,200 = 15,372,800 =
40,595,286 − 25,222,486. Two things follow from that match. The cell metadata
really is 52 B, and the window's per-cell cost is about 2 KB retained plus
2.0-7.8 KB of reserved scene quads, depending on N.

On macOS, Metal copies the emitted quads into a second, shared buffer that grows
to its high-water mark (TelarMetalRenderer.m lines 519-532). Atlas, sprite,
diagram and Kitty textures form a separate GPU domain (U6).

## Admission cost

The costs below are requested bytes, exclusive, and a lower bound: the open
terms are listed with each formula. Mapped and GPU costs are listed separately
and are not added in.

| Admission | Requested, known part | Open terms | Outside Heap and requested bytes |
| --- | --- | --- | --- |
| Runtime pane | `1,011,822 + 32·C·R + 3·R + W + L` | output tail (0 or 65,536), RenderState, ghostty gpa structures | ≥ 12·S of VT pool mapping; 2 × 16 MiB thread stacks; futures; child process (measured separately) |
| Runtime attachment | `217,662 + 64·C·R + 3·R` | projected RenderState after the first scroll | none found |
| Runtime session | `9,550,400` | clipboard, queued results | socket |
| Machine client, GUI or headless | `10,027,008` beyond its inline slot (the GUI already holds the slot; a headless client allocates 2,909,536 more) | renderer and adapter state | GPU |
| Client pane replica | `88,075 + 32·C·R + 5·R` | cwd and title copies | none |

Worked arithmetic, from [verify.py](verify.py):

| Geometry | Runtime pane | Attachment | Client replica | Sum per viewed pane | Five text-metadata copies |
| --- | ---: | ---: | ---: | ---: | ---: |
| 80x24 | 1,073,334 | 340,614 | 149,635 | 1,563,583 | 437,935 (28.0%) |
| 153x40 | 1,207,782 | 609,462 | 284,115 | 2,101,359 | 438,015 (20.8%) |

**Shared startup versus marginal.** The runtime's tables (`PaneStore`,
`Attachments`, the session `Store`) are inline in `RuntimeModel` and reserved
once. Their size is not in the archive (U1). Beyond them, the first pane costs
what every later pane costs; the only once-per-process work is `png.install`.
The `std.Io.Threaded` pool grows by up to two persistent threads for each pane
that blocks, so threads are a marginal cost, not a shared one.

The window's first resource is different. Opening a window costs the 17-slot
array (49,462,112), the local client's 10,027,008, the window geometry, and the
renderer, review panel and 17 graphics stores, which are unsized here. Each
further machine adds 10,027,008 plus its pane replicas. A further attachment
costs the same as the first, plus the projected RenderState after its first
scroll.

## Where each resource belongs

These are evidence-based assignments, not pool designs or limits.

**Stable segments**, for records that are large, independently lived and
address-stable:

- `Pane` (836,696), whose actors borrow its address (Pane.zig lines 586-615 and
  867-875);
- `Attachment` (42,536), which delivery dereferences through `Attachments.record`;
- `Session` (1,096,256);
- the `Client` slot (2,909,536). Today it is pre-reserved 17 times; allocating
  it at machine admission would move 49 MB from the window's fixed cost to a
  per-machine cost.

The 488 B model `Pane` fits a slab size class rather than a page segment. These
sizes include the worst-case inline payloads listed next. Moving those payloads
out changes which segment size is appropriate, so segment sizes should wait for
that decision.

**Dynamic payload pools**, for payloads that are variable, reserved at worst
case and often unused:

- `TextMetadata` storage: 87,563 + R B per copy, five copies per viewed pane,
  geometry-independent. 65,536 B of each copy is URI capacity
  (limits.zig lines 4-5) that most screens never use.
- Attachment Kitty state (about 40 KB per attachment) and `Pane.media`
  (203,640 B per pane), both sized for panes with graphics.
- The session `ResponseQueue`: 128 slots sized for an `ExecutionReply`.
- The 4 MiB frame buffers per connection. Each session and each client reserves
  8 MiB for the largest possible frame, even when idle.
- The attachment projected set, needed only while scrolled. Scrolling is
  interactive, so if this becomes on-demand it must either be reserved at
  admission or be refused without failing the scroll.
- Client outbox payloads (640 KiB) and palette storage (896 KiB) per client.
- Geometry buffers (cells, damage, `RetainedCells`, `QuadList`). These stay
  contiguous, retained arrays per owner, charged at admission and resize
  together with their replacement overlap.

**Reusable scratch**, for storage used only during a bounded operation:

- `Pipeline.scratch` (64 KiB, used only by the media actor);
- the inactive half of each double-buffered media and history batch while no
  actor runs (`worker: ?u1`, Pipeline.zig line 23, Observer.zig line 25);
- admission transients `ChildEnvironment` and `OwnedCommand`
  (pane_launch.zig lines 150-171);
- OSC and DCS parser growth;
- resize overlap.

Scratch must be counted at its concurrency, meaning one per running actor, not
one per pane.

**Existing shared backing**, which should be integrated into the ledger rather
than replaced:

- ghostty's page, node and pin pools, which already recycle pages and bound
  scrollback;
- `GraphicsBudget` with `PaneMediaAllocator` and its shared-memory mappings,
  charged to the runtime; a client reports its mapped view separately;
- GPU buffers and textures, in their own domain.

Whatever is decided for the media terminal must count its page pool, which
bypasses `GraphicsBudget` today.

**Duplicate representations.** The pane's screen and text metadata, each
attachment's acknowledged baseline, and the client replica are separate copies
with separate owners and revisions. They are intentional, not accidental
duplication. The projected set and the three emulators per pane are the
duplicates that most need a measured benefit (U2, U3).

## Unknowns and the next isolated measurements

1. **U1**: field `@sizeOf` and `@offsetOf` for Pane, Attachment, Session, Client,
   ClientModel, `vt.Terminal`, `vt.TerminalStream`, `vt.RenderState`,
   `Pipeline`, `Observer`, `PendingResponse` and `Transfer`, on AArch64 macOS
   and x86-64 Linux, where `max_path_bytes` differs. This resolves every
   residual and estimate above, plus the 1,870,232 B and 822,448 B that are
   unattributed in the client.
2. **U2**: ghostty's S, the bytes each PageList pool maps after `Terminal.init`,
   mapped versus resident for one pane, the alternate-screen delta, and the
   high water and retention of 10 MB of scrollback. This is the largest
   per-pane unknown.
3. **U3**: RenderState bytes per cell and per row, including the projected
   state after the first scroll.
4. **U4**: allocator backing and first-touch faults for 836,696 B, 1,096,256 B,
   4 MiB and 49,462,112 B requests under macOS libc malloc and musl
   `slabheap`.
5. **U5**: `std.Io.Threaded` threads per live pane in steady state, and after
   panes close.
6. **U6**: GPU residency per window.
7. **U7**: replacement peaks at large geometry for the pane, the attachment, the
   client replica, `RetainedCells` and `QuadList`.

U1 and U2 should come first: they decide whether the inline payloads or the VT
pages dominate the per-pane floor.

## Validation

`python3 docs/performance/resource-inventory/verify.py` performs 18 equality
checks and 3 residual-sign checks, and passes all of them. It reproduces:

- P2's live storage and allocation counts;
- P3's geometry delta;
- the 17-slot total and the `Client` exclusive size;
- each admission constant.

It also confirms that the itemized inline estimates stay below the archived
totals. The ownership audit covered each allocation and free site cited above.
No production source, experiment input or shared planning document was changed.

Limits:

- RSS, backing, mapped VT pages, thread stacks and GPU memory are not measured.
- The P1 sizes are quoted from a discussion; their raw printout is not archived.
- Inline layouts on Linux differ from the AArch64 macOS figures.
- No whole-process figure can be claimed while ghostty, libc, `std.Io`, native
  window services and GPU drivers keep the uncovered allocations listed above.
