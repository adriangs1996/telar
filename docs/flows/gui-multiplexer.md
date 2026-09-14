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
4. `overlays/Overlays.zig` paints notifications, prompts, the goto picker,
   history inspection and command suggestions.
5. `TerminalRenderer.seal()` publishes the atlas version after every layer has
   finished adding glyphs. The presentation commit records the panes represented
   by terminal and thread surfaces.

`chrome/Regions.zig` reserves the bars and sidebar before the shared layout
calculates pane rectangles. A one-row host keeps a terminal row; two rows reserve
only the bottom bar. Padding stays outside the grid. `TerminalMetrics.rect()`
maps grid rectangles to physical pixels once, using the same origin as pointer
input. Every terminal leaf is painted, including splits restored from a session.

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
| `g`, `/`, `?` | Goto picker, history, command suggestion |
| `[` | Enter copy mode |
| `a` | Toggle agent thread surface |
| `d` | Detach client |

Chrome hit maps retain stable pane, tab, workspace and agent identities. Pane
content clicks focus before shared mouse routing; controls consume their own
gestures. Right-clicking a tab opens its rename prompt. Sidebar scrolling
moves one card pitch; scrolling and hover advance `chrome.revision`; prefix
changes advance the input revision. The sidebar lays its header and cards
out in device pixels inside its cell column and publishes one cell-based
`focus_agent` target per card ([sidebar contract](../sidebar.md)).
`GuiClient.prepare` stamps monotonic seconds on the chrome so card ages add
the time since the agent snapshot arrived.
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
closing and reopening the window. Screenshots and action logs remain in the
chosen directory. [The Wayland matrix](gui-multiplexer-linux.md) also checks
configured bindings, tab movement, pane resize and close actions.
