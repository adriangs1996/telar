# Sidebar animation

The client animates the status icon of each working agent. The frame is visible
client state, so `ClientModel` owns it. The scheduler owns only its pending
timer. The view receives the current frame as render input and does not advance
time.

The scheduler arms each next tick 120 milliseconds after processing while at
least one agent is working. A tick only commits state; paced presentation
remains the presenter's responsibility.

## End-to-end path

```text
accepted agent snapshot
        |
agent_snapshots adapter
        |
SidebarAnimationHandler.synchronize
        |
sidebar_animations scheduler, one pending timer
        |
ClientEvent.sidebar_animation_tick
        |
sidebar_animations.handleTick
        |
SidebarAnimationHandler.tick
        |
ClientModel.advanceSidebarAnimation
        |
frame + Version.sidebar_animation
        |
presentation_lifecycle.observe
        |
Presenter -> View.render(frame)
```

`SidebarAnimationHandler.synchronize` checks model policy and asks the
scheduler for a future tick without changing the frame. The scheduler's
`pending` bit coalesces repeated agent snapshots and rearm attempts into one
select task.

When the timer completes, `sidebar_animations.handleTick` first releases the
pending token. `SidebarAnimationHandler.tick` then advances the frame if a
working agent still exists and rearms the scheduler. If every agent has left
`working`, the tick is a semantic no-op and the loop stops.

## Model and presentation

`ClientModel.sidebar_animation_frame` is the only stored render frame.
`advanceSidebarAnimation` increments it with wrapping arithmetic and advances
only `Version.sidebar_animation`. Agent snapshot revisions and transient
sidebar scroll remain independent; an animation tick cannot look like a new
runtime snapshot or reset scroll position.

The use case and adapter never request a draw. After dispatch,
`presentation_lifecycle.observe` publishes the committed version. `Presenter`
compares it with the last observed and painted versions, invalidates the view,
and passes `sidebarAnimationFrame()` into `View.render`. The tick joins other committed
updates in the next paced frame.

## Failure and recovery

Failure to arm the first timer leaves the model unchanged. A rearm failure
after a successful tick preserves the new frame and revision because the model
commit precedes the effect. The adapter also clears the pending token before it
propagates a failed timer completion.

The client loop propagates these errors, and the disposable client exits.
Runtime processes and PTYs continue running. Reconnection starts a fresh client
model, and the next current agent snapshot starts a new animation loop when
needed.

## Proof

- `src/frontend/client/model.zig` proves active-only frame advancement and
  isolated versioning.
- `src/frontend/client/application/sidebar_animation.zig` proves inactive
  no-ops, synchronization without mutation, commit-before-rearm ordering and
  retained commits after effect failure.
- `src/frontend/client/sidebar_animations.zig` owns the single pending timer
  and releases it before handling completion.
- `src/frontend/client/presenter.zig` observes the dedicated revision and
  supplies the model frame to the view.
- `src/frontend/client/client_test.zig` proves a real scheduled tick mutates
  the model without requesting presentation before `presentation_lifecycle.observe`.
