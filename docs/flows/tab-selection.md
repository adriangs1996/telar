# Tab selection

The active tab belongs to the client. Runtime membership remains canonical.
All sources resolve their intent through one concrete operation:

```text
operations/input/actions.apply, delivered tab click or agent navigation
  -> operations/tabs/tab_selections.select
     -> reject a pending tab snapshot
     -> Model.selectTab
     -> tab_attachments.detach(previous)
     -> show selected graphics
     -> active_pane_resources.synchronize
     -> request_lifecycle.requestTabSnapshot(selected location)
  -> adapter observes presentation revisions
```

The target can be a stable identity, zero-based position or signed offset.
Missing/repeated targets, complete wrapped turns and fewer than two tabs are
no-ops. Offset reduction happens before addition, so full-range signed inputs
do not overflow. Callers do not inspect tab slots or implement navigation.

A real selection commits the active-tab revision and releases copy mode if it
belongs to the previous tab. Attachment retirement finishes that tab's captured
paste, sends its focus-out, delivers detaches, retires pending attachment
continuations and hides graphics. Attachment flags commit only after all of
that tab's effects succeed. An unrelated report owner is preserved.

Selected graphics become visible before active attachment/focus synchronization
and the canonical snapshot request. Snapshot reconciliation repairs membership
and requests detached panes with usable visible content. Late confirmations
for the previous tab cannot revive its ownership.

Selection and resource delivery are synchronous in the same operation. A
failure after the selection keeps the committed identity and completed effects,
then propagates to the client loop. Reconnect rebuilds disposable resources;
runtime tabs and PTYs remain alive. Presentation follows the active-tab revision
and is scheduled only by the host adapter.

Source: `src/client/operations/tabs/tab_selections.zig` and
`tab_attachments.zig` in the same directory.
Tests: `src/frontend/client/tests/tab_lifecycle.zig`, `pane_lifecycle.zig`,
`src/client/model/tests/tabs.zig`, and `src/client/workspace/` tests cover target
resolution, no-ops, wire order, exact ownership and canonical repair.
