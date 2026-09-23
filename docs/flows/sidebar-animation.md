# Sidebar animation

The client animates the status icon of each working agent. The frame is visible
client state, so `ClientModel` owns it. `model.sidebar_animation_scheduler`
owns only its pending timer. The view receives the current frame as render input and does not advance
time.

The scheduler arms each next tick 120 milliseconds after processing while at
least one agent is working. A tick only commits state; paced presentation
remains the presenter's responsibility.

## End-to-end path

```text
accepted agent snapshot or pane progress
        |
agent_snapshot.applyAgentSnapshot / applyPaneProgress
        |
sidebar_animation.synchronizeSidebarAnimation
        |
model.sidebar_animation_scheduler, one pending timer
        |
client.workers.start(.timer, .sidebar_animation)
        |
Message.sidebar_animation_tick -> Client.update
        |
sidebar_animation.completeSidebarAnimationTick
        |
ClientModel.advanceSidebarAnimation
        |
frame + Version.sidebar_animation
        |
presentation_lifecycle.observe
        |
Presenter -> State.render(RenderInput.sidebar_animation_frame)
```

`sidebar_animation.synchronizeSidebarAnimation` checks
`ClientModel.sidebarAnimationActive` and asks the scheduler for a future tick
without changing the frame. The scheduler's `pending` bit coalesces repeated
agent snapshots and rearm attempts into one timer job. A host that reports no
`model.host.animation_frame_ns` gets no timer.

When the timer completes, `sidebar_animation.completeSidebarAnimationTick` first releases the
pending token. `ClientModel.advanceSidebarAnimation` then advances the frame if
a working agent or a pane with active progress still exists, and the client
rearms the scheduler. If none is left, the tick is a semantic no-op and the
loop stops.

## Model and presentation

`ClientModel.sidebar_animation_frame` is the only stored render frame.
`advanceSidebarAnimation` increments it with wrapping arithmetic and advances
only `model.sidebar_animation_revision`, reported as
`Version.sidebar_animation`. Agent snapshot revisions and transient
sidebar scroll remain independent; an animation tick cannot look like a new
runtime snapshot or reset scroll position.

The client and adapter never request a draw. After dispatch,
`presentation_lifecycle.observe` publishes the committed version. `Presenter`
compares it with the last observed and painted versions, invalidates the view,
and passes `Projection.sidebar_animation_frame` into the view's `render` through
`RenderInput`. The tick joins other committed
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

## Validation

- `src/model/state/tests/observations.zig` proves active-only frame
  advancement and isolated versioning.
- `src/client/notifications/sidebar_animation.zig` arms the single pending timer and releases
  it before handling completion; `src/client/notifications/sidebar_animation.zig`
  names its `Activity` result.
- `src/model/state/ClientModel.zig` owns the frame, its revision and the
  scheduler.
- `src/frontend/client/presentation/Presenter.zig` observes the dedicated revision and
  supplies the model frame to the view.
- `sidebar animation commits model state before the presenter observes it` in
  `src/frontend/client/tests/notifications_and_agents.zig` proves a real
  scheduled tick mutates the model without requesting presentation before
  `presentation_lifecycle.observe`.
