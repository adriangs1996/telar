# Client presentation contract

Each client connection owns one `LifecycleState` from `LifecycleState.zig`.
Its tokens are scoped to that owner. Drivers cancel and join consumers before destroying the owner; a token
is not an address or a cross-client identifier.

`capture` borrows the semantic model for synchronous preparation. The projection
contains pane cells and semantic control state, not terminal widgets, writers,
textures or GPU commands. Adapters own their chrome, hit maps, physical metrics,
input decoding and host services. Pane cells do not prescribe a cell-based GUI.

`LifecycleState.observe` coalesces revisions. `LifecycleState.begin` seals one
prepared commit and returns a token. `LifecycleState.complete` consumes that
exact token once. Only a
successful completion returns a delivery for `DeliverPresentationHandler`.
Preparation, failed delivery and cancellation never retire model damage.
Obsolete tokens cannot consume a replacement flight. Receiving newer cells does
not invalidate an older successful delivery: it retires only captured damage
and leaves newer damage pending. Cell ACKs are sent by `ApplyPaneFrameHandler`
after validation and application to owned model storage, before host-resource
effects. Receiving bytes alone, a broken base, failed application or a detached
frame never produces an ACK.

A commit includes attachment generations. The model allocates them across
workspace replacements and reattachments, and filters retired identities at
completion. Equal wire frame IDs from different attachments cannot clear each
other's damage. Presentation completion cannot send another cell ACK or release
an unrelated runtime frame window.

## Ownership and bounds

- The driver alone mutates the lifecycle. Preparation borrows the model;
  asynchronous consumers use adapter-owned storage or explicit resource leases.
- Lifecycle operations allocate nothing. Commit and geometry storage are bounded
  by `schema.max_panes_per_tab`; there is one flight and no frame queue. While
  that flight is busy, ordered patches update the same model and accumulate
  damage. The next preparation captures the latest state, not a visual replay.
- Geometry owns the workbench-grid revision, tab, layout revision, grid
  metrics (columns, rows and cell pixels, whichever host supplies them) and pane
  shapes. `Geometry.matches` checks new pane-coordinate gestures. Existing
  gestures retain their owner. Widget hit maps remain adapter-owned.
- Graphics and attachment leases belong to their consumers, not the commit.
  Cancellation is a completion notification after consumers stop borrowing;
  it is not permission to reuse storage while a worker still runs.
- Retired image bytes stay charged until their last lease returns. Cell ACKs
  do not return graphics credit or authorize reusing consumer storage. Credits
  are drained independently on I/O and presentation completion. A detached
  allocation cannot return credit to a later attachment.

## Adapters and recovery

The TUI keeps composition, cell diff, Kitty delivery, output buffers and pacing.
Its output actor borrows sealed bytes and returns a token after write completion.
A partial diff is never cancelled to make room for a newer frame. Host write
failure ends that client; reconnect rebuilds from runtime snapshots. New pointer
gestures cannot use changed pane geometry during an in-flight presentation.

`HeadlessAdapter.zig`, exported as `telar-client.HeadlessAdapter`, owns at most
16,384 cells and a bounded pane descriptor array.
It explicitly rejects larger preparations rather than truncating them. Tests
control busy admission, preparation failure, delayed completion, delivery
failure and cancellation. The adapter imports no terminal, font or window
resources. It is a presentation test adapter, not a second full CLI or an
implementation of untested host services.

`headless_tests.zig` assembles real shared workspace, frame, resource-delivery,
input and presentation handlers with the shared decoded-message entrypoint and
outbox. Unwired message adapters fail explicitly. Tests cover delayed input,
borrowed wire reuse, invalid bases, reattachment and workspace reconstruction,
stale completions, geometry ABA, independent graphics credits, independent clients, capacity
failure and allocation-free steady-state operation. TUI integration additionally
checks the host-write boundary and keeps its terminal-specific regression suite.
