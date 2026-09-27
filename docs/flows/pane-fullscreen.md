# Pane fullscreen

Fullscreen belongs to the disposable client layout. It changes visibility and
size offers without changing runtime membership or destroying split geometry.

```text
actions.executeAction
  -> pane_resize.togglePaneFullscreen
     -> pane_fullscreen.toggle
     -> pane_resize.deliverPaneGeometry: validate exact geometry commit
     -> model.to_host.invalidate_placements
     -> pane_resize.resizeAttachedPanes: visible attached panes only
     -> pane_attachment.attachVisiblePanes: newly visible detached panes
  -> adapter observes the pane revision
```

An absent/empty layout is a no-op. A single pane can enter fullscreen. The
model preserves focus and every split ratio, toggles the flag and advances only
the pane revision. Left/right focus follows the displayed leaf order without
wrapping; up/down does nothing. Identity-based focus still works. Explicit
resize changes the hidden split tree; leaving fullscreen reveals it and keeps
the last selected pane focused.

Splitting a fullscreen pane preserves the mode and focuses the new pane.
Closing down to one pane also preserves it. Removing the final pane clears it;
an explicit toggle can always leave it. A single pane has no directional focus
target.

Entering offers the focused pane's content rectangle inside its border.
Exiting offers all attached visible panes and requests any newly revealed
siblings that remain detached after a tab round trip. Pending attachment
requests are deduplicated, and pane input remains disabled until confirmation.
The runtime accepts size offers only from the geometry owner; no success reply
is invented for `pane_resize`.

## Fullscreen presentation

The fullscreen pane keeps its border, including when it is the only pane.
Exiting fullscreen with one pane restores borderless content.

The window keeps the top border row plain and draws `FullscreenStrip` on the
bottom border row instead, inside the same `ChromeMetrics.pane_header` band
the pane header uses. The focused pane keeps its header entry: application
mark, index in bold, name in `subtext0` and the `StatusChip` of its agent.
The hidden panes follow in display order with the tab strip's label
composition (mark, index, name) and no tab surface, in `overlay1` with the
mark at 0.6 alpha, the way an unfocused pane is dimmed; hovering one lifts it
to `text`. A hidden agent that is blocked or failed keeps its `AttentionDot`.
The right end holds the progress capsule, the change-review button and a
`pane_fullscreen` control that sends the `toggle_pane_fullscreen` intent,
the same toggle as `prefix z`. Nothing in the band uses `accent`; the frame
ring alone marks focus. When the entries do not fit, hidden names give way to
mark-plus-index first, then the row scrolls around the focused entry with
`TabStrip.firstVisible`, so the focused pane stays visible at any width.
Hidden entries and the leave control are pixel band targets; the focused pane
stays reachable through its frame bands.

`TabStrip` appends a fullscreen mark (`⛶`) to the caption of every tab whose
layout is fullscreen, so fullscreen in another tab stays visible from the
strip.

## Failure and verification

The flag commits before graphics and resize effects. Delivery failure preserves
that commit and reaches the normal client error path. Runtime panes continue.
Reconnect restores retained fullscreen/layout only when pane membership matches
runtime authority; otherwise canonical display order supplies the layout.
Graphics are rebuilt. No operation directly schedules a draw.

Source: `src/client/panes/pane_resize.zig` and `src/model/state/ClientModel.zig`.
Tests: `src/client_tests/pane_lifecycle.zig` (including its fullscreen tab
round trip), `src/client_tests/synchronization.zig`, and shared model/layout
tests.
