# Pane mouse input

A host pointer event first crosses client chrome and copy-mode ownership. If
neither consumes it, the client resolves one pane and selects one effect:
move its viewport, translate an alternate-screen wheel into cursor keys, or
send an SGR mouse report to the child.

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
raw pixels -> host cells
        |
prompt / copy_mode_pointer
        |
unowned only
        |
View.handleMouse
        |
DispatchViewInteractionHandler
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

`InputHandler` owns host parsing concerns. It counts the event, suppresses it
while a name prompt is active and converts supported raw pixel coordinates to
host cells. It then delegates first refusal to `copy_mode_pointer` without
reading copy state, pane storage or pane geometry. `CopyModePointerHandler`
owns copy-mode pointer policy; only its `unowned` result continues to the view.
The view then resolves client chrome. A consumed view command ends the event.
Pane focus is different: the focus command commits first, then the same press
may continue to the newly focused child. See [Copy mode](copy-mode.md).

After those owners finish, `InputHandler` delegates the remaining event. It
does not inspect pane mouse modes, choose scroll policy, encode SGR bytes or
send IPC.

## Pane plan

`multiplexer.Model.planPaneMouse` is the only query that reads pane geometry,
child mouse modes and scroll state for this flow. Wheel events target the
visible pane under the pointer. Other events target the focused pane and are
dropped unless the pointer lies inside its content rectangle.

The result copies the pane identity, content rectangle, mouse protocol,
alternate-screen scroll flag and live-bottom state. It does not expose pane
storage to the application handler. Planning does not advance a client model
revision.

## Application policy

`PaneMouseHandler` resolves one plan and chooses at most one effect.

- A child-tracked event with SGR enabled becomes a report, including tracked
  wheel events.
- An untracked wheel at the live bottom becomes three cursor-up or cursor-down
  inputs when alternate-screen scroll is enabled.
- Every other untracked wheel moves the client viewport by three rows.
- An untracked non-wheel event is ignored.

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
  pointer-local wheel targeting and value-copy planning.
- `src/frontend/client/application/pane_mouse.zig` proves tracked-event,
  viewport and alternate-scroll selection, the live-bottom gate, ignored
  events and effect failure propagation.
- `src/frontend/client/pane_mouse_inputs.zig` proves exact raw-pixel and
  cell-center SGR encoding.
- `src/frontend/client/client_test.zig` proves focus-before-press delivery,
  scrollback preservation, exact host-pixel delivery and pointer-local
  alternate-screen scrolling through the complete input entrypoint.
- `src/frontend/input/mouse_protocol.zig`, `pane-input.md` and
  `pane-viewport.md` cover protocol encoding and the two downstream effects.
