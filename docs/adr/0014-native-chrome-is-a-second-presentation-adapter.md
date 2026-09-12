---
status: accepted
---

# Native chrome is a second presentation adapter over the semantic projection

[ADR 0012](0012-share-client-behavior-across-presentation-adapters.md) moved
client behavior into `telar-client` and left the native renderer as separate
work. That renderer is now defined: a GPU-drawn window in the spirit of
Ghostty, with a native sidebar, a multiplexer and agent views like T3 Code.
Terminal panes stay cell grids; everything around them is native chrome. The
TUI keeps every function at cell fidelity.

## Decision

The boundary both adapters share is the semantic projection, not a composed
cell buffer. The projection carries data with stable identities and versions:
workspaces, tabs, agents, notifications, keyboard focus and selection, the
active prompt or modal, the layout tree with its proportions, and per-node
content. It carries no widget hit map, hover, scroll offset or chrome metric.
Each presentation adapter owns its chrome, hit testing, pointer gestures,
animation and metrics. The physical values that cross into the shared model
are the workbench cell grid the adapter publishes, its cell pixel size, and
the columns and rows per terminal pane the model derives from them, because
the runtime needs those for the geometry lease. The TUI derives the grid from
its terminal size and chrome; a GUI derives it from its window, font metrics
and native chrome. Layout arithmetic therefore stays shared.

A layout leaf is a pane shown through one surface: its terminal cells, or a
Telar view of the agent running in it. A Telar view is content Telar composes
from client and runtime projections instead of from a PTY; the thread view
with its composer is the first. Its state lives in the client model and in
runtime projections, never in the adapter. The GUI paints it with native
widgets; the TUI paints it with cells. Agent mode as a second composition
beside the workbench is gone; ADR 0009 is superseded.

The feature surface of a client is the set of Telar actions, runtime commands
and application handlers in `telar-client`. An adapter maps host events to
that surface and maps the projection to what the host shows. A function that
exists only inside one adapter is a defect of the split. The headless adapter
is the proof that the surface is complete without any host.

The execution model stays independent of the adapter. The client loop takes
its host as a comptime parameter with three parts: presentation, input
producer and host services. No vtable sits on the interactive path.

## Considered options

- Share the composed cell buffer and let the GUI rasterize cells plus pixel
  overlays. It would reuse the TUI widgets but freeze the chrome at cell
  fidelity, which contradicts the goal, and it would pull the TUI widgets and
  compositor into `telar-client`.
- Share a widget framework or a display list. ADR 0012 already rejected
  prescribing a GUI before one exists; the two chromes are different products.
- Let the GUI own agent panes. Their state would die with the window, which
  fails the runtime test, and it contradicts
  [ADR 0009](0009-agent-mode-is-a-client-projection-of-one-runtime.md).

## Consequences

- TUI widgets, the cell compositor, `Screen`, diff, pacing and Kitty delivery
  stay in the TUI adapter. Configuration, plugins, bars and local transport
  move to `telar-client` because both adapters need them. The shared client
  therefore owns the Lua modules; an adapter never loads configuration.
- Controllers stop importing the terminal decoder and the Kitty delivery
  store; those become the TUI's input producer and graphics port.
- `Projection` loses its host `Region`. Pane geometry becomes a versioned
  per-node value the adapter publishes.
- Telar views exist in the model before the native renderer does, so the GUI
  never becomes the only place a function lives.
- The TUI mirrors of model state in its view, such as sidebar visibility,
  remain projections. They never become a second source of truth.
