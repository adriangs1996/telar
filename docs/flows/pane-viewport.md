# Pane viewport

The client owns its visible scroll position. The runtime keeps an independent
per-attachment projection so it can return the requested history rows.

```text
pane_input.sendPaneInput, inputPaneMouse or applyCopyMode
  -> pane_viewport.applyPaneViewport
     -> pane_viewport.set
     -> pane_viewport.deliverPaneViewport
        -> validate exact committed pane, viewport and revision
        -> graphics.setPaneVisible
        -> sendRuntime(set_pane_viewport)
  -> adapter observes presentation revisions
```

`pane_viewport.set` resolves absolute, relative or bottom intents only for
an attached pane in the active tab. It clamps against retained history and
advances only the viewport revision. Missing, inactive, detached and unchanged
targets are no-ops. Copy mode owns its viewport transaction exclusively, so a
standalone viewport request cannot interfere with it.

Copy movement/exit commits viewport and copy state together, then calls
`pane_viewport.deliverPaneViewport` with the resulting change. The delivery entrypoint
therefore retains exact commit validation. Stale location, attachment, offset,
bottom state or revision executes no physical effect.

Keyboard and paste return to the bottom before sending bytes. Wire order is
`set_pane_viewport` then `pane_input`; mouse reports preserve the viewport they
describe. Focused scroll bindings reuse mouse wheel/alternate-screen policy and
do not immediately undo their scroll by treating the binding as child input.

Graphics visibility changes before runtime delivery. A graphics error prevents
the wire effect; a `model.to_runtime` error keeps committed scroll and completed graphics
changes. Neither failure rolls the viewport back.

The runtime clamps and pins the attachment viewport; reaching the bottom clears
the pin. Its next frame contains the accepted scroll projection. Frame
application advances the frame revision independently from local viewport
changes. The presenter reads those revisions and recomposes the active model;
operations do not invalidate presentation caches or schedule draws.

This work performs bounded arithmetic and at most one viewport enqueue.
Client death discards the attachment projection without changing the PTY.
Source: `src/client/panes/pane_viewport.zig`.
Tests: `src/model/state/tests/input_and_frames.zig`,
`src/frontend/client/tests/host_interaction.zig`, `input.zig` and
`mouse_selection.zig`; runtime attachment tests cover pinning and live-screen
restoration.
