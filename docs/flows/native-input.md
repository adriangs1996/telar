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

Each gesture has one owner. Chrome retains controls and resize handles, shared
copy mode retains selection, and `PointerRouting` retains child mouse reporting
by button. A child capture stores pane ID, attachment generation and tab location;
it resolves and clips against the current pane rectangle on drag/up. Focus
changes never redirect those events. Detachment or an attachment replacement
makes the capture stale, and its remaining events are consumed. The additive
`pane_mouse_inputs.reportRetained` port uses the existing encoder and input
controller with a `pointer_lease` target. A newly opened prompt cannot intercept
the release of a gesture already acquired by that pane. Focus loss reserves one
ordered cancellation message even under input saturation, releases live
gestures and invalidates queued starts.

Window fullscreen belongs to the native host: macOS uses Ctrl-Command-F and its
window control; Wayland uses F11 and xdg-toplevel requests. This is independent
of the shared `toggle_pane_fullscreen` action.

The interactive path uses a 1,024-item input ring, three pointer captures and the
shared bounded router and outbox. It performs no escape parsing, I/O, allocation
or plugin work before an explicit binding is matched. Socket backpressure pauses
drain, and transport completion resumes it.

Proof lives in `src/gui/tests/navigation.zig`, the input capability tests and
`src/client/input/routing_tests.zig`: all built-in actions resolve identically,
Ctrl-Space and modifier normalization match configured keys, paste stays with
prompts, key ownership survives reload, child drag remains on its original pane,
stale geometry and attachment generations cannot redirect input, and invalid or
oversized input is rejected without partial admission. `test-gui-window` exercises
the actual native AppKit entrypoints alongside GPU delivery and window closure.
