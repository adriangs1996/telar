# Native multiplexer

The GUI renders the shared client's semantic projection. Workspace and tab
requests, pane splits, focus, resize, fullscreen, copy mode, history and prompt
editing use the same handlers as the TUI. Native code owns window input and GPU
delivery; it does not reproduce those state transitions.

## Composition

`GuiClient.projection()` captures the current model, input mode and workbench
rectangle. `render/Scene.zig` borrows that projection for one preparation:

1. `TerminalRenderer.begin()` resets the quad list and prepares retained resources.
2. `widgets/Composition.render()` builds one bounded `frame_widget.List` from
   the projection without drawing. It selects terminal and thread panes, the
   hovered link, navigation, status bar, sidebar, pane decorations, focus,
   notifications and the active modal. `Chrome.compose` and `Overlays.compose`
   append their widgets to this list.
3. `widgets.draw(canvas)` calls each component's `draw(Canvas)` in order.
   Containers draw their children through the same contract. `TerminalPane`
   uses the retained terminal cell meshes and cursor through `Canvas.terminal`.
4. After drawing and control registration succeed, the scene seals the frame
   and pending hit maps. `TerminalRenderer.seal()` records the atlas version
   after every widget has finished adding glyphs.
5. Successful native presentation publishes the matching controls and retires
   only the pane generations and damage captured by the composition's commit.

All components and drawing support live in `widgets`, with modal and notification
widgets in `widgets/overlays`. `Context` contains semantic inputs and hit maps;
the canvas is passed to `draw`. Persistent state such as `SidebarState` survives
the transient widget values. There is no separate `Chrome.paint` or `Overlays.paint`
entrypoint.

The chrome around the grid is measured in pixels, not cells.
`widgets/ChromeMetrics.zig` resolves top navigation (42) and the status bar
(26 logical px, scaled by the display and by `gui.font.size`)
and `widgets/SidebarBand.zig` resolves the sidebar band: `gui.sidebar.width`
logical pixels (default 284, bounds 220..480) scaled and rounded, clamped so
the workbench keeps 20 columns after the band and its 8 px gap, and zero
while the shared model hides the sidebar or the window cannot hold the
narrowest band. `TerminalRenderer.measure` subtracts the height bands from
the window height and the band plus its gap from the width before it counts
cells, so the grid origin sits under navigation and after the band, every
row is a complete terminal row and every column a complete terminal column.
A window too short for one row gives the height bands back: navigation
first, then the status bar. `widgets/Regions.zig` gives the
whole grid to the workbench; the column preference the runtime retains in
the shared layout is TUI-only and the GUI no longer reads it.
`widgets/Bands.zig` places the pixel bands from the same origin, the sidebar
band running from under navigation to the status bar, so a band never
overlaps a cell. Both horizontal bars span the full window independently
of sidebar visibility.
Padding stays outside the grid; while the band is visible it replaces the
left padding and the right padding remains. `TerminalMetrics.rect()` maps
grid rectangles to physical pixels once, using the same origin as pointer
input. Every terminal leaf is painted, including splits restored from a session.

The top bar holds the sidebar toggle and at most three numbered workspaces
on the left, with the active workspace centered except at the ends of the
runtime's list. Labels are centered inside equal slots that keep their positions
while names and selection change; a narrow window reduces them to the active
workspace. Overflow
counters select the nearest hidden workspace and aggregate attention dots
from the hidden range. Counters use plain text without a pill background,
including on hover. Global workspace numbers and keyboard intents stay
unchanged.
Native navigation ignores the retained `workspace_list_collapsed` preference;
only available width can reduce its visible workspace count.
When the current location is a worktree or its workspace has not reached the
list replica yet, the bar shows its current name without assigning another
workspace's identity. A missing name falls back to the location type and ID.

Tabs align to the far right of that same row. The active tab has rounded
upper corners and an open lower edge in the terminal background, without a
permanent accent stripe. Each tab carries a dot in the status colour of its
most urgent agent when that agent needs the person. Explicit child progress
can still add its temporary stroke to a single-pane tab, and `+` sends the
`create_tab` intent. Tab positions do not depend on sidebar visibility.
Pane headers fill the border row
with the index, the program name and a status chip; the cwd is no longer
shown there. Unfocused panes get one dim quad over their content and, while
their agent is blocked or failed, a two-pixel ring inside the border that fades
in over the model's animation counter (`RingFades`). The status bar shows
configured `bottom` slots through `SlotRow`, followed by legacy `top_right`
content and the reserved TLS badge. The `tabs` slot paints nothing because
tabs are already above. Prefix and copy mode replace the widgets with the
mode chip and hints, preserving TLS and navigation. The sidebar list uses the
space below its header down to the bottom inset.
Attention colours and aggregation come from `widgets/attention.zig` over the
shared `telar-client.agent_attention` comparator.

The native adapters consume the existing quad frame through Metal on macOS and
Vulkan on Wayland. No TUI compositor or Kitty delivery code is imported by the GUI.

## Input and invalidation

See [native input](native-input.md) for routing and gesture ownership. The default
prefix is Ctrl-B; configuration and hot reload replace it through the shared
router. Some useful default suffixes are:

| Suffix after prefix | Action |
| --- | --- |
| `%`, `"` | Split right, split down |
| Arrow, Shift-arrow | Focus pane, resize pane |
| `z` | Toggle pane fullscreen |
| `s`, Alt-left/right | Toggle sidebar, resize sidebar |
| `w` | Toggle the TUI workspace-list preference; native visibility follows available width |
| `N`, `W` | Create or rename workspace |
| `c`, `T` | Create or rename tab |
| `n`, `p`, `1`–`9` | Select tab |
| `,`, `.` | Move tab |
| `x`, `X` | Close pane or tab |
| `g`, `?` | Command palette prefixed `@` (agents and panes) or `?` (suggest a command); `>` lists actions |
| `/` | History palette |
| `[` | Enter copy mode |
| `a` | Toggle agent thread surface |
| `d` | Detach client |

Chrome hit maps retain stable pane, tab, workspace and agent identities. Cell
controls live in `HitMap`; band controls, including every agent card and the
sidebar resize handle, live in `BandHitMap` in device pixels.
A pointer sample the grid does not resolve goes to the delivered band targets,
and a band press keeps its gesture through drag and release even over cells.
A press on the sidebar's resize handle (a 6 px strip centred on the edge
line, horizontal resize cursor) turns every drag and the release into a
`BandCommand` carrying the width under the pointer, which `GuiClient`
adopts into its `SidebarPreference` without touching the shared model; the
next preparation measures the grid again and the PTY follows. The
`resize_sidebar` action does the same in 16 logical px steps from
`input/InputHandler.zig`. The gap between the band and the grid belongs to
no target.
The palette keeps its own bounded hit map of at most 16 visible rows in the
overlay state; a primary press on a row submits it through the `prompt_row`
intent. Pane content clicks focus before shared mouse routing; controls
consume their own gestures. Right-clicking a tab opens its rename prompt.
Sidebar scrolling moves one card pitch; scrolling and hover advance
`chrome.revision`; prefix changes advance the input revision. The sidebar
lays its header, cards, footer slot row and edge line out in device pixels
inside its band and publishes one pixel `focus_agent` target per visible
card ([sidebar contract](../sidebar.md)). `GuiClient.prepare` stamps monotonic
seconds on the chrome so card ages add the time since the agent snapshot
arrived.
Both enter `PresentationIngress`, so they can request a frame without changing
terminal cells. Modal gestures cannot fall through to panes behind them.

## Execution and budgets

`entrypoints/events.zig` is the sole consumer of GUI completions. It dispatches
socket input, native input, presentation, configuration, binding deadlines,
notifications, bar jobs and plugin jobs to the shared controllers. Host workers
use the existing inbox/outbox execution model. Layout replication is observed
once after a bounded turn.

Cell meshes remain retained across chrome redraws. Selection recolors a borrowed
cell value and never edits the canonical terminal buffer. A geometry-time quad
reservation covers the base scene, bounded overlays, notifications and fixed
decorations. ASCII shaping has dedicated cache entries, so labels do not evict
one another on an unchanged frame. Components do not retain projection pointers
or allocate widgets during paint.

Receipt ACKs still acknowledge owned runtime state. GPU delivery retires only
the captured presentation damage; newer state can arrive while a frame is in
flight. Chrome does not introduce another scheduler or an unbounded frame queue.

## Reopening a window

`WindowIdentity` holds an exclusive file lease next to the runtime socket for
the lifetime of `run()`. A concurrent window selects another slot. Reopening
a free slot reuses its identity, allowing the existing runtime layout replica
to restore tabs, split ratios, focus and fullscreen state. The lock file is
never unlinked; closing its descriptor releases the lease. It contains no
terminal or session data.

The endpoint directory and lock file must belong to the current user. The
directory cannot be writable by other accounts; lock files must be regular,
single-link files with mode 0600. Descriptors use CLOEXEC. The pool is bounded
at 64 live GUI windows per endpoint; the runtime's existing bounded layout
retention still determines which closed sessions remain available to restore.

## Verification

`zig build test-gui` exercises chrome clipping and hit maps, all default key
bindings, custom prefixes, gesture ownership, prompts, selection, layer ordering,
hot reload and ACK progress during GPU delivery. `zig build test-gui-window`
uses the native window implementation and its GPU backend.
`tests/top_navigation.zig` covers the centered workspace window, stable
identities, right-aligned tabs with the sidebar shown and hidden, narrow
windows and conditional child progress. `tests/status_bar.zig` covers widget
placement, compatibility with existing top slots and TLS priority.

`tools/gui_multiplexer.py BINARY /tmp/NEW-DIRECTORY` drives AppKit against an
isolated runtime. It records shell PIDs and `stty size` while navigating splits,
fullscreen, sidebar, tabs and workspaces, then checks the same session after
closing and reopening the window. Its pointer clicks are window fractions
(`0.75` of the width); with the sidebar open they reach the right pane only
when the workbench spans more than half the window, which the 284 px band
leaves on any window wider than about 600 pt. Screenshots and action logs remain in the
chosen directory. [The Wayland matrix](gui-multiplexer-linux.md) also checks
configured bindings, tab movement, pane resize and close actions.
