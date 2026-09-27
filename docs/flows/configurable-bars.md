# Configurable bars

One client owns the disposable top- and bottom-bar layout, the open bar panel,
its live Lua callbacks, tick deadlines and command worker state. The runtime
supplies host metrics but does not know where or how a client renders them.

## End-to-end path

```text
config.lua client.bars, client.panels
          |
Generation.parsePanels / parseBars / component_values.parse
          |
BarConfiguration (sources, panels) + callback registry
          |
config_adoption.completeConfigReload / initial generation
          |
BarLayout -> ClientModel.bars
          |                 |
          |   bar_updates.synchronizeBars -> model.bar_updates
          |                 |
          |   bar_updates.rearm -> workers.start(bar timer or bar_command)
          |                 |
          |   bar_updates.handleTick / completeCommand
          |                 |
          |     Generation.invokeBar -> component_values.parse
          |                 |
          |     configurable_bars.update / bar_panels.receive
          |                 |
          +------ Version.bars
                         |
             Client.presentation.observe
                         |
               GuiAdapter.prepare -> client.Projection
                         |
               StatusBar -> BarRow, BarOverlay
                         |
               bar_fitting.fit (shared)
```

Static content becomes a fixed bounded value during configuration parsing.
Dynamic and command slots enter the model as empty content tagged with their
configuration generation. The scheduler arms them immediately, so the first
value does not wait for a full interval.

## Components

A slot's content is a flat list of `Node`s in document order, bounded by
`GenericContent`: a child names its container by index, and text, sparkline
samples and click actions live in the list's own fixed storage. Bar slots and
panels use the same shape with different bounds (`Content`, `PanelContent`),
so one parser and one painter serve both.

`component_values.parse` validates every table against the fields its
component accepts and the place it appears in: inline components in a bar
slot, a group's children, a tooltip, a panel, or buttons in a callout or an
actions row. A rejected component rejects the whole render and keeps the last
valid content. Legacy segment tables become labels.

Tones map to palette roles in the model (`Tone.inkRole`, `Tone.markRole`), so
the same meaning always gets the same colour. Built-in metrics format
and choose their tone in `bar_metrics`; clocks format in `bar_clock`.

## Fitting

`bar_fitting.fit` degrades a row by priority until it fits. The window
measures every component at full and compact level in pixels and draws the
levels it gets back. A meter drops
its track before it disappears; a group disappears after all its children; a
warning or danger tone raises a component's effective priority. The function
is pure and bounded by the slot capacity: every node reduces at most twice.

Hidden top-level components are recorded in a `BarOverflow` for the frame and
counted in a `+N` chip; the overflow panel lists them.

## Interaction and panels

The GUI registers a band target for every group with an action, a url or a
tooltip; each reports `Intent.bar_component`. The
client resolves it against the current layout in `bar_components.activate`:
`open_panel` toggles the panel anchored to that component, any other action
runs through `actions.executeAction`, and a url goes to the link opening
worker. The adapter never calls Lua. The GUI paints
the hovered group's tooltip children above it.

`model.bars.panel` holds the open panel: its target (a configured index or the
overflow list), its anchor, its content, its status and the time of its last
render. Every opening gets a number, and a render started for an earlier
opening is discarded when it completes (`bar_panels.receive`). Escape, a
click outside the panel and any other chrome interaction close it
(`key_routing`, `view_interactions`).

The open panel is one more source of `BarUpdatesState`: `startPanel` arms it at
once when it opens and `stopPanel` forgets it when it closes, so a closed panel
costs nothing. A panel without `every_ms` renders once per opening and on
`refresh_panel`. Its command shares the single command worker with the bars.

Clock components need no Lua: `BarUpdatesState.clock_deadline` wakes the
bar timer at the next minute, or second for a format with `%S`, only while the
layout has a clock, and `advanceClock` writes `model.bars.now`.

## Ownership, budget and authority

`Generation` owns live Lua closures. `ClientModel` owns only typed layout,
content and panel values; neither the renderer nor the runtime can invoke Lua.
`BarUpdatesState` (`model.bar_updates`) owns deadlines, pending command bits,
the open panel's run and one command execution identity, whose target is a bar
position or a panel run. A command worker receives a complete argv copy and
publishes its output in a heap buffer owned by the completion;
`completeCommand` releases it on every path. It retains no generation pointer.

Ticks and command completions are observation events. Command execution never
runs on the client loop. A Lua render callback runs only when its observation
event is handled and is stopped by the client VM's instruction and wall-time
budget. `telar.json.decode` builds its tables inside a protected call, so a
Lua error there frees the parsed document. Rendering reads fixed values,
formats built-in components in fixed buffers, and allocates nothing.

Configuration may choose bottom left, center and right content, with exactly
one slot holding the built-in tabs source. It may choose only the top-right
content and still accepts up to three sidebar footer slots
(`sidebar_footer_left`, `_center`, `_right`) for compatibility. The window
displays no footer slots.
The native top bar owns workspace navigation and tabs. `StatusBar` paints the
bottom slots through `BarRow`, which omits the tabs source and appends legacy
`top_right` content before the far-right TLS badge. Prefix and copy mode
replace all components with `ModeBar`; they retain both the TLS badge and the
top navigation.

Workspace navigation, the sidebar toggle and the permanent ProxyTLS signal
remain authoritative Telar UI. The window fits custom content before it can
cover the proxy badge. Its peach color denotes an exact-host policy, red
denotes a suffix or global wildcard, and yellow denotes installed system trust
while the proxy is off. The native bars span the window.

## Bounds and scheduling

- Seven configurable positions, with exactly one bottom tabs source.
- 32 components, 1024 text bytes, 64 samples and 4 actions per bar slot; 64
  components, 4096 text bytes and 8 actions per panel; 8 panels.
- Bar intervals from 100 ms through one hour, with one replaceable deadline
  worker for the client, shared by bar sources, the open panel and clocks.
- One command process at a time and one coalesced pending bit per position and
  for the open panel.
- Thirty-two argv entries and 4096 argv bytes per command.
- Command timeouts from 100 ms through 10 seconds; 64 KiB of stdout for a
  render callback, one 512-byte line without one; 4096 stderr bytes.
- Lua callback limits inherited from the client configuration VM: bounded
  allocator, 100,000 instructions, 10 ms wall time and validated output.

When several intervals expire before the client handles them, `BarUpdatesState`
advances each deadline to its first future occurrence and evaluates once.
It handles at most one Lua render callback per observation event, bar
positions before the panel, so another ready event can run between configured
blocks. While a command runs, later expirations collapse into one pending
rerun. There is no replay queue proportional to elapsed time.

## Lifecycle and recovery

Startup derives deadlines from the active typed generation. A successful
reload first commits the new layout and swaps the generation, then replaces
all deadlines. A reload that changes the layout closes the panel, because
panel indices name the old configuration's panels; one that keeps it restarts
the open panel's source under the new generation. It clears queued command
bits but lets one already running process finish. Completion resolves its
exact execution ID and generation; obsolete output is discarded before Lua or
model state is touched. Client destruction cancels the timer and worker tasks
before freeing the generation.

A callback error, command spawn failure, timeout, nonzero exit or invalid
output leaves the last valid content untouched and stores a bounded diagnostic;
a panel also shows that its last render failed. The next scheduled evaluation
is still eligible to recover. Closure state and display content are disposable
and intentionally reset when their generation is replaced.

## Validation

- `src/model/bars/`: `GenericContent.zig` proves bounded components and
  rejected input; `bar_fitting.zig` degradation by priority, attention and
  tooltips; `bar_clock.zig` formatting; `bar_panels.zig` openings and stale
  renders; `bar_metrics.zig` thresholds; `model.zig` legacy segments and
  stale updates.
- `src/client/config/component_values.zig` proves the Lua vocabulary, places,
  panel actions and `telar.json.decode` in a panel render.
- `src/client/bars/command.zig` proves direct argv execution, single-line plain
  output and multi-line rendered output.
- `src/model/operations/configuration/bar_timing.zig` proves immediate
  deadlines, missed-tick coalescence, single-worker identity, queue reset on
  synchronization and the open panel's deadline.
- `src/gui/tests/bar_components.zig` proves band targets, tooltips above the
  bar, the anchored panel with its buttons, closing on an outside press and the
  overflow list; `status_bar.zig` slot order, legacy content and TLS priority.
- `src/client_tests/configuration.zig` crosses reload, Lua, a click, the
  panel tick and Escape, and proves that an old command completion is
  discarded.
- `tools/gui_bar.py` drives `docs/examples/bar` in a real window against an
  isolated runtime: hover, both panels, Escape, prefix mode and, where the
  window manager allows the resize, the overflow chip.
