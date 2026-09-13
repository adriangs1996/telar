# Native input and navigation

AppKit and Wayland translate platform events to the bounded `telar_gui_input`
ABI. The native callback copies committed text, paste chunks, semantic keys and
pointer samples into `NativeInput`; its readiness notification enters the shared
inbox. Only the window-thread consumer changes the client model.

`input/router.zig` instantiates the shared key router without an escape decoder.
It resolves the same configured prefix, built-in actions and Lua/plugin bindings
as the TUI. `input/InputHandler.zig` delegates keys and actions to the shared
controllers. Prompt editing, copy mode, pane focus, workspace and tab requests,
splits, pane fullscreen and detach therefore follow the existing application
handlers and runtime messages. Prefix status is projected from this effective
router, and a replaceable `.binding` timer expires ordinary partial chords.

Native keycodes retain press ownership through repeats and releases. Binding
reload inherits those physical leases while cancelling partial chords; releasing
a held binding cannot send its key to a newly selected pane. Committed IME text
has no physical lease when it cannot be associated with one native key. Paste
admission is atomic, bounded at 64 KiB, and splits only at UTF-8 scalar boundaries.
The shared paste router owns delivery to a prompt or the pane selected at start.

Pointer samples carry physical top-left coordinates and the current grid
revision. `PointerGeometry` removes padding and preserves subcell coordinates for
pixel mouse protocols. New gestures queued against replaced geometry are
rejected. Presentation geometry additionally rejects new pane gestures whose delivered
layout differs from the current model, including the interval before a new GPU
flight starts.

Chrome and overlays keep two bounded hit states. Painting replaces the prepared
state; pointer lookup uses the last delivered state. A matching successful GPU
completion publishes the prepared state by swapping an index. Failed and stale
completions cannot change visible control identities. This also covers tab
reordering, notification replacement and modal closure when the pane geometry
does not change. Hover, sidebar scrolling and captured gestures remain outside
these snapshots, so publishing a frame cannot erase input received in flight.

Each gesture has one owner. Chrome retains controls and resize handles, shared
copy mode retains selection, and `PointerRouting` retains child mouse reporting
by button. A child capture stores pane ID, attachment generation, tab location
and its last visible rectangle and cell metrics. Drag/up resolves that tab even
when another tab is active. A pane hidden by fullscreen keeps its last visible
geometry until release; visible panes update that geometry on each retained
event. Focus changes never redirect those events. Detachment or an attachment replacement
makes the capture stale, and its remaining events are consumed. The additive
`pane_mouse_inputs.reportRetained` port uses the existing encoder and input
controller with a `pointer_lease` target. A newly opened prompt cannot intercept
the release of a gesture already acquired by that pane. Focus loss reserves one
ordered recovery message even under input saturation, releases live gestures
and invalidates queued starts.

Window fullscreen belongs to the native host: macOS uses Ctrl-Command-F and its
window control; Wayland uses F11 and xdg-toplevel requests. This is independent
of the shared `toggle_pane_fullscreen` action.

The interactive path uses a 1,024-item input ring with one reserved recovery slot,
three pointer captures and the shared bounded router and outbox. If ordinary
admission fills, mouse-up occupies that recovery slot and cancels all native
gesture owners when the earlier input has drained. Key-up uses a fixed recovery
table for the hosts' 256 keycode identities and a FIFO of their arrival order;
duplicate releases share one entry. Recovery rejects new presses until these
releases finish through the existing router and outbox budget. Another key press
therefore cannot overtake the release of its previous physical lease.
The input path performs no escape parsing, I/O, allocation
or plugin work before an explicit binding is matched. Socket backpressure pauses
drain, and transport completion resumes it.

Proof lives in `src/gui/tests/navigation.zig`, the input capability tests and
`src/client/input/routing_tests.zig`: all built-in actions resolve identically,
Ctrl-Space and modifier normalization match configured keys, paste stays with
prompts, key ownership survives reload, child drag remains on its original pane,
stale geometry and attachment generations cannot redirect input, hidden panes
receive their releases, saturation cannot strand a physical lease, and invalid
or oversized input is rejected without partial admission. `test-gui-window` exercises
the actual native AppKit entrypoints alongside GPU delivery and window closure.
