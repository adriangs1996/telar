# Pane mouse input

A host pointer event first crosses client chrome and copy-mode ownership. If
neither consumes it, textual links get first refusal. Remaining events resolve
one pane and select one effect: begin mouse selection, move its viewport,
translate an alternate-screen wheel into cursor keys, or send an SGR mouse
report to the child. See [Mouse selection](mouse-selection.md).

A `scroll_pane` binding enters the same policy directly through native action
dispatch. Its command carries only an up/down direction and always targets the
focused pane. It does not run pointer hit testing or enter copy mode.

This is an interactive-path flow. It allocates no memory, retains no pane
pointer and adds no queue. The application decision uses fixed values. Mouse
reports use a 64-byte stack buffer, while delivery reuses the bounded client
outbox.

## Boundary and ownership

```text
host mouse event
        |
InputHandler.mouse
        |
pointer_routing adapter
        |
prompt/model authority + raw pixels -> host cells
        |
PointerRoutingHandler
        |
copy_mode_pointer
        |
unowned only
        |
View.handleMouse
        |
DispatchViewInteractionHandler
        |
inside workbench and unconsumed
        |
link_openings
        |
unowned only
        |
pane_mouse_inputs adapter
        |
PaneMouseHandler
        |
multiplexer.Model.planPaneMouse
        |
        +-------------------+--------------------+
        |                   |                    |
 viewport effect    alternate-scroll effect   report effect
        |                   |                    |
pane_viewports       three cursor keys       SGR encoding
        |                   |                    |
SetPaneViewportHandler      +---------+----------+
                                      |
                              PaneInputHandler
                                      |
                              runtime attachment
```

`InputHandler.mouse` only delegates the host event.
`pointer_routing` counts the event, rejects input while a name prompt owns the
client, except for a captured selection gesture, or no active model exists,
and converts supported raw pixel coordinates
to host cells. It captures one active model pointer for the synchronous call.

`PointerRoutingHandler` owns the order between the four policies.
It gives `copy_mode_pointer` first refusal, then asks the view to resolve client
chrome, then offers pane content to `link_openings`. It reaches
`pane_mouse_inputs` only while the normalized pointer is inside the
post-interaction workbench and neither the view nor a link consumed it.
`CopyModePointerHandler` still owns copy-mode policy. See
[Copy mode](copy-mode.md).

A consumed view command ends the event. Pane focus is different: the focus
command commits first, then the same press may continue to the newly focused
child. View-local hover, scroll and modal changes advance their own revision
before later effects run.

Neither `InputHandler` nor `PointerRoutingHandler` inspects pane mouse modes,
chooses scroll policy, encodes SGR bytes or sends IPC.

## Pane plan

`multiplexer.Model.planPaneMouse` resolves physical pointer events.
`multiplexer.Model.planFocusedPaneMouse` resolves focused scroll without any
pointer coordinates. Both queries read pane geometry, child mouse modes and
scroll state and share construction of the immutable `PaneMousePlan`. Wheel events target the
visible pane under the pointer. Other events target the focused pane and are
dropped unless the pointer lies inside its content rectangle.

The result copies the pane identity, content rectangle, mouse protocol,
alternate-screen scroll flag and live-bottom state. It does not expose pane
storage to the application handler. Planning does not advance a client model
revision.

## Focused scroll entry

```text
host binding or client Lua action
        |
InputHandler.action -> action_routing -> actions
        |
NativeActionHandler, then scroll_pane dispatch
        |
pane_mouse_inputs.apply(.focused_scroll)
        |
PaneMouseHandler -> Plans.resolve(Command)
        |
planFocusedPaneMouse -> Resolved { plan, pointer }
        |
same wheel policy and effect delivery as physical input
```

`Command` distinguishes `.pointer` from `.focused_scroll`. The pointer router
continues to accept only `PointerCommand` and wraps it at pane delivery.
The adapter's resolver preserves physical pointer commands unchanged. For
focused scroll it resolves the focused pane first, then builds a synthetic
wheel event at the first content cell with button 64 or 65 and no modifiers.
Pixel reports use host cell dimensions and the existing cell-center fallback,
not raw pointer pixels. Empty pane content produces no resolution.

`NativeActionHandler` exits any active copy mode before dispatching this action,
restoring its entry viewport before the step. Plugin worker effects explicitly
reject `scroll_pane`; client Lua bindings and callbacks use native dispatch.

## Application policy

`PaneMouseHandler` resolves a plan and normalized pointer command, then chooses
at most one effect. Its policy does not distinguish physical and synthetic
wheel events.

- A left press without child mouse tracking starts selection. Shift-left press
  forces selection when the host delivers it; textual links decline that press.
- A remaining child-tracked event with SGR enabled becomes a report, including tracked
  wheel events.
- An untracked wheel at the live bottom becomes three cursor-up or cursor-down
  inputs when alternate-screen scroll is enabled.
- Every other untracked wheel moves the client viewport by three rows.
- Other untracked non-wheel events are ignored.

The handler knows these rules but does not know how to mutate a viewport,
encode a report or reach the runtime.

## Effects and coordinates

`pane_mouse_inputs` applies the selected effect through existing use cases.
Viewport movement goes through `SetPaneViewportHandler`. Alternate-screen keys
and reports go through `PaneInputHandler` with the mouse source, so neither
restores scrollback.

Cell reports use coordinates relative to the pane content. If the child asks
for pixel reports and the host supports raw pixels, the adapter preserves the
exact pane-relative pixel. Otherwise it reports the center of the addressed
cell. SGR coordinates remain one-based on the wire.

The three alternate-scroll keys preserve order, but the outbox may split or
coalesce their frames. If a later send fails, earlier accepted keys remain in
the outbox. Every selected effect failure propagates to the event loop.

## Presentation

Mouse reports and alternate-scroll inputs do not change client presentation
state. A viewport effect advances `ClientModel.Version.viewport` only when the
offset changes. `Presenter` observes that revision on the paced loop and
recomposes the affected projection. No use case requests a draw directly.

## Proof

- `src/frontend/workspace/multiplexer.zig` proves focused button ownership,
  pointer-local wheel targeting, focus-only scroll targeting, empty-target
  rejection and value-copy planning.
- `src/frontend/client/application/pointer_routing.zig` proves exclusive owner
  order, workbench gating and selected-effect failure boundaries.
- `src/frontend/client/application/pane_mouse.zig` proves tracked-event,
  viewport and alternate-scroll selection, the live-bottom gate, ignored
  events and effect failure propagation.
- `src/frontend/client/controllers/input/pane_mouse_inputs.zig` proves exact
  raw-pixel and cell-center SGR encoding.
- `src/frontend/client/tests/input.zig` proves default scroll bindings through
  host byte routing, focus rather than hover, synthetic SGR cell/pixel reports,
  alternate-screen keys, viewport no-ops, return to live output and copy-mode
  retirement.
- `src/frontend/client/client_test.zig` proves prompt rejection after host
  telemetry, focus-before-press delivery, scrollback preservation, exact
  host-pixel delivery and pointer-local alternate-screen scrolling through the
  complete input entrypoint.
- `src/frontend/input/mouse_protocol.zig`, `pane-input.md` and
  `pane-viewport.md` cover protocol encoding and the two downstream effects.
