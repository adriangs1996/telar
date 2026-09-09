# Pane fullscreen

Fullscreen is disposable client layout state. It changes which pane the client
shows and which attached sizes it offers to the runtime. It does not change
runtime pane membership or destroy the tiled split tree.

The action runs on the interactive path. It uses fixed-size model values and
the bounded client outbox, allocates no queue and waits for no runtime reply.

## Client transition

```text
native, Lua or plugin fullscreen action
        |
client_actions.apply
        |
TogglePaneFullscreen { area }
        |
TogglePaneFullscreenHandler
        |
ClientModel.togglePaneFullscreen
        |
DeliverPaneGeometryHandler
        |
OfferPaneGeometryHandler
        |                         |
pane_resize messages             presentation_lifecycle.observe
        |                         |
runtime socket                   Presenter
```

The shared action dispatcher supplies the current workbench rectangle and
delegates. It does not inspect the layout, invalidate `View` or request a draw.

`ClientModel.togglePaneFullscreen` rejects an absent active tab or an empty
layout. A single pane can enter fullscreen. A commit keeps the focused pane identity, toggles the
fullscreen flag and advances only `ClientModel.Version.panes`. The returned
change carries the exact tab, focus, pane revision, area and new fullscreen
state.

The layout retains every split ratio while fullscreen is active. Left/right
focus selects the previous/next leaf in display order without wrapping;
up/down focus is a no-op. Navigation changes only focus, never the split tree.
Explicit resize actions can still change the hidden split ratios. Exiting
fullscreen reveals the retained geometry, keeps the last selected pane focused
and restores spatial navigation through the same pane-focus transition.

Splitting a single fullscreen pane keeps fullscreen active and focuses the new
pane. Closing panes also preserves fullscreen when only one remains. Only
removing the last pane clears it automatically; an explicit toggle always
leaves the mode. With one pane, all directional focus actions are no-ops.

The fullscreen pane keeps its border, including when it is the only pane.
Exiting fullscreen with one pane restores borderless content. Its top edge lists pane indices and
foreground names in the same order used by navigation. The active label uses
the theme's accent background; other labels use subdued text. The strip
truncates names at grapheme boundaries before hiding labels, and always keeps
the active label visible when space permits. It uses fixed storage bounded by
`schema.max_panes_per_tab`, does O(panes + label bytes) work only when the border
is drawn and adds no content row or persistent state. The focused pane's
progress indicator uses the remaining border space.

With KGP and RGB label colors, all pane labels use embedded JetBrains Mono
Regular. The selected pill is 75 percent of the cell height, vertically centered
on the border. Font size is at most half the cell height and four-thirds of the
cell width, so narrow terminal cells also get smaller text. The pill hugs the
measured text rather than filling its entire cell rectangle. Workspace labels
and pane contents are unchanged. The cell fallback uses regular-weight text.

`Compositor` copies the already truncated label text into a fixed-size
`pane_labels.Plan`. Each of at most 64 labels owns up to 80 UTF-8 bytes; media
work never borrows pane names or cell storage. `View.prepareGraphics` rasterizes
that snapshot into one RGBA image of at most 1 MiB on the media path. It reuses
the sidebar's rounded fill and the existing text rasterizer. A position-only
change reuses the image; focus, text, theme or cell-size changes replace it.
There is one pending snapshot, not a replay queue.

Image data is chunked within the media pass's 256 KiB encoded budget. An open
continuation owns the graphics stream until completion or explicit abort;
replaced or hidden snapshots cancel it. Stale placement deletions may accompany
the next cell frame only when that stream is available. `View` removes the cell
labels only after the exact snapshot, colors and placement have reached the
host. Gaps retain their border glyphs. Overlapping modals or toasts retire the
label image. Unsupported geometry, terminal-derived colors, missing font
glyphs and allocation failure preserve all cell labels and rectangular
selection. A failed host write exits through the existing presentation error
path. Client teardown frees the pixels and font face; reconnect rebuilds them.

The tab bar still draws the `pane_fullscreen` icon after the label of every tab
whose layout is fullscreen, so fullscreen in another tab stays visible from
the bar.

## Geometry effects and presentation

Fullscreen and edge resizing share `DeliverPaneGeometryHandler` because both
need the same resource policy after their separate model commits. The handler
verifies active tab, focus, pane revision and fullscreen state, then invalidates
host graphics placements. `OfferPaneGeometryHandler` selects attached panes
with visible content from one layout snapshot; the adapter only publishes the
resulting commands. After resizing attached panes, the handler requests missing
attachments through `RequestActivePaneAttachmentsHandler`. This also covers
exiting fullscreen after a tab round trip, when hidden siblings remain
detached. Each newly visible detached pane receives one `open_pane` request;
input stays disabled until `pane_opened` confirms it. Existing pending requests
are not duplicated.

Entering fullscreen gives the focused pane the workbench minus its one-cell
border, so the client sends one `pane_resize`. Exiting restores the tiled snapshot and sends
one resize for each attached pane. The runtime accepts those messages only
from the workspace geometry owner and processes them through
`pane_resize.Controller` and `PaneResizeHandler`.

The protocol has no success response. Independently, `client_events` calls
`presentation_lifecycle.observe`. `Presenter` observes the pane revision and
schedules the paced frame that changes the visible composition.

## Failure and recovery

The fullscreen flag commits before graphics and resize effects. A local effect
failure reaches the client loop with that flag preserved. Client shutdown does
not stop runtime panes or PTYs. Reconnect restores the retained fullscreen and
split layout when pane membership still matches runtime authority; otherwise it
falls back to canonical pane order. Graphics state is always rebuilt.

Client layout updates and reconnect snapshots accept a one-leaf fullscreen
tree. Schema generation 43 requires an updated runtime because generation 42
rejects that state. The wire fields are unchanged; the handshake generation
prevents an older runtime from accepting the connection and then rejecting
layout persistence. Updating only the client is insufficient.

A runtime geometry rejection leaves PTY size unchanged and increments runtime
telemetry. The client does not roll back an unacknowledged resize.

## Proof

- `src/frontend/client/tests/pane_lifecycle.zig` covers exiting fullscreen
  after a tab round trip and verifies attachment confirmation and input to
  both panes.

- `src/frontend/workspace/layout.zig` proves that fullscreen retains tiled
  ratios, follows display order without wrapping, ignores vertical focus,
  restores spatial navigation, preserves fullscreen through single-pane splits
  and removals, clears on the last removal and round-trips one-leaf snapshots.
- `src/frontend/workspace/fullscreen_tabs.zig` covers regular-weight selection,
  Unicode truncation and label snapshots at narrow widths.
- `src/frontend/presentation/pane_labels.zig` covers ownership of grapheme text
  independently of cell-buffer lifetime and placement coordinates.
- `src/frontend/graphics/pill.zig` covers font size, transparency, quotas, image
  reuse, exact coverage, chunked transfer cancellation and fallback failures.
- `src/frontend/graphics/rasterizer.zig` covers matching measured/drawn advances
  and straight-alpha glyph blending without changing opaque blending.
- `src/frontend/client/presentation/view.zig` covers all cell labels until media
  completion, preserved border gaps, focus changes, resize and fullscreen exit.
- `src/frontend/workspace/multiplexer.zig` covers border composition, focus
  changes, progress animation and incremental idle rendering.
- `src/frontend/client/model/tests/panes.zig` covers horizontal fullscreen
  navigation, splitting from one fullscreen pane, geometry commits and no-op
  revision preservation.
- `src/core/schema_contract_test.zig` accepts single-pane fullscreen updates
  while still rejecting invalid trees and duplicate panes.
- `src/frontend/client/application/panes/toggle_pane_fullscreen.zig` proves
  single-pane entry, commit-before-delivery ordering and post-commit failure behavior.
- `src/frontend/client/application/pane_geometry_delivery.zig` proves shared
  validation, visible-pane selection, delivery order and retained commits on
  failure.
- `src/frontend/client/pane_geometry.zig` implements the physical graphics and
  runtime delivery ports.
- `src/frontend/client/tests/pane_lifecycle.zig` proves bordered and borderless
  resizes for a single pane, multi-pane tiled exit resizes and presenter-only
  frame scheduling through a substituted runtime socket.
