# Architecture audit implementation

Base: `16b8205`. Each numbered item is implemented and committed independently.
The existing runtime/client split and interactive, media and observation budgets
remain constraints, not targets for consolidation.

## 1. History producer ownership

- A session-owned atomic `Sequence` reserves unique SQLite-compatible identities
  for concurrent producers; exhaustion never wraps. No producer mutates a raw
  counter. Reservation does not require waiting for the observation worker.
- Runtime reports go through `Pane.recordAgentCommand`, which captures runtime
  geometry instead of borrowing the observation actor's private terminal.
- Removed history-service plumbing from hook and plugin adapters.
- Proof: concurrent reservation and exhaustion tests; an agent-report test leaves
  the observation terminal uninitialized to verify that it is never accessed.
- Validation: `zig build test --summary all` passed.

## 2. Checkpoint ownership

- Pending checkpoint state owns its buffer and allocator as one optional value.
- Scheduling transfers ownership before starting the worker; both startup failure
  and completion release it through the same idempotent transition.
- Removed the application's separate buffer field and the duplicate free path.
- Proof: injected scheduler failure, retry, duplicate completion, debounce and
  disk-failure tests. `zig build test --summary all` passed.

## 3. Request composition and focus exchange

- Extracted the focus protocol controller with explicit pane/client stores,
  metrics and delivery dependencies. The dispatcher no longer implements the
  exchange; connection state exposes reservation/correlation/retirement methods.
- Moved audible transition policy from the PTY entrypoint to the agent capability.
- Checkpoint publication follows committed workspace events; rejected requests
  no longer mark persistence dirty. Pane closure is captured by lifecycle events.
- Proof: exact-generation, duplicate reservation and retry tests, plus the full
  suite: `zig build test --summary all` passed.

## Remaining items

## 4. Frontend transport boundary

- Transport state no longer imports Client, controllers or runtime entrypoints.
- The runtime I/O entrypoint owns cross-resource coordination; transport owns
  read reservations, bounded buffers and send preparation/cancellation.
- Input chunk limits belong to the input capability, not an application handler.
- Proof: isolated read reservation/failure test plus existing backpressure,
  graphics-credit and socket tests. `zig build test --summary all` passed.

## 5. History inspection dependency direction

- Read planning no longer imports a widget or constructs rendering-specific rows.
- An immutable presentation projection computes the scroll bound; the controller
  delivers that value through a semantic application operation.
- Proof: clamp/no-op revision test and existing browser integration tests.
  `zig build test --summary all` passed.

## 6. Git observation ownership

- The workspace repository owns the single outstanding probe and returns an
  owned path, with semantic reserve/cancel/complete operations.
- Aggregate completion commits observation time and Git status together.
- Removed duplicated pending flags from Application and Workspace; filesystem
  and process access live in the runtime's Git resource adapter.
- Proof: stale results, cancellation, due ordering and workspace removal while
  probing. `zig build test --summary all` passed.

## 7. Session-file readers

- Provider readers own transcript scanning and the Codex SQLite schema.
- The runtime application schedules an owned reader job and applies its typed
  completion without importing SQLite or opening provider files.
- Existing transcript append/rewrite/missing-file and database-title tests moved
  with the supported reader boundary. `zig build test --summary all` passed.

## 8. Agent observation values

- Reused the existing core manifest signal values directly, eliminating the
  unnecessary dependency through history detection.
- Agent observations own their wire-dialect vocabulary and inference policy;
  the proxy detector implements that contract. No backend-only value moves
  into core.
- Runtime composition translates panes into Identity; Identity no longer reads
  PTY/process resources. All production callers and their tests use that adapter.
- Proof: dialect policy and existing identity/evidence integration tests.
  `zig build test --summary all` passed.

## 9. Client submodel ownership

- Host state now owns capability/geometry validation and both host revisions.
  Model only propagates a committed geometry change into the tab collection.
- Plugin execution and clipboard capture each own their reservation, identifier
  exhaustion and stale-completion checks. Configuration selection remains in
  Model, which supplies the generation rather than exposing itself to a child.
- Public Model operations remain compatible; existing exhaustive host and
  asynchronous-ownership tests exercise the new owners.
- `zig build test --summary all` passed.

## 10. Pane media protocol

- Media owns budget accounting, mapped image allocations and shared transfers;
  the media-to-pane import cycle is removed.
- An ingestion state owns framing, chunk counts, prepared transfers and shared
  consumers. Its processor receives explicit emulator/allocator/response borrows,
  never a Pane. Pane retains actor lifetime and projection revision commits.
- Pipeline exposes reset semantics instead of requiring batch-array inspection.
- Existing quota, shared/file-frame, preparation and actor-lifecycle tests pass:
  `zig build test --summary all` (3347 tests).

## 11. Kitty presentation responsibilities

- Stateless KGP encoding lives in a codec with no store or layout dependency.
- Sidebar assets/rasterization and their tests live outside the pane image store.
- Store operations own presentation-clock advancement, successful inline/shared
  transmission commits and delete-overflow recovery. Writers commit these only
  after the corresponding encoding succeeds.
- Wire, paced/compressed/shared transmission, overflow and sidebar regression
  tests pass with `zig build test --summary all`.

## 12. Attachment boundaries

- The clipboard adapter owns native capture and source validation independently
  of Store, graphics or marker parsing.
- Pure marker scanning/navigation consumes cells and marker identities, not
  Slots or Store. Aggregate pairing and retirement remain one bounded mutation.
- Preview placement geometry/output state is separate from capture and identity
  reconciliation, reusing the existing path-marker implementation.
- Capture ownership, marker/deletion, generation-scoping and preview regression
  tests pass with `zig build test --summary all`.

## 13. Configuration parsing and local modules

- The local-module loader owns its Lua closure context, cache, canonical roots
  and dependency fingerprints, without borrowing Generation.
- Bar value parsing reuses lua_value independently of generation/callback state.
- Loader construction now checks the actual root-buffer capacity before copying;
  an oversized root is rejected with cleanup rather than exceeding the buffer.
- Added oversized-root regression; containment, escaping symlinks, reload and
  bar parsing tests pass with `zig build test --summary all`.

14. History search policies and bounded result accumulation.
15. Modal-specific prompt state and semantic selection.
16. Atomic history page request/result transitions.
17. Shared incremental HTTP/2 framing.
18. Per-command CLI grammars and argument cursor.
