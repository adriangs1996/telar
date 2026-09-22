# Pane frame

A frame is the runtime's bounded screen projection for one client attachment.
The client owns validated cells before acknowledging application. Presentation
then consumes the latest model independently of runtime patch publication.

```text
AttachedClient.handleServerMessage(.pane_frame)
  -> AttachedClient.applyPaneFrame
     -> Model.applyPaneFrame
        -> multiplexer / Pane.applyFrame and copy-state reconciliation
     -> detached: no effects
     -> broken base: request_snapshot
     -> applied: frame_ack, graphics visibility, active resources
        -> telemetry and attachment-prompt reconciliation
  -> adapter observes presentation revisions
  -> successful host completion retires exact captured damage
```

The model resolves pane membership, ignores detached frames and compares patch
bases with the last applied frame. A broken base returns the known frame ID
without mutation. Valid frames commit owned cells, cursor, child modes, scroll
and copy-state pruning, then advance the frame revision even when visible cells
are unchanged. Failed application does not publish a revision.

`AttachedClient.applyPaneFrame` enqueues the ACK before synchronizing graphics and active
resources. A newly enabled child focus-report mode can therefore receive its
focus-in after application acknowledgement. The operation keeps commit and
ordered delivery in the same synchronous call; callers cannot substitute an
older frame commit between them.

ACK failure preserves owned cells and pending presentation damage. Later
resource failure preserves both that commit and any completed effects. These
errors reach the client loop; reconnect repairs disposable resources. The
runtime retains its per-pane bound of one unacknowledged patch, independently
of host write or GPU completion. One blocked client cannot hold another client's
presentation hostage.

Presentation observes the model revision after the event and folds it into
paced work. Preparing a frame seals one bounded commit; successful completion
calls `operations/session/presentation_delivery.apply`. It filters retired
attachment generations and retires only exact pending frame IDs. It sends no
cell ACK. Frame N+1 can be applied and acknowledged while N is being presented,
leaving N+1 damage pending for the next preparation.

A reconstructed pane may reuse a wire frame ID but has a new client attachment
generation. An old host completion cannot clear that pane's damage. Failed or
cancelled host delivery clears no model damage and never claims presentation.

Source: `src/client/AttachedClient.zig`,
`src/client/model/Model.zig`, `src/client/panes/Pane.zig`, and
`src/client/operations/session/presentation_delivery.zig`.
Tests: `src/frontend/client/tests/pane_updates.zig`,
`src/client/presentation/headless_tests.zig`,
`src/frontend/client/tests/presentation.zig`, `src/gui/tests/terminal.zig`,
and `src/client/panes/tests.zig` cover base recovery, ACK ordering, busy/failed
consumers, owned buffers, allocation failures and attachment-generation ABA.

## Terminal text metadata

`pane_frame` also carries bounded OSC 8 URI identities, row-local cell runs and
physical-row flags (`wrap`, `continuation`, wide-character padding, hyperlinks).
URLs do not enlarge `Cell`. `TextMetadataCapture` reads Ghostty VT state before
blit consumes damage and before a temporary history viewport is restored. It
uses the original page cell for hyperlink lookup, preserves explicit identities
across pages, and reserves its buffers at initialization or resize.

A snapshot carries a complete replacement, including an explicitly empty table.
A patch carries either a replacement or a zero-length unchanged marker. Separate
active/history sources and revisions prevent a viewport transition from reusing
the wrong table. Metadata-only changes publish a frame even when no cell changes.

The decoder validates dimensions, flags, offsets, run ordering, bounds, dictionary
indices and quotas before client application. The pane copies the complete
replacement into owned storage before the existing application ACK. Corrupt
metadata or an invalid frame base cannot install a partial replacement. The
metadata shares the frame ID and base: no extra queue, ACK, or GPU dependency.

Limits per viewport are 256 destinations, 2,048 runs, 4,096 bytes per URI and
64 KiB of combined URI bytes. Exceeding any capture quota emits `omitted` with
row flags and no links; hyperlink rows then decline textual fallback. Later valid
content restores a complete table. One reserved buffer occupies `87,563 + rows`
bytes: a pane uses one in the client, two in the runtime and two per attachment
for its independent history projection. Normal unchanged patches add only a
four-byte marker. The maximum cell grid reserves the worst-case metadata size
within the existing 4 MiB frame limit.

The wire fingerprint changes with this representation. Runtime and clients must
use matching builds. An already-running older runtime is never restarted
automatically: doing so would terminate the children it owns.
