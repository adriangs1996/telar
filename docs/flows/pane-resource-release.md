# Pane resource release

Canonical pane, tab and workspace retirement share one concrete cleanup
operation. Callers pass a stable pane identity after committing canonical state.

```text
owning pane/tab/workspace operation
  -> AttachedClient.releasePaneResources
     -> ClientModel.releaseCopyMode
     -> ClientModel.releasePanePaste
     -> ClientModel.releaseReportedPaneFocus
     -> graphics.clearPane
```

Each model release matches the exact identity. Retiring a different pane
preserves the current copy, paste and reported-focus owners. Unknown or repeated
retirement still clears physical graphics so stale resources can be repaired.

Copy release advances its presentation revision. Paste and reported focus are
operational state and advance no display revision. Canonical retirement sends
no child input. A tab/workspace replacement that invalidates the whole reporting
context additionally forgets that context; intentional detachment uses the
separate paste/focus delivery path before detaching.

This operation is synchronous and has no generic effect callback. Model cleanup
allocates nothing; graphics cleanup uses the existing bounded resource stores.
Its caller's canonical revision determines presentation work.

Source: `src/client/AttachedClient.zig`.
Tests: exact model-owner tests in `src/model/state/tests/input_and_frames.zig`,
plus concrete pane
exit, tab removal and snapshot cleanup in
`src/frontend/client/tests/pane_lifecycle.zig`, `tab_lifecycle.zig` and
`synchronization.zig`.
