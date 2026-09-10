# Client presentation contract

Each client connection owns one `lifecycle.State`. Its tokens are scoped to that
owner. Drivers cancel and join consumers before destroying the owner; a token
is not an address or a cross-client identifier.

`capture` borrows the semantic model for synchronous preparation. The projection
contains pane cells and semantic control state, not terminal widgets, writers,
textures or GPU commands. Adapters own their chrome, hit maps, physical metrics,
input decoding and host services. Pane cells do not prescribe a cell-based GUI.

`State.observe` coalesces revisions. `State.begin` seals one prepared commit and
returns a token. `State.complete` consumes that exact token once. Only a
successful completion returns a delivery for `DeliverPresentationHandler`.
Preparation, failed delivery and cancellation never retire model damage.
Obsolete tokens cannot consume a replacement flight. Receiving newer cells does
not invalidate an older successful delivery: it ACKs only captured frames and
leaves newer damage pending.

A commit includes attachment generations. The model allocates them across
workspace replacements and reattachments, and filters retired identities at
completion. Equal wire frame IDs from different attachments cannot clear each
other's damage or release each other's frame window. The handler derives ACKs
from the accepted commit; adapters cannot supply an unrelated ACK batch.

## Ownership and bounds

- The driver alone mutates the lifecycle. Preparation borrows the model;
  asynchronous consumers use adapter-owned storage or explicit resource leases.
- Lifecycle operations allocate nothing. Commit and geometry storage are bounded
  by `schema.max_panes_per_tab`; there is one flight and no frame queue.
- Geometry owns the region revision, tab, layout revision, host size and pane
  shapes. `Geometry.matches` checks new pane-coordinate gestures. Existing
  gestures retain their owner. Widget hit maps remain adapter-owned.
- Graphics and attachment leases belong to their consumers, not the commit.
  Cancellation is a completion notification after consumers stop borrowing;
  it is not permission to reuse storage while a worker still runs.
- Retired image bytes stay charged until their last lease returns. Credits are
  drained by the application before frame ACKs. A detached allocation cannot
  return credit to a later attachment.

## Adapters and recovery

The TUI keeps composition, cell diff, Kitty delivery, output buffers and pacing.
Its output actor borrows sealed bytes and returns a token after write completion.
A partial diff is never cancelled to make room for a newer frame. Host write
failure ends that client; reconnect rebuilds from runtime snapshots. New pointer
gestures cannot use changed pane geometry during an in-flight presentation.

`headless.Adapter` owns at most 16,384 cells and a bounded pane descriptor array.
It explicitly rejects larger preparations rather than truncating them. Tests
control busy admission, preparation failure, delayed completion, delivery
failure and cancellation. The adapter imports no terminal, font or window
resources. It is a presentation test adapter, not a second full CLI or an
implementation of untested host services.

`headless_tests.zig` assembles real shared workspace, frame, resource-delivery,
input and presentation handlers with the shared decoded-message entrypoint and
outbox. Unwired message adapters fail explicitly. Tests cover delayed input,
borrowed wire reuse, invalid bases, reattachment and workspace reconstruction,
stale completions, geometry ABA, credit ordering, independent clients, capacity
failure and allocation-free steady-state operation. TUI integration additionally
checks the host-write boundary and keeps its terminal-specific regression suite.
