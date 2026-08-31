# Copy mode

Copy mode is bounded, disposable client state for navigating one pane's
retained history and selecting text. `ClientModel.copy_state` is its only
authority. It owns the target pane, absolute cursor and anchor, selection mode,
entry viewport and current viewport. `ClientModel.Version.copy` identifies
committed changes independently from workspace, pane, chrome and prompt state.
Viewport commits advance `ClientModel.Version.viewport` separately.

The state and its motions allocate nothing. The runtime still owns scrollback
and performs the actual copy; the client sends a bounded `copy_selection`
request containing only coordinates.

## Input and commit

```text
host key, mouse wheel or native action
        |
key_routing / InputHandler.mouse / client_actions
        |
copy_modes adapter
        |
CopyModeHandler
        |
ClientModel.planCopyMode
        |
optional copy_selection effect before exit
        |
ClientModel.commitCopyMode
        |
optional set_pane_viewport effect after commit
        |
ClientModel.Version.copy and optional viewport
```

Entry resolves the attached focused pane and captures its current viewport.
An active name prompt, missing pane or repeated entry is a no-op. While copy
mode is active, `KeyRoutingHandler` sends semantic keys to copy mode and
consumes replayed bytes. Neither reaches the child. Copy mode does not make
`capturesKeys` true, so configured prefix bindings remain available. The mouse
is also captured; only wheel events over the target pane move the copy cursor.
Any native action other than copy-mode entry first leaves copy mode and
restores its entry viewport. See [Key routing](key-routing.md).

`ClientModel.planCopyMode` applies the pure motion component to a local state
copy. Unhandled keys and boundary motions return no plan and advance no
revision. `commitCopyMode` accepts only the revision and exact prior state that
were planned, so an obsolete plan cannot overwrite a newer command.

Copy delivery is intentionally ordered before the exit commit. If the outbox
is full, the selection and copy-mode revision remain intact and the user can
retry. Viewport synchronization follows the commit. If that effect fails, the
client retains the committed disposable state; reconnection or a later runtime
frame repairs the operational projection. Copy mode uses the same
`PaneViewportChange` effect port as normal scrolling, so graphics and
`set_pane_viewport` policy stay in `pane_viewports`.

## Clipboard delivery

```text
runtime-selected bytes -> schema.pane_clipboard
                              |
                    server_messages dispatcher
                              |
                    pane_clipboards.apply
                              |
                    screen.writeClipboard
                              |
                      host writer flush
```

`pane_clipboards.apply` is a terminal adapter, not an application use case.
The event neither reads nor changes `ClientModel`; the runtime already selected
the requested text. The schema decoder rejects an invalid pane identity, and
the adapter keeps the same check for direct callers. It writes the bounded
borrowed payload as OSC 52 and flushes it without retaining the decoded buffer.
A pane may exit after the copy request without cancelling the user's completed
copy.

Clipboard output bypasses the cell diff and does not advance a model version or
schedule presentation. The schema and terminal writer share the 64 KiB bound.

## Runtime frames and pane retirement

```text
schema.pane_frame
        |
pane_frames -> ApplyPaneFrameHandler
        |
ClientModel.applyPaneFrame
        |
screen commit + copy_mode.onFrame
        |
Version.frame always + Version.copy when copy state changed
```

A frame can prune retained rows or confirm a requested viewport. Reconciliation
is internal to the frame transaction. It pulls absolute selection coordinates
across pruned history, clamps them to the new row count and adopts the runtime
viewport. Unrelated or identical copy projections do not advance the copy
revision.

Pane and tab cleanup call `ClientModel.releaseCopyMode` through
`pane_resources`. Only retirement of the target pane closes the mode. Paste,
focus and graphics cleanup remain separate disposable effects. A model
transition that makes another tab active also releases copy authority, so
routing cannot remain attached to an inactive pane after an asynchronous
runtime response.

## Presentation

Neither the input adapter nor the application handler requests a draw or
writes a pane's `copy_view`. After the client event, the loop publishes the
model version. `Presenter` compares the `copy` revision with its last presented
version, projects the latest immutable `CopyModeProjection` into the
multiplexer damage cache and folds it into the paced frame.

When copy movement also changes the viewport, `Presenter` observes the
independent viewport revision and invalidates tab composition caches. The copy
use case does not mutate rendering caches.

The presenter retains only the projection it last painted. It clears the old
pane when the target changes or copy mode exits. Entering and leaving invalidate
the status bar; cursor and selection movement use exact pane damage instead of
invalidating all chrome. `multiplexer.Pane.copy_view` is therefore a rendering
cache, never semantic authority.

## Proof

- `src/frontend/input/copy_mode.zig` proves fixed-state motions, selection and
  frame reconciliation.
- `src/frontend/client/model.zig` proves entry authority, independent
  revisions, no-ops, stale-plan rejection, frame reconciliation and exact pane
  release.
- `src/frontend/client/application/copy_mode.zig` proves copy-before-exit and
  viewport-after-commit ordering, including both failure policies.
- `src/frontend/client/copy_modes.zig` owns the selection outbox adapter.
- `src/frontend/presentation/screen.zig` proves exact OSC 52 encoding,
  multi-chunk payloads and the terminal-side size bound.
- `src/frontend/client/pane_viewports.zig` owns graphics visibility and
  runtime viewport synchronization for both normal input and copy mode.
- `src/frontend/client/client_test.zig` proves routing, backpressure,
  clipboard delivery and presenter-only projection through the real client
  boundary.
- `src/frontend/client/presenter.zig` is the only client component that writes
  `multiplexer.Pane.copy_view`.
