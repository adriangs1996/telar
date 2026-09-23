# Pane fullscreen

Fullscreen belongs to the disposable client layout. It changes visibility and
size offers without changing runtime membership or destroying split geometry.

```text
AttachedClient.executeAction
  -> AttachedClient.togglePaneFullscreen
     -> ClientModel.togglePaneFullscreen
     -> AttachedClient.deliverPaneGeometry: validate exact geometry commit
     -> model.to_host.invalidate_placements
     -> AttachedClient.resizeAttachedPanes: visible attached panes only
     -> AttachedClient.attachVisiblePanes: newly visible detached panes
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
Exiting fullscreen with one pane restores borderless content. Its top edge
lists pane indices and foreground names in the same order used by navigation. The active label uses
the theme's accent background; other labels use subdued text. The strip
truncates names at grapheme boundaries before hiding labels, and always keeps
the active label visible when space permits. It uses fixed storage bounded by
`core.max_panes_per_tab`, does O(panes + label bytes) work only when the border
is drawn and adds no content row or persistent state. The focused pane's
progress indicator uses the remaining border space.

With KGP and RGB label colors, all pane labels use embedded JetBrains Mono
Regular. The selected pill is 75 percent of the cell height, vertically centered
on the border. Font size is at most half the cell height and four-thirds of the
cell width, so narrow terminal cells also get smaller text. The pill hugs the
measured text rather than filling its entire cell rectangle. Workspace labels
and pane contents are unchanged. The cell fallback uses regular-weight text.

`Compositor.fullscreenLabels` copies the already truncated label text into a
fixed-size `Plan` (`src/frontend/presentation/Plan.zig`). Each of at most 64
labels owns up to 80 UTF-8 bytes; media work never borrows pane names or cell
storage. The TUI view's `State.prepareGraphics` has its `PillRenderer` rasterize
that snapshot into one RGBA image of at most 1 MiB on the media path. It reuses
the sidebar's rounded fill and the existing text rasterizer. A position-only
change reuses the image; focus, text, theme or cell-size changes replace it.
There is one pending snapshot, not a replay queue.

Image data is chunked within the media pass's 256 KiB encoded budget. An open
continuation owns the graphics stream until completion or explicit abort;
replaced or hidden snapshots cancel it. Stale placement deletions may accompany
the next cell frame only when that stream is available. The view removes the cell
labels only after the exact snapshot, colors and placement have reached the
host. Gaps retain their border glyphs. Overlapping modals or toasts retire the
label image. Unsupported geometry, terminal-derived colors, missing font
glyphs and allocation failure preserve all cell labels and rectangular
selection. A failed host write exits through the existing presentation error
path. Client teardown frees the pixels and font face; reconnect rebuilds them.

The tab bar still draws the `pane_fullscreen` icon after the label of every tab
whose layout is fullscreen, so fullscreen in another tab stays visible from
the bar.

## Failure and verification

The flag commits before graphics and resize effects. Delivery failure preserves
that commit and reaches the normal client error path. Runtime panes continue.
Reconnect restores retained fullscreen/layout only when pane membership matches
runtime authority; otherwise canonical display order supplies the layout.
Graphics are rebuilt. No operation directly schedules a draw.

Source: `src/client/AttachedClient.zig` and `src/model/state/ClientModel.zig`.
Tests: `src/frontend/client/tests/pane_lifecycle.zig` (including its
`FullscreenReattachment` scenario), `src/frontend/client/tests/synchronization.zig`,
`src/frontend/client/tests/pane_splits.zig`, and shared model/layout tests.
