# Pane focus

Pane focus belongs to one disposable client. The runtime owns pane processes
and PTYs. Start at `operations/input/actions.apply`, mouse input, or agent navigation;
each source reaches the same concrete operation.

```text
host input -> input/actions or agent navigation
  -> operations/panes/pane_focus.apply
     -> Model.focusPane
     -> active_pane_resources.deliverFocus
        -> attachment reservation and geometry
        -> pane_focus_reports.sync
        -> fullscreen geometry and missing attachments
  -> adapter observes presentation revisions
```

`pane_focus.apply` accepts a stable identity or direction and commits before
resource delivery. `Model.focusPane` resolves only within the active tab. An
absent target, repeated identity or direction without a candidate is a no-op.
Tiled navigation uses spatial geometry. Fullscreen left/right follows displayed
leaf order without wrapping; up/down does nothing. The split tree is retained.

`active_pane_resources.deliverFocus` validates the exact location, identity and
pane revision because compound input transactions also call it with a captured
focus commit. It synchronizes the attachment shelf before focus reports; a
changed shelf reservation re-offers geometry. A fullscreen focus change
invalidates placements and offers the visible pane size, then requests missing
attachments. A newly visible detached pane cannot receive input until its
correlated `pane_opened` confirmation arrives. Pending requests are deduplicated.

Semantic focus and reported child focus are separate. `pane_focus_reports.sync`
commits the reported target in the model and emits focus-out before focus-in.
Enabling focus reports on an already focused pane sends focus-in once. Disabling
them updates report state without sending focus-out. Report state changes no
presentation revision and its bytes are not counted as user input.

Intentional tab detachment clears only that tab's report owner, before its
`detach_pane` messages. Canonical pane retirement calls `pane_resources.release`
and silently forgets that exact owner. Canonical tab/workspace replacement can
forget the entire obsolete reporting context through `pane_focus_reports.retire`.
These paths do not send child input to a retired attachment.

Tab, workspace, frame and snapshot operations call
`active_pane_resources.synchronize` directly. Agent snapshots synchronize only
attachments because they cannot change terminal focus. A mouse click completes
focus/resource effects before forwarding its triggering mouse event.

The work is bounded by the pane store and fixed outbox. A delivery failure
preserves committed focus and completed effects; it propagates to the client
loop. Reconnect rebuilds disposable state without stopping runtime panes.
Operations do not draw: the adapter observes the changed model revision.

Source: `src/client/operations/panes/pane_focus.zig`,
`active_pane_resources.zig` and `pane_focus_reports.zig` in the same directory.
Tests: `src/frontend/client/tests/pane_lifecycle.zig`,
`src/frontend/client/tests/mouse_selection.zig`, and
`src/client/model/tests/panes.zig`.
