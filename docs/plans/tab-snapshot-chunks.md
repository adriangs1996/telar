# Bounded fragmented tab snapshots

Status: design only, written 2026-10-02 against base `23e9afc6` (production
`43567b04`). No protocol, schema or production code changes. Nothing here was
compiled or run by its author; the proposal is argued on paper (§12).
Integration review updated the lifecycle rules below after Reviews was removed
(schema `866b480d`). Historical source line numbers refer to the authoring base;
this remains a design, not an implemented protocol.

Scope: **one collection, a tab's panes** (`request_tab_snapshot` /
`tab_snapshot`). Workspace, agent and layout snapshots appear only where they
constrain this design (§14). Quota numbers, allocator work and a protocol
migration of other messages are out of scope. This follows the
[memory design agreement](memory-design-agreement.md), the
[memory budget](memory-budget.md) and the
[access-cluster roadmap](access-clusters.md): capacity policy, canonical layout
and derived representations are separate decisions; charge writable backing,
including unused slots; duplicate only with an explicit invalidation contract.

## 1. Decision in one paragraph

Replace the single bounded `tab_snapshot` reply with **revision-bound
pagination pulled by the receiver**. The runtime stays stateless per snapshot,
as it is today: each page is a late-bound projection of current membership,
ordered by ascending pane id, at most `P` descriptors, stamped with a runtime
**membership revision**. The client asks for the next page with the revision
and the last pane id it staged; if membership changed, the runtime restarts the
snapshot in place (a first page under the new revision). The client stages
pages in a bounded, invisible area and publishes only a complete snapshot under
one revision, in one model transaction. Strictly increasing ids make duplicate
detection O(1) per descriptor and O(n) per snapshot without a hash set. Tab
population capacity, page size `P` and receiver staging capacity become three
separately named bounds. A snapshot of at most `P` panes is one request and one
reply, so today's tabs keep today's round trip. This requires an explicit,
non-backward-compatible schema change (§6.5). The first implementable slice
needs no wire change: an exact runtime membership revision (§13).

## 2. Current behavior (source-traced)

### 2.1 Wire layout and bounds

Request, client tag `0x08` ([tags.zig](../../src/core/schema/messages/tags.zig)),
derived encoding of [`RequestTabSnapshot`](../../src/core/schema/messages/RequestTabSnapshot.zig):
`tag u8 | request_id u64 | location` = 26 bytes; golden
`request_tab_snapshot` in [golden.zig](../../src/core/golden.zig).
`location` is [`TabLocation`](../../src/core/schema/TabLocation.zig):
`kind u8 (0 workspace, 1 worktree) | container id u64 | tab_id u64`, 17 bytes
([codec.zig](../../src/core/schema/codec.zig) `encodeTabLocation`,
`decodeWorkspaceLocation`); zero ids are rejected by [id.zig](../../src/core/schema/id.zig).

Reply, server tag `0x86`,
[tab.zig `encodeTabSnapshot`/`decodeTabSnapshot`](../../src/core/schema/messages/tab.zig) (lines 125–179):

```text
tag u8 | request_id u64 (non-zero) | location (17 B) | pane_count u16
pane_count × ( pane_id u64 (non-zero) | lifecycle u8 (0 running, 1 exited) | pane_generation u64 )
```

Header 28 bytes, 17 bytes per descriptor. The golden `tab_snapshot` entry pins
it, and the handshake fingerprint is derived from the golden corpus plus every
`types.zig` bound ([schema_contract_test.zig](../../src/core/schema_contract_test.zig),
`wire_bounds`, tests "every bound types.zig declares is part of the
fingerprint" and "the handshake fingerprint derives from the golden corpus").
[handshake.zig](../../src/core/schema/handshake.zig) accepts exactly one
`schema_id` (`schema_version` `"86"` + fingerprint `"6b480d"`); there is no version range.

| Bound ([types.zig](../../src/core/schema/types.zig)) | Value | Exact current meaning |
| --- | --- | --- |
| `max_panes` | 256 | Runtime `PaneStore.capacity`, every pane in every tab **including exited panes not yet collected**; also the client `Panes.capacity` per `ClientModel` and, via "every tab has a pane", the live tab bound |
| `max_panes_per_tab` | 64 | Simultaneously: runtime admission per tab (`PaneStore.allocateKey` refuses at `occupancyAt == 64`, which counts closing and exited panes); the encode/decode bound of `tab_snapshot.pane_count`; per-tab `pane_count` in `workspace_snapshot`; leaves of a client split tree (`layout_support.max_nodes = 64·2−1`); and the size of ~55 files' fixed arrays and queues (below) |
| `max_tabs_per_workspace` | 64 | `workspace_snapshot` tab count; client `Tabs.capacity` |
| `max_agent_snapshot_entries` | 64 | `agent_snapshot` entries, one per agent pane generation |
| `localsocket.transport.max_frame_size` | 4 MiB | Every frame, checked before allocation; also the size of each runtime session's preallocated `Delivery.send_buffer` |

A count field's **width** is not its **policy**. `pane_count` is a `u16`
(65,535) but the policy is 64. Even at the width maximum a reply is
`28 + 65,535·17 = 1,114,123` bytes, about a quarter of the 4 MiB frame. Frame
size is therefore not what bounds a tab snapshot today; the bound exists to keep
validation work and receiver arrays fixed. Raising 64 inside the same message
would leave the frame valid and make validation and storage grow (§2.4).

`max_panes_per_tab` also sizes structures unrelated to the snapshot message:
the client request `Tracker.capacity = 64 + 8`
([Tracker.zig](../../src/model/connection/Tracker.zig)), the runtime
`ResponseQueue` (`capacity = 64·2`,
[response_queue.zig](../../src/backend/runtime/delivery/response_queue.zig)),
client layout node arrays, GUI hit maps and widgets. The constant is a
population policy, a wire bound and a storage size at once. That coupling is
what this design separates for the snapshot path only.

### 2.2 Producer (runtime)

1. `client_request.receive` routes `.request_tab_snapshot` to
   [`tab_snapshot_reconciliation.snapshot`](../../src/backend/runtime/tab_snapshot_reconciliation.zig).
   It fails with `tab_not_found` when the workspace lacks the location or
   `countAt` is 0; otherwise it pushes `PendingTabSnapshot{request_id,
   location}` with `push` (not `pushOrDrop`). A full queue returns
   `ResponseQueueFull`, which drops the sender (the dispatch comment: "An error
   drops the sender"; [client_connection.zig](../../src/backend/runtime/client_connection.zig)
   `dropUnanswered`).
2. **No descriptor is captured at request time.** `Delivery.prepare`
   ([Delivery.zig](../../src/backend/runtime/delivery/Delivery.zig) line 147)
   runs only when the session has no send in flight (`phase == .ready`).
   Management responses (everything except `history_result`) go first,
   in FIFO order. [`encoder.encodeResponse`](../../src/backend/runtime/delivery/encoder.zig)
   then calls `PaneStore.descriptorsAt(location, &descriptor_storage)` and
   `core.encodeTabSnapshot` into the 4 MiB send buffer.
3. [`PaneStore.descriptorsAt`](../../src/backend/pane/PaneStore.zig) (line 139)
   scans all 256 slots and keeps panes that are `launch_state == running`,
   `!close_requested`, `exit == null` and at exactly `location`, **in slot
   order**, with `lifecycle` hard-coded to `.running` and the pane's
   generation. The runtime never emits `.exited` here. Slots are reused
   (`insert` takes the first free slot), so slot order is neither creation
   order nor stable across closes.
4. The encoder re-checks `len ≤ 64` and runs a quadratic duplicate scan.
   It does not re-check that the tab still exists: if the tab lost every
   discoverable pane between request and send, the reply is a valid
   **empty** snapshot, which precedes any later `tab_closed` in the FIFO.

So today's reply describes membership at the instant it is encoded, and the
ordered socket delivers it before any response queued later. The per-session
cost is one queue entry, an O(256) scan and an O(n²) check, with no retained
per-snapshot state.

Membership change counters: `PaneStore.revision` advances on insert, removal,
exit and cwd changes (and `pane_observation`, `agent_snapshot` advance it too),
so it is coarse. More importantly, **`Pane.requestClose` sets `close_requested`,
which removes the pane from `descriptorsAt`, without advancing any revision**
([Pane.zig](../../src/backend/pane/Pane.zig), `requestClose`;
`PaneStore.closeAt` also advances nothing). Launch commit
(`starting → running`) happens in the same event as insertion
([pane_launch.zig](../../src/backend/runtime/pane_launch.zig) line 247), so
it cannot be observed between two deliveries. A pane's `location` is assigned
only at creation. No existing counter is an exact membership revision.

### 2.3 Consumers

**GUI and headless client.** The decode runs on the read job, outside the
client loop ([RuntimeMessage.zig](../../src/model/connection/RuntimeMessage.zig)
`decodeInto`). Decode errors lose the link (`runtime_io.receiveRuntime`).
`runtime_messages.receiveServerMessage` calls
[`tab_snapshot.applyTabSnapshot`](../../src/client/workspace/tab_snapshot.zig)
(line 50):

1. `tracker.take(request_id)` must yield `.tab_snapshot = location` (or
   `.ignored`, already retired by `tab_closed`/`ignoreTab`), and the reply
   location must equal it, else `UnexpectedTabSnapshot`.
2. It copies **only pane ids** into a stack `[64]PaneId`. `lifecycle` and
   `pane_generation` are decoded and discarded.
3. [`reconcileTab`](../../src/model/workspace/tab_snapshot_reconciliation.zig)
   (line 172) re-checks `len ≤ 64`, runs a quadratic duplicate scan, rejects a
   pane that exists in another tab, collects removed panes with an O(m·n)
   `findScalar`, stages a saved layout, then calls `reconcile` (line 17), which
   runs **a third** quadratic duplicate scan, removes vanished panes from the
   layout, adds discovered panes (`Panes.add` → `gpa.create(Pane)`, then
   `layout.split`), restores focus and sets `snapshot_loaded`.
4. After the model commits: removed-pane requests are ignored and their
   resources released; if active, focus is synchronized, attached panes
   resized and visible panes attached.

Snapshot order is meaningful: `tab_layout.restoreDisplayOrder` builds a
left-to-right chain in snapshot order after a workspace handoff, and
`addDiscovered` splits in snapshot order.

Coalescing: `recoverTabSnapshot` skips if **any** `.tab_snapshot`
continuation is pending, whatever its location. `tab_selection.selectTab`
returns `null` (the selection is dropped) while any is pending, and
`cli_control` answers `ClientBusy`. `requestTabSnapshot` itself (selection,
workspace list, handoff) does not coalesce, so several snapshots for
different tabs can be in flight.

Failure: a `request_failed` for a `.tab_snapshot` continuation returns
`error.RuntimeRequestFailed`
([request_failure.zig](../../src/client/connection/request_failure.zig)
line 45). Any non-limit error leaves `Client.update`, and the GUI loop's
`absorbUpdate` re-raises it ([GuiAdapter.zig](../../src/gui/GuiAdapter.zig)
line 788). Ordering protects the common race: a `tab_closed` queued before a
later request's failure turns the continuation `.ignored` first.

Reconnect: `runtime_session.forget` resets `request_lifecycle` and the
replicas ([runtime_session.zig](../../src/model/connection/runtime_session.zig)).

**CLI.** [`PaneCatalog.loadTab`](../../src/cli/PaneCatalog.zig) and
[`TabControl.read`](../../src/cli/TabControl.zig) use `Session.exchange`
([Session.zig](../../src/cli/Session.zig) line 79). It assigns the request id
(the literal `.none` is overwritten), allocates a 4 MiB buffer per exchange and
discards replies with other ids. `PaneCatalog` reports the snapshot index as
`position` and stores at most `max_panes` entries across tabs it loaded
through separate, non-atomic requests.

### 2.4 Findings that constrain the design

| # | Finding | Consequence |
| --- | --- | --- |
| F1 | The 64 limit is policy; the u16 width and the 4 MiB frame admit far more | Raising the constant passes the frame check and grows work and arrays |
| F2 | Duplicate checks are O(n²) in the encoder, decoder and twice in the client model, plus O(m·n) removal detection | 4 × 2,016 comparisons at 64; about 2.1·10⁹ per scan at the u16 width |
| F3 | Late binding keeps the runtime stateless and the reply current at send time | A multi-message design must keep or replace this property explicitly |
| F4 | No counter tracks discoverable membership exactly; `close_requested` changes it silently | Pagination needs a new exact revision (§7.2) |
| F5 | The client ignores `pane_generation` and `lifecycle` | Stale-generation handling must be specified rather than assumed |
| F6 | `reconcile` removes panes, then adds with fallible allocation and `layout.split` | An allocation failure midway can leave membership that is neither old nor new; only the pane just added is rolled back (`errdefer`) |
| F7 | Snapshot order drives display order; slot order is arbitrary | Changing the order is a visible behavior change (§6.3) |
| F8 | A failed snapshot request is fatal on the client unless already ignored | New failure paths must be non-fatal by construction |
| F9 | The client layout cannot hold more than 64 leaves (`max_nodes = 127`, `findLeaf` linear) | A bigger snapshot alone does not raise what a client can display; it must refuse explicitly |

## 3. Requirements

From the brief and the user's decision:

- Population capacity is decoupled from per-message work and receiver budget.
  Raising constants is not the solution.
- Every message stays bounded; untrusted input validation stays bounded and
  happens before storage.
- Covered: snapshot identity and revision, ordering, completion, abort,
  cancellation, supersession, duplicates in O(n) expected or a justified
  alternative, mutation during transfer, stale generations, atomic
  publication, focus, disconnect/reconnect, malformed counts and lengths,
  overflow, receiver refusal, backpressure and slow consumers.
- Memory: incomplete staging plus the overlap of old and new publications is
  charged. Chunking alone does not bound full-snapshot memory.
- An interrupted snapshot never silently replaces a valid one.
- Compatible with flat `RuntimeModel`/`ClientModel` and existing flow
  boundaries; a schema change is explicit.

## 4. Three quantities, three owners

| Quantity | Owner | Today | Proposal |
| --- | --- | --- | --- |
| **Tab population capacity**: panes one tab may hold | Runtime admission (`allocateKey`) | `max_panes_per_tab` | A runtime policy value, later derived from the runtime budget; never sent as a wire bound |
| **Page bound `P`**: descriptors in one reply | Wire schema (fingerprinted) | Same constant, as `pane_count` limit | New `max_tab_snapshot_page_panes`; bounds decode and encode work per message |
| **Receiver staging capacity `S`**: descriptors one client will stage for one snapshot | Each receiver's own budget (window allowance or CLI) | Implicit 64-entry stack arrays | Explicit per receiver, checked against `total` before staging; refusal is a named limit, not a protocol error |

A runtime may hold more panes in a tab than a given client can stage or lay
out. That client then refuses the snapshot explicitly (§8.5). It does not
publish a truncated tab.

## 5. Alternatives with Telar's actual ownership and transport

**A. Raise the constants.** Rejected by the user decision and F1/F2/F9:
quadratic work, larger fixed arrays on every receiver, and the layout tree
still caps display.

**B. Chunked streaming (runtime-driven).** One request; the runtime sends
`begin(total, revision) · chunk* · end`.

- The runtime needs per-session stream state: a cursor, revision and request id
  per stream, re-queued after each send. This breaks the current "one queued
  entry → one message, popped at commit" model of `ResponseQueue`/`Delivery`.
  To stay late-bound it needs the same membership revision plus an abort
  message; to avoid restarts it must **copy** the membership at begin, costing
  O(n) runtime memory per in-flight stream per session (up to 32 sessions,
  `ClientList.capacity`), retained for as long as a slow client takes.
- The client receives chunks it cannot refuse once the stream starts. Refusal or
  supersession needs a cancel message and a "cancelled but still arriving"
  continuation state until `end`. Bounding receiver memory needs a credit
  window, which is pull under another name.
- The `Tracker` contract ("exactly one success or failure consumes the
  continuation", [requests.zig](../../src/model/connection/requests.zig)) and
  CLI `Session.exchange` (one reply per request) both need multi-reply
  continuations.
- Benefit: no round trip per chunk; with a copy-at-begin, no restarts under
  churn.

**C. Revision-bound pagination (receiver-pulled).** Each page is one request and
one reply. The runtime keeps no snapshot state.

- The runtime side reuses `PendingTabSnapshot`, with two more fields, and the
  same late-bound encode. Nothing exists to clean up on disconnect, cancel or
  supersede.
- Backpressure is built in: at most one page request per transfer is
  outstanding, and the next one is sent only after the receiver staged the
  previous page. A slow consumer slows only itself.
- Fits `Tracker` (one continuation per page) and CLI `exchange` unchanged.
- Cost: `⌈n/P⌉` round trips, and restarts when membership changes mid-transfer.
  For `n ≤ P`, identical to today.

| Concern | B. Streaming | C. Pagination |
| --- | --- | --- |
| Runtime retained state per transfer | cursor + revision (late-bound), or O(n) copy | none |
| Cancellation / supersession | cancel message + draining state | stop asking; ignore one in-flight reply |
| Disconnect | free stream state on both sides | client-side reset only |
| Receiver refusal | after `begin`, chunks still arrive | before the next page is requested |
| Slow consumer | runtime holds stream (and copy) | runtime holds nothing |
| Consistency | snapshot at begin (copy) or at end (revision) | snapshot at the final page encode (revision) |
| Latency, n > P | ~1 RTT | `⌈n/P⌉` RTT plus restarts |
| Tracker / CLI | multi-reply continuation | unchanged contracts |

**Choice: C.** It is the smallest design that keeps the runtime's existing
late-bound, stateless reply, the single-reply request contract and the flat
models. B's advantages matter only when `n ≫ P` over high-latency links under
churn. That case is not supported today, so it is measured later rather than
designed in (§11, §14).

## 6. Proposed protocol (requires a schema change)

### 6.1 Messages

`request_tab_snapshot` (client → runtime):

| Field | Type | Rule |
| --- | --- | --- |
| `request_id` | `RequestId` | non-zero |
| `location` | `TabLocation` | as today |
| `membership_revision` | u64 | `0` = start a new snapshot; else the revision of the pages already staged |
| `after_pane` | u64 | `0` = from the first pane; else the last staged pane id. Must be `0` exactly when `membership_revision` is `0` |

`tab_snapshot` (runtime → client), one page:

| Field | Type | Rule |
| --- | --- | --- |
| `request_id` | `RequestId` | non-zero, echoes the request |
| `location` | `TabLocation` | echoes the request |
| `membership_revision` | u64 | non-zero; current runtime membership revision |
| `after_pane` | u64 | equals the request's `after_pane` (continuation) or `0` (a fresh or restarted first page) |
| `total_panes` | u32 | panes in the snapshot under this revision. The width is headroom, not policy |
| `page_count` | u16 | `≤ P`; exactly `min(P, total_panes − ordinal_of_first)` |
| descriptors | `page_count × (pane_id u64, lifecycle u8, pane_generation u64)` | ids strictly increasing, all `> after_pane`; generation non-zero; lifecycle valid |

Sizes: request 42 bytes (today 26), reply header 48 bytes (today 28),
descriptor 17 bytes. At `P = 64` a page is at most `48 + 1,088 = 1,136` bytes.
The receiver derives the ordinal of a page's first descriptor from what it
staged, not from the wire, so the runtime cannot make the receiver skip or
overlap positions. A reply is final when staged + `page_count == total_panes`.

### 6.2 Runtime answer rule

For a request `(L, rev, after)`:

1. If the workspace lacks `L`, answer `tab_not_found` at request time, as today.
2. At encode time, let `cur` be the current membership revision.
   - `rev == 0`, or `rev != cur`: encode a **first page** under `cur` with
     `after_pane = 0` (start or restart in place; no extra round trip and no new
     failure code).
   - `rev == cur`: encode the page of members with id `> after`.
3. A tab that lost every member before encoding yields `total_panes = 0`,
   `page_count = 0`. That is today's empty-snapshot behavior (§2.2, step 4), so
   no new fatal failure path is introduced (F8).

### 6.3 Order

Descriptors are ordered by **ascending pane id**. Pane ids come from
`PaneStore.next_id` and are never reused within a runtime lifetime; restored
keys must be `≥ next_id` (`reserveRestoredKey`). So id order is creation order
and is stable under slot reuse. This is what makes the cursor a single id and
duplicate detection a comparison.

It changes visible behavior (F7): `restoreDisplayOrder`'s left-to-right chain
and discovery splits follow creation order instead of slot order, and the CLI
`position` changes meaning accordingly. This needs Adrian's approval (§15).
If slot order must be kept, the fallback is a slot cursor plus an
open-addressing id set in the staging area (O(n) expected, `2·S` ids charged
to the receiver). It is sound, but it costs memory and has a worse worst case.

### 6.4 Validation (bounded, before staging)

Per page, on the read job, in O(`page_count`) with no allocation: tag; the
existing location and request-id rules; `page_count ≤ P` **before** reading
descriptors; each descriptor's id is non-zero and greater than the previous one
in the page and than `after_pane`; generation non-zero; lifecycle valid;
`ensureEnd`. The encoder enforces the same strictly increasing rule in O(P)
instead of its O(n²) scan.

Across pages, in the receiver (§8), O(1) per page: the correlation and echo
rules; `total_panes ≤ S`; `staged + page_count ≤ total_panes`, computed in
`u64` from a `u32` and a `u16`, which cannot overflow; the full-page rule; the
first id is greater than the last staged id.

### 6.5 Compatibility

This is a breaking encoding change. It changes the golden `tab_snapshot` and
`request_tab_snapshot` corpus entries, adds `max_tab_snapshot_page_panes` to
the fingerprinted bounds, and bumps `schema_version`. Under the exact handshake,
mismatched peers are refused with `incompatible_schema`; there is no mixed-version
operation and no backward compatibility is claimed. Keeping the old tags beside
new ones would gain nothing while the handshake stays exact. The recommendation
is to keep the tag numbers and names and change their layouts in one schema
generation.

## 7. Runtime

### 7.1 Request and encode

`PendingTabSnapshot` gains `membership_revision` and `after_pane` (16 bytes).
That is unlikely to grow the `PendingResponse` union, whose size is set by larger
variants; confirm with `@sizeOf` when implementing. Page selection at encode,
in one pass over the `C` pane slots (`C = PaneStore.capacity`): keep members of
`L` with id `> after` in a bounded max-heap of size `P` on the stack, and count
all members of `L` for `total_panes`. Cost is O(C log P) time and O(P) scratch.
A per-tab ordered index is a derived representation, rejected until a
measurement shows the scan matters (agreement §"Three separate decisions").

### 7.2 Membership revision

`PaneStore.membership_revision: u64`, advanced with `revisions.advance`
(zero stays "start") on **every** transition that can change the result of
`descriptorsAt` for some location:

| Transition | Where today | Changes `descriptorsAt`? |
| --- | --- | --- |
| launch commit `starting → running` | `Pane.commitLaunch` via `pane_launch.launch` | yes |
| close request of a running pane | `Pane.requestClose` and its callers, `PaneStore.closeAt` | yes (F4) |
| exit recorded | `PaneStore.completeExit` | yes |
| removal of a slot | `removeAndDestroy`, `removeExitedAt` | only if the pane was still discoverable; advancing anyway is allowed |
| launch abort, cwd/title/foreground/metadata | `abortLaunch`, `CwdState`, `TitleState`, … | no; must not advance |

The revision is global, not per tab. A membership change in any tab restarts
in-flight multi-page transfers of every tab. That is sound and cheap. Its cost,
restarts, is proportional to membership changes per transfer duration
(`⌈n/P⌉·RTT`), not to output or metadata churn. A per-tab column in the runtime
`Workspaces` table is the refinement if measured restarts warrant it. It
requires the advancing procedures to reach the tab row, so it is deferred.

A content digest computed in the same scan was considered: it needs no writer
discipline but is probabilistic. It is rejected because an exact counter plus
an oracle test (§13) gives a guarantee.

## 8. Client receiver

### 8.1 Data (flat model)

One singleton field on `ClientModel`, `tab_snapshot_transfer`, holding plain
fields and fixed columns:

```text
location: TabLocation          // tab being staged; meaningful only while staging
request_id: RequestId          // the one outstanding page request, or .none
membership_revision: u64       // revision of staged pages; 0 before the first page
total: u32                     // total_panes of the staged revision
staged: u32                    // descriptors staged so far
restarts: u8                   // restarts of this transfer
staged_pane: [S]PaneId         // columns, valid for [0, staged)
staged_generation: [S]u64
staged_lifecycle: [S]PaneLifecycle
```

Plus two columns on `Tabs`: `snapshot_deferred: [tabs capacity]bool` and
`snapshot_retry_blocked: [tabs capacity]bool` (§8.4).
Continuations keep their current shape: `.tab_snapshot = location`. The expected
revision and cursor live in the transfer, keyed by `request_id`, so `Tracker`
entries do not grow. Proposed glossary terms for `CONTEXT.md`: **membership
revision** and **tab snapshot transfer**.

### 8.2 State machine

States: `idle`, and `staging` (`request_id` outstanding, `0 ≤ staged < total`).
A first-page request for a tab is in neither state; it is a plain tracked
request. Coalesce requests for the same location while either that first-page
continuation or its multi-page transfer is outstanding. Supersession ignores
the previous continuation before sending its replacement.

**Dispatch precedence.** Drop ignored replies first. A reply matching
`transfer.request_id` must go through the transfer rules before the standalone
single-page fast path. Validate location, revision, cursor, count and receiver
capacity before publication. A continuation keeps the same total; a restart
has a different nonzero revision and cursor zero. Charge every restart against
R, including a restart that now fits in one page. If it completes, release the
transfer (request id, staging count, revision and restart count) **before**
fallible publication preparation. Its reply view remains borrowed for that
call. Preparation failure preserves the old published model but leaves the
transfer idle, allowing another tab to proceed.

| State | Event | Action → next |
| --- | --- | --- |
| any | `request(L)` with no outstanding request/transfer for L | Send `(L, 0, 0)` as a tracked request → unchanged |
| any | reply, continuation `.ignored` | Drop → unchanged |
| any | standalone reply (not `transfer.request_id`), `after_pane = 0`, `page_count == total_panes` | Check receiver and publication capacity, validate, **publish** directly from the view → unchanged; any unrelated transfer stays intact |
| `idle` | reply, `after_pane = 0`, `total_panes > page_count` | If `total_panes > S`, or exceeds publication capacity (§8.5): **refuse** (named limit, keep publication) → `idle`. Else claim the transfer, stage page, request `(L, rev, last_id)` → `staging` |
| `staging(L)` | reply for another tab `L′`, multi-page | Transfer occupied: set `snapshot_deferred[L′]` → `staging(L)` (§8.4) |
| `staging(L)` | reply with `request_id == transfer.request_id`, `after_pane == last_id`, same revision | Stage; if `staged == total`, release the transfer then **publish** → `idle`; else request next → `staging` |
| `staging(L)` | reply with matching id and `after_pane = 0` (restart) | `restarts += 1`; if over the restart bound R: **abort** (named limit, keep publication, defer and block automatic retry of `L`) → `idle`; else validate the new total against capacity and reset staged to the new page → `staging`, or release the transfer then publish → `idle` |
| `staging(L)` | reply with matching id and any other echo, revision or rule failure | Protocol error. Reset the transfer **first**, then return the error (invariants: release the slot before any step that can fail) → `idle` |
| `staging(L)` | `tab_closed(L)` | `ignoreTab` already ignores the outstanding continuation; reset transfer → `idle` |
| `staging(L)` | `request_failed` for the outstanding page | Reset transfer, then the existing failure path → `idle` |
| `staging(L)` | `request(L)` (coalesce) | No new request → `staging` |
| `staging(L)` | user selects another tab | Recommended: **supersede**. Ignore the outstanding page, reset, defer `L` → `idle` (§15) |
| any | link lost / reconnect | `runtime_session.forget` resets the transfer with the rest → `idle` |
| `staging` | publication preparation refused | Keep publication, report limit (or propagate a host `SystemError`), reset → `idle` |

Only two transitions publish: a validated single page, and `staged == total`
under one revision with full pages and a strictly increasing id sequence. A
matched transfer is released before either publication path. Every
other exit resets staging without touching published rows. **An interrupted
snapshot cannot replace a valid one.**

### 8.3 Publication transaction

Today's `reconcile` (F6) becomes **prepare, then commit**, in one procedure of
the tab-snapshot-reconciliation flow:

1. **Validate against the model** without mutating it. The tab exists at the
   exact location. Each id is absent or already in this tab (index lookup,
   O(1)). Generations: a client pane with non-zero `pane_generation` different
   from the snapshot's is a different pane lifetime and is scheduled as
   remove-plus-add; zero means "not learned yet" and adopts the snapshot's.
   Compute the added count `a` and removed set with an O(n + m) pass that marks
   retained client slots in a stack bitset over `Panes.capacity`, replacing
   today's `findScalar` scans.
2. **Prepare** every fallible resource. Layout capacity for `n` leaves; `Panes`
   free rows `≥ a` after removals; allocate the `a` new `Pane` records up front.
   On failure, free what was prepared and keep the publication.
3. **Commit**, infallibly: remove vanished panes from layout and table, insert
   prepared records, rebuild or extend the layout, restore focus, set
   `snapshot_loaded`, advance revisions exactly as today (active, visible
   change only).
4. **Post-commit effects**, as today: retire removed resources, synchronize
   focus, resize, attach. Their failure keeps the committed membership; a later
   snapshot repairs disposable state (the existing flow rule).

**Focus.** The focus considered is the one at commit time, not at request
time, because the user may move focus on the old publication during staging. A
surviving focused pane keeps focus; otherwise today's fallback applies. Pending
saved-layout restoration keeps today's rules and is staged at commit.

**Ordering after publication.** The published set equals runtime membership at
the final page's encode: the revision did not move between the first and the
final encode, so every page described the same set. Any later runtime event
reaches this client after that page on the ordered socket. Notifications that
precede it (for example a `pane_exited` from the attachment lane that the
runtime prioritizes behind responses) must stay idempotent against the
published set, as they are today.

### 8.4 One transfer slot, deferred tabs

At most one multi-page transfer per `ClientModel`, so staging memory is one
`S`-sized set of columns. First pages remain concurrent as today. A second
multi-page snapshot that arrives while the slot is busy marks its tab in
`snapshot_deferred` and keeps its publication. When the slot frees, the client
re-requests the active tab if deferred and not retry-blocked, else the lowest
deferred, unblocked tab slot. Restart exhaustion or capacity refusal sets
`snapshot_retry_blocked`; freeing the transfer must not immediately restart
that refused tab. An explicit refresh/reselection, reconnect or a separately
observed membership/capacity change may clear the block. Ordinary output,
metadata and the completion of another transfer do not. This prevents an
unbounded retry loop made of individually bounded transfers.
That is an O(T) scan over 64 tab rows per completion. The selection guard
(`tab_selection` returning `null` while a snapshot is pending) would block the
user for the whole transfer. The recommendation is that a selection supersedes
a transfer for the tab being left. Whether to allow K > 1 slots is open (§15).

### 8.5 Refusal and population above client capacity

For every complete single-page snapshot and every initial or restarted first
page of a multi-page snapshot, the receiver checks
`total_panes ≤ min(S, layout leaf capacity, Panes.capacity − panes in
other tabs)`; final preparation rechecks availability against the current model. Refusal reports a named limit with `limit_reached.report`, for
example `tab_snapshot.max_staged_panes`, keeps the old publication and marks
the tab deferred and retry-blocked. How such a tab is presented (notice, read-only indicator) is a product
decision. A truncated or partial publication is never made.

## 9. CLI

`PaneCatalog.loadTab` and `TabControl.read` loop `exchange` over pages:
restart on `after_pane = 0`, stop at `total`, and refuse above their own `S`
(`PaneCatalog` already bounds its entries at `max_panes`). A CLI has no
publication to preserve, so a refusal is an exit status with the limit name.
Each exchange allocates a 4 MiB buffer today; paging should reuse one buffer
per command rather than multiply that allocation.

## 10. Invariants

1. Every message is bounded: `page_count ≤ P`, header fixed; frame limit unchanged.
2. Decode work per message is O(P) and allocation-free; no check is quadratic.
3. Pane ids in one snapshot are strictly increasing across all pages. Duplicates
   are impossible to stage.
4. A staged snapshot is published only when `staged == total` under one
   membership revision, with every page full except the last.
5. Staging is invisible: no reader other than the transfer procedures reads it.
6. Publication is all-or-nothing: preparation failure leaves the old
   publication byte-for-byte unchanged.
7. The runtime retains no per-snapshot state. Cancel, supersede, refuse and
   disconnect need no runtime message.
8. At most one page request per transfer is outstanding; the receiver controls
   the rate.
9. `membership_revision` advances on every change of any tab's discoverable
   membership and on nothing that does not affect it except removals
   (conservative).
10. Population capacity, `P` and `S` are independent named bounds. Raising one
    never silently widens another or the wire.
11. Transfer work is bounded: at most `(R + 1)·⌈S/P⌉` pages per transfer,
    `≤ (R + 1)·S` staged descriptors.
12. A new failure path for a snapshot is non-fatal and releases the transfer
    before it can fail.

## 11. Complexity

`C` runtime pane slots, `n` tab members, `m` client panes in the tab, `P` page
bound, `T` tabs.

| Step | Today | Proposed |
| --- | --- | --- |
| Runtime encode per message | O(C) scan + O(n²) duplicates | O(C log P) select + O(P) encode |
| Runtime per snapshot | 1 message | `⌈n/P⌉` messages, `⌈n/P⌉·O(C log P)` |
| Client decode per message | O(n²) | O(P) |
| Client staging per snapshot | — | O(n) total, O(1) per descriptor |
| Client publication | 2·O(n²) duplicate scans + O(m·n) removal + layout | O(n + m) validate/prepare + layout rebuild (unchanged, O(n·max_nodes) via linear `findLeaf`, §14) |
| Round trips | 1 | `⌈n/P⌉` (1 for `n ≤ P`), × restarts |

## 12. Resource accounting

Following the agreement: charge writable backing, including unused slots; one
charge per owner; reusable space is not free budget; credit returns when backing
is released.

**Runtime.** Nothing per transfer. Each page request occupies one existing
`ResponseQueue` entry (the queue is fixed and already charged); encode scratch
is O(P) stack; the per-session 4 MiB send buffer is existing. Cost scales with
requests in the queue, which the client tracker bounds (72 < 128).

**Client, per `ClientModel`.**

- Staging columns: `S·(8 + 8 + 1)` bytes, plus header fields and the tab
  bitset. Charged in full while they exist, including unused rows. If they are
  fixed table columns (the slice proposal) they are charged at startup for
  **every machine client of the window**: `17 × 17·S` bytes, about 18 KiB at
  `S = 64`, about 1.1 MiB at `S = 4,096`. If `S` becomes budget-derived and
  large, the alternative is one backing reservation per transfer at the
  admission check (§8.5), charged as a whole segment and released at reset.
  Only one transfer can be in flight per client.
- **Old and new coexist** during staging and preparation. The old publication
  (its `Pane` records, layout, attachments) stays valid and usable throughout;
  it is already charged to the panes table and its records. Staging is
  additional.
- **Peak at publication** ≈ old published records + staging (`17·n`) + `a`
  prepared `Pane` records (and whatever `Panes.add` allocates for each) +
  layout rebuild scratch. Removed records return credit only when their backing
  is released, not when they leave the table (agreement §"Accounting").
  Admission (§8.5) reserves the staging and the `a` records before step 3.
  A refused reservation keeps the old publication.
- Chunking bounds message size and per-message work only. Full-snapshot
  memory is bounded by `S` and by admission, never by `P`.

**Who is charged.** Staging and prepared records belong to the window
allowance (memory budget §"Budget ownership"). They are optional transfer
memory: preparation uses existing capacity or refuses, and never borrows the
control reserve, which must still cover the refusal notice and the reset.

## 13. Next slice: exact membership revision (no wire change)

The smallest step that is useful alone, needs no schema change, and
everything else depends on. It closes F4.

**Change.** Add `PaneStore.membership_revision: u64 = 1` and advance it in the
transitions of §7.2. Add the glossary entry **membership revision** to
`CONTEXT.md`. No client, wire, golden or fingerprint change.

**Acceptance criteria.**

1. Oracle test over two tabs in two workspaces (worktree and workspace
   locations). It drives launch commit, close request through
   `Pane.requestClose` and through `PaneStore.closeAt`, `completeExit`,
   `removeAndDestroy`, `removeExitedAt` and `abortLaunch`. After each step it
   compares `descriptorsAt` for every location with its previous result:
   **any difference implies `membership_revision` changed**.
2. The same fixture applies cwd, title, foreground and agent-metadata changes:
   `membership_revision` is unchanged, while `PaneStore.revision` may change.
3. Zero is never produced (`revisions.advance` semantics); a wrap test exists
   or is reused.
4. `schema_contract_test` and golden files are untouched; the handshake
   `schema_id` is unchanged.
5. No allocation is added on any path; the field adds 8 bytes to `PaneStore`.
6. Validation: targeted backend pane/runtime tests only, `-j1`, run after the
   placement benchmark on Personal reports completion. `zig build codestyle`
   on the touched files.

**Then, in order (each a separate task):**

2. Client publication as prepare/commit with O(n + m) validation and generation
   adoption, on the current single message (closes F2 client side, F5, F6).
3. Schema change of §6 with `P` equal to the current per-message bound, CLI
   paging, transfer state machine and the order change (if approved). Every
   existing tab is then one page; `S` stays 64 on clients.
4. Separate runtime tab population capacity from `max_panes_per_tab`, together
   with the layout and workspace-snapshot couplings in §14.

## 14. Couplings outside this collection

Raising a tab's population above 64 also requires, independently of this
design: client `WorkspaceLayout` capacity (`max_nodes`) and its linear
`findLeaf` (layout rebuild is O(n·max_nodes)); `workspace_snapshot` per-tab
`pane_count`/foregrounds (`foreground_storage[max_panes]` spans all tabs);
`client_layout` wire bounds (`max_client_layout_tab_nodes`); `Tracker.capacity`
and `ResponseQueue.capacity`, which assume one request per pane of the shown
tab; GUI fixed arrays sized by the constant; and `agent_snapshot`'s 64 entries
with its own quadratic duplicate check on `(pane_id, generation)`. None is
changed here.

## 15. Open decisions

- **Order**: adopt ascending pane id (creation order) for snapshot and display
  order, or keep slot order with an id set in staging (§6.3).
- **Selection during a transfer**: supersede (recommended) or keep blocking.
- **`P`, `S`, R** (restart bound) and whether more than one transfer slot per
  client is allowed. Proposed starting points for discussion only:
  `P` = today's 64, `S` = the client's layout leaf capacity, small R with
  retry on the next trigger. Numbers need measurement.
- **Over-capacity tabs**: how a client presents a tab it refused to stage.
- **Per-tab vs global membership revision**: global first; per-tab if
  restarts are measured.
- **Unchanged shortcut**: whether a request may carry the client's published
  revision and receive an empty "unchanged" reply. This is useful only with a
  per-tab revision.
- Whether `lifecycle` stays on the wire when the runtime emits only `running`.
  This design keeps it unchanged.

## 16. Failure and test matrix (worked on paper)

Example tab for the traces: members `{3, 9, 12, 20, 31}`, revision 40, `P = 2`,
`S = 64`.

| # | Scenario | Trace | Required outcome / test |
| --- | --- | --- | --- |
| 1 | Normal multi-page | `(0,0)` → rev 40, total 5, `[3,9]`; `(40,9)` → `[12,20]`; `(40,20)` → `[31]` | Publish `{3,9,12,20,31}` once; 3 round trips |
| 2 | **Why revision binding is required** | Without it: `[3,9]`; pane 9 closes; `pane_exited(9)` reaches the client and removes 9 from the publication; `(·,9)` → `[12,20]`, `[31]` | The union would **resurrect 9** with nothing left to remove it. With the revision, `(40,9)` meets rev 41 → restart `[3,12]`, `[20,31]` → `{3,12,20,31}` |
| 3 | Pane added mid-transfer | id 40 created after page 1 → rev 41 → restart | Published set includes 40; no torn read even though new ids sort last |
| 4 | Continuous churn | every page meets a new revision | After R restarts: abort, limit notice, old publication kept, tab deferred |
| 5 | Duplicate across pages | `[3,9]` then `[9,12]` | First id 9 ≤ last 9 → protocol error; transfer reset first; publication unchanged |
| 6 | Duplicate within page | `[9,9]` | Decode rejects (not strictly increasing) before the receiver runs |
| 7 | Count over bound | `page_count = 65,535` | Decode rejects before reading descriptors |
| 8 | Short page | total 5, page `[3]` while P = 2 | Full-page rule → protocol error (bounds the page count) |
| 9 | Overrun | staged 4 of 5, page claims 2 | `4 + 2 > 5` in u64 → protocol error |
| 10 | Truncated bytes | `page_count = 2`, one descriptor present | `readInt` fails → link lost, as today |
| 11 | Huge total | `total_panes = 4,294,967,295` | `> S` → refusal limit, nothing staged, no arithmetic beyond u64 |
| 12 | Zero-progress page | `page_count = 0`, `total > staged` | Full-page rule → protocol error; no busy loop |
| 13 | Echo mismatch | request `(40,9)`, reply `after = 12` | Protocol error |
| 14 | Late reply after supersede | page for L arrives after select L′ | Continuation `.ignored` → dropped; staging already reset |
| 15 | Tab closed mid-transfer | `tab_closed(L)` between pages | `ignoreTab` + reset; later page ignored; no fatal `RuntimeRequestFailed` |
| 16 | Tab emptied before encode | all members closing | `total = 0` page, published empty, then `tab_closed` (today's behavior) |
| 17 | Disconnect mid-transfer | link lost after page 2 | `forget` resets; runtime has nothing to free; reconnect starts at `(0,0)` |
| 18 | Slow consumer | client stalls before page 3 | Runtime holds no state; other sessions unaffected; resumes or restarts later |
| 19 | Stale generation | snapshot `(7, gen 12)`, client pane 7 at gen 11 | Remove-plus-add in one commit; old buffers released post-commit |
| 20 | Generation not learned | client pane 7 at gen 0 | Adopt 12; buffers kept |
| 21 | Cross-tab id | snapshot of L includes a pane the client has in L′ | Rejected in validation (`PaneAlreadyExists`); no mutation |
| 22 | Allocation refused at prepare | the 3rd of 4 new records fails | Free 2 prepared; publication unchanged; limit or `SystemError` reported |
| 23 | Focus removed | focused 9 absent from the new set | Today's survivor fallback, computed at commit |
| 24 | Focus moved during staging | user focuses 20 while staging | Commit keeps 20 |
| 25 | Two multi-page tabs | L staging, L′ first page says multi-page | L′ deferred; requested after L completes |
| 26 | CLI | `telar tab` on a 5-pane tab with P = 2 | 3 exchanges, one buffer; same JSON as one page |
| 27 | Old peer | a client with the previous schema | Handshake refuses with `incompatible_schema`; no partial decode |
| 28 | Single page | n ≤ P | One round trip, no staging touched; equals today's flow except order |
| 29 | Restart shrinks to one page or empty | stage `[3,9]` at rev 40; next reply at rev 41 has total 1, `[31]` (or total 0) | Count restart, validate capacity, release transfer before publication; publish once; another tab can acquire staging |
| 30 | Shrinking restart cannot publish | same as 29, preparation refuses | Old publication unchanged, transfer idle, no stale outstanding request |
| 31 | Restart exhaustion | every continuation restarts until R is exceeded | Report once, release staging, block automatic retry for this tab; unrelated transfers may proceed |
| 32 | Standalone single page during another transfer | L is staging; L′ replies with one page | Publish L′ without clearing L; enforce L′ capacity even though staging is unused |

Rows 1–13 are wire/receiver unit tests (fuzz seeds extend
`server_fuzz_test.zig`'s `tab_snapshot_*` corpus). Rows 14–25 are model or
client-harness flow tests with `model_invariants.check`. Row 26 is a CLI test,
row 27 a handshake test, and the revision oracle of §13 covers rows 2–4 on the
runtime side. Rows 29–32 pin the receiver lifecycle corrections from integration
review.
