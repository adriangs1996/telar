# Native multiplexer

The GUI renders the shared client's semantic projection. Workspace and tab
requests, pane splits, focus, resize, fullscreen, copy mode, history and prompt
editing use the same handlers as the TUI. Native code owns window input and GPU
delivery; it does not reproduce those state transitions.

## Composition

`GuiClient.projection()` captures the current model, input mode and workbench
rectangle. `render/Scene.zig` borrows that projection for one preparation:

1. `TerminalRenderer` appends retained terminal cell meshes and cursors.
2. The thread surface paints the shared agent header and composer.
3. `chrome/Chrome.zig` draws bars, workspaces, tabs, the agent sidebar and pane
   decorations. Each component has its own file and receives a borrowed context.
4. `overlays/Overlays.zig` paints notifications, prompts, the command
   palette (`CommandPalette.zig`), history inspection and, for prompts opened
   outside the native key path, the goto picker and command suggestion.
5. `TerminalRenderer.seal()` publishes the atlas version after every layer has
   finished adding glyphs. The presentation commit records the panes represented
   by terminal and thread surfaces.

The chrome around the grid is measured in pixels, not cells.
`chrome/ChromeMetrics.zig` resolves the top bar (38), the tab strip (32) and
the status bar (26 logical px, scaled by the display and by `gui.font.size`)
and `TerminalRenderer.measure` subtracts them from the window before it
counts cells, so the grid origin sits under the tab strip and every row is a
complete terminal row. A window too short for one row gives the bands back:
status bar first, then the strip, then the top bar. `chrome/Regions.zig` only
splits that grid between the sidebar column and the workbench, and
`chrome/Bands.zig` places the pixel bands from the same origin, so a band never
overlaps a cell. Padding stays outside the grid. `TerminalMetrics.rect()` maps
grid rectangles to physical pixels once, using the same origin as pointer
input. Every terminal leaf is painted, including splits restored from a session.

The top bar holds the sidebar toggle, numbered workspace pills with an
attention dot when a blocked or failed agent lives in that workspace, the
selected workspace's location in the monospace face (`▣ ~/path ⎇ branch`,
branch only when the workspace list replica reports one; a worktree tab shows
its name because the replica has no entry for it), the configured
`top_right` slot and the TLS badge. The tab strip under it spans the
workbench: the active tab is a rounded-top block in the terminal background,
each tab carries a dot in the status colour of its most urgent agent when that
agent needs the person, the single-pane progress stroke stays on the active
tab, and `+` sends the `create_tab` intent. Pane headers fill the border row
with the index, the program name and a status chip; the cwd is no longer
shown there. Unfocused panes get one dim quad over their content and, while
their agent is blocked or failed, a two-pixel ring inside the border that fades
in over the model's animation counter (`RingFades`). The status bar shows the
mode chip and hints in prefix and copy mode; in normal mode it still lends a
cell row to the Lua `bottom` slots (`SlotRow`) until they move to the sidebar
footer, and the `tabs` slot paints nothing because tabs have their strip.
Attention colours and aggregation come from `chrome/attention.zig` over the
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
| `w` | Collapse or expand workspace list |
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
controls live in `HitMap`; band controls live in `BandHitMap` in device pixels.
A pointer sample the grid does not resolve goes to the delivered band targets,
and a band press keeps its gesture through drag and release even over cells.
The palette keeps its own bounded hit map of at most 16 visible rows in the
overlay state; a primary press on a row submits it through the `prompt_row`
intent. Pane content clicks focus before shared mouse routing; controls
consume their own gestures. Right-clicking a tab opens its rename prompt.
Sidebar scrolling moves one card pitch; scrolling and hover advance
`chrome.revision`; prefix changes advance the input revision. The sidebar
lays its header and cards out in device pixels inside its cell column and
publishes one cell-based `focus_agent` target per card
([sidebar contract](../sidebar.md)). `GuiClient.prepare` stamps monotonic
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

`tools/gui_multiplexer.py BINARY /tmp/NEW-DIRECTORY` drives AppKit against an
isolated runtime. It records shell PIDs and `stty size` while navigating splits,
fullscreen, sidebar, tabs and workspaces, then checks the same session after
closing and reopening the window. Its pointer clicks are window fractions
(`0.75` of the width); with the sidebar open they reach the right pane only
when the workbench spans more than half the window. Screenshots and action logs remain in the
chosen directory. [The Wayland matrix](gui-multiplexer-linux.md) also checks
configured bindings, tab movement, pane resize and close actions.
