# Pane resize

The client owns split geometry. The runtime accepts offered PTY sizes only from
the workspace geometry owner. Follow the action directly into the operation:

```text
actions.executeAction
  -> pane_resize.resizePane
     -> pane_resize.resizePane
     -> pane_resize.deliverPaneGeometry: validate committed location,
        focus, fullscreen and pane revision
     -> model.to_host.invalidate_placements
     -> pane_resize.resizeAttachedPanes
     -> pane_attachment.attachVisiblePanes
  -> adapter observes presentation revisions
```

`pane_resize.resizePane` moves the nearest split edge on the requested axis. Missing
axes, bounded ratios and rectangles without usable content produce no change.
A commit advances the pane revision. Fullscreen keeps its split tree, so a
resize while fullscreen changes the hidden tiled layout.

`pane_resize.resizeAttachedPanes` computes one bounded layout snapshot with
`tab_layout.snapshot` and applies the attachment shelf reservation only to its
owner. It emits one `pane_resize` per attached pane with visible content;
fullscreen selects its focused pane. Cell pixel metrics come from
`model.host.host_size`. Callers resolve the target tab and geometry
once before invoking the delivery methods. Empty clients skip pane delivery.

After offering sizes, `pane_attachment.attachVisiblePanes` requests newly visible
detached panes whose canonical membership has been loaded. It skips already
pending requests. The fixed `model.to_runtime` outbox replaces obsolete unsent resizes for the
same pane instead of building a replay queue.

The runtime verifies the attachment and geometry lease before applying or
deferring the PTY resize. The protocol has no success acknowledgement. The
resulting cell snapshot respects synchronized-output blocks; expiry or EOF
releases pending work even if no later output arrives.

Layout commits before delivery. Outbox failure retains that layout and any
completed effects, then reaches the client error path. Runtime rejection leaves
the PTY size unchanged. A reconnect reconstructs disposable geometry and
resources. No operation requests a draw; presentation observes the pane revision.

Source: `src/client/panes/pane_resize.zig` and
`src/model/state/ClientModel.zig`.
Tests: `src/frontend/client/tests/pane_lifecycle.zig`,
`src/frontend/client/tests/host_resources.zig`,
`src/model/state/tests/panes.zig`, and runtime pane-resize/cell-projection tests.
