# Pane mouse input

A host pointer event first crosses client chrome and copy-mode ownership. If
neither consumes it, textual links get first refusal. Remaining events resolve
one pane and select one effect: begin mouse selection, move its viewport,
translate an alternate-screen wheel into cursor keys, or send an SGR mouse
report to the child. See [Mouse selection](mouse-selection.md).

A `scroll_pane` binding enters the same policy directly through native action
dispatch. Its command carries only an up/down direction and always targets the
focused pane. It does not run pointer hit testing or enter copy mode.
A physical hold repeats this same action at most once every 100 ms, provided
its original pane still owns focus. The client router drops excess repeats;
wheel events themselves remain unthrottled. See [Key routing](key-routing.md).

This is an interactive-path flow. It allocates no memory, retains no pane
pointer and adds no queue. The application decision uses fixed values. Mouse
reports use a 64-byte stack buffer, while delivery reuses the bounded
`model.to_runtime` outbox.

## Boundary and ownership

```text
host mouse event
        |
host_inputs.mouse (TUI) / GuiAdapter pointer input
        |
pointer_routing.apply
        |
resolve: prompt/model authority + raw pixels -> host cells
        |
copy_mode_pointer.apply
        |
unowned only
        |
HostChrome.pointer -> State.handleMouse
        |
view_interactions.apply
        |
inside workbench and unconsumed
        |
HostChrome.linkPointer or link_opening.inputLinkPointer
        |
unowned only
        |
pane_mouse_input.inputPaneMouse(.pointer)
        |
tab_layout.planPaneMouse
        |
pane_mouse_input.applyPaneMouseEffect
        |
        +-------------------+--------------------+
        |                   |                    |
 viewport effect    alternate-scroll effect   report effect
        |                   |                    |
        |            three cursor keys    pane_mouse_inputs.encodeReport
        |                   |                    |
pane_viewport.applyPaneViewport      +---------+----------+
                                      |
                              pane_input.sendPaneInput
                                      |
                              runtime attachment
```

`host_inputs.mouse` only delegates the host event after TUI tab dragging
declines it; the GUI calls `pointer_routing.apply` from its own pointer
ownership. `pointer_routing.apply` counts the event. Its `resolve` step
rejects input while a name prompt owns the client, except for a captured
selection gesture, or while no active tab exists, and converts supported raw
pixel coordinates to host cells.

`pointer_routing.apply` owns the order between the four policies.
It gives `copy_mode_pointer` first refusal, then asks the adapter's
`HostChrome.pointer` to resolve client chrome, then offers pane content to
`HostChrome.linkPointer` or `link_opening.inputLinkPointer`. It reaches
`pane_mouse_input.inputPaneMouse` only while the normalized pointer is inside the
post-interaction workbench and neither the view nor a link consumed it.
`copy_mode_pointer.apply` still owns copy-mode policy. See
[Copy mode](copy-mode.md).

A consumed view command ends the event. Pane focus is different: the focus
command commits first, then the same press may continue to the newly focused
child. View-local hover, scroll and modal changes advance their own revision
before later effects run.

Neither the adapter nor `pointer_routing.apply` inspects pane mouse modes,
chooses scroll policy, encodes SGR bytes or sends IPC.

## Pane plan

`tab_layout.planPaneMouse` resolves physical pointer events.
`tab_layout.planFocusedPaneMouse` resolves focused scroll without any
pointer coordinates. Both queries read pane geometry, child mouse modes and
scroll state and share construction of the immutable `PaneMousePlan`. Wheel
events target the visible pane under the pointer. Other events target the focused pane and are
dropped unless the pointer lies inside its content rectangle.

The result copies the pane identity, content rectangle, mouse protocol,
alternate-screen scroll flag and live-bottom state. It does not expose pane
storage to the operation. Planning does not advance a client model
revision.

## Focused scroll entry

```text
host binding or client Lua action
        |
host_inputs.applyDecision / GuiAdapter.applyInputDecision
        |
actions.executeAction, then scroll_pane dispatch
        |
pane_viewport.scrollPane
        |
pane_mouse_input.inputPaneMouse(.focused_scroll)
        |
tab_layout.planFocusedPaneMouse -> Resolved { plan, pointer }
        |
same wheel policy and effect delivery as physical input
```

`PaneMouseCommand` distinguishes `.pointer` from `.focused_scroll`. The
pointer router continues to accept only `PointerCommand` and wraps it at pane
delivery. `inputPaneMouse` preserves physical pointer commands unchanged. For
focused scroll it resolves the focused pane first, then builds a synthetic
wheel event at the first content cell with button 64 or 65 and no modifiers.
Pixel reports use host cell dimensions and the existing cell-center fallback,
not raw pointer pixels. Empty pane content produces no resolution.

`actions.executeAction` exits any active copy mode before dispatching this action,
restoring its entry viewport before the step. Plugin worker effects explicitly
reject `scroll_pane`; client Lua bindings and callbacks use native dispatch.

## Application policy

`pane_mouse_input.inputPaneMouse` resolves a plan and normalized pointer command, then chooses
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

`pane_mouse_input.inputPaneMouse` selects the effect and
`pane_mouse_input.applyPaneMouseEffect` delivers it through concrete viewport,
copy-selection and pane-input procedures. Mouse encoding remains in
`pane_mouse_inputs.encodeReport` and `keyinput.encodeSgr`; it does not mutate model
state.

## Effects and coordinates

`pane_mouse_input.applyPaneMouseEffect` applies the selected effect through
existing procedures. Viewport movement goes through
`pane_viewport.applyPaneViewport`. Alternate-screen keys and reports go
through `pane_input.sendPaneInput` with the mouse source, so neither
restores scrollback.

Cell reports use coordinates relative to the pane content. If the child asks
for pixel reports and the host supports raw pixels, `encodeReport` preserves
the exact pane-relative pixel. Otherwise it reports the center of the addressed
cell. SGR coordinates remain one-based on the wire.

The three alternate-scroll keys preserve order, but `model.to_runtime` may
split or coalesce their frames. If a later send fails, earlier accepted keys
remain queued. Every selected effect failure propagates to the event loop.

## Presentation

Mouse reports and alternate-scroll inputs do not change client presentation
state. A viewport effect advances `ClientModel.Version.viewport` only when the
offset changes. `Presenter` observes that revision on the paced loop and
recomposes the affected projection. No use case requests a draw directly.

## Validation

- `src/frontend/workspace/multiplexer.zig` proves focused button ownership,
  pointer-local wheel targeting, focus-only scroll targeting, empty-target
  rejection and value-copy planning.
- `src/client/input/pane_mouse_inputs.zig` proves exact raw-pixel and
  cell-center SGR encoding.
- `src/frontend/client/client_tests.zig` proves SGR buttons and pane-relative
  coordinates.
- `src/frontend/client/tests/host_interaction.zig` proves link ownership of a
  complete gesture and copy-mode pointer ownership.
- `src/frontend/client/tests/input.zig` proves default scroll bindings through
  host byte routing, focus rather than hover, synthetic SGR cell/pixel reports,
  alternate-screen keys, viewport no-ops, return to live output and copy-mode
  retirement. Physical hold tests cover both viewport directions, bounded
  repetition, endpoint no-ops and cancellation on focus or copy-mode changes.
- `src/frontend/client/tests/` proves prompt rejection after host
  telemetry, focus-before-press delivery, scrollback preservation, exact
  host-pixel delivery and pointer-local alternate-screen scrolling through the
  complete input entrypoint.
- `lib/keyinput/mouse_protocol.zig`, [Pane input](pane-input.md) and
  [Pane viewport](pane-viewport.md) cover protocol encoding and the two
  downstream effects.
