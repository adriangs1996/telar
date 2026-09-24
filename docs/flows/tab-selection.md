# Tab selection

The active tab belongs to the client. Runtime membership remains canonical.
All sources resolve their intent through one concrete operation:

```text
actions.executeAction, delivered tab click or agent navigation
  -> tab_selection.selectTab
     -> reject a pending tab snapshot
     -> tab_selection.commitSelection -> tab_selection.selectPosition / selectOffset
     -> tab_removal.detachTab(previous)
     -> show selected graphics
     -> pane_focus.synchronizeActivePane
     -> tab_snapshot.requestTabSnapshot(selected location)
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

Source: `src/client/workspace/tab_selection.zig`, `src/model/state/ClientModel.zig`
and `src/model/workspace/tab_selection.zig`.
Tests: `src/frontend/client/tests/tab_lifecycle.zig`, `pane_lifecycle.zig`,
`src/model/state/tests/tabs.zig` and `src/model/workspace/tab_flow_tests.zig`
cover target resolution, no-ops, wire order, exact ownership and canonical
repair.
