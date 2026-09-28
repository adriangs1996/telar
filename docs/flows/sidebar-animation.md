# Sidebar animation

The status icon of each working agent pulses. The window draws that pulse from
its own frame clock; no model state advances and no timer job runs. The model
tick described below was driven by the terminal client, and no current client
arms it.

## Window path

```text
Scene.prepare -> chrome.animation.begin(now) -> canvas.animation
        |
AgentCard (working agent) -> clock.step(120 ms) -> status_glyph.pulse(frame)
        |
FrameClock.requestAt(next step boundary)
        |
GuiAdapter.wakeupAfter -> native wake at the deadline
        |
GuiAdapter.update -> chrome.animation.requestPreparation -> needs_draw
```

`animate.FrameClock` keeps one frame timestamp and one coalesced deadline for
every visible widget; a later widget cannot postpone an earlier deadline.
`AgentCard` selects the pulse step from the clock every 120 milliseconds, and
the clock asks for a frame at the next step boundary. Only the window thread
owns the timer, and drawing never starts a worker. A frame that shows no
working agent requests no deadline, so the window stops waking.

The pulse changes no `ClientModel.Version`. Agent snapshot revisions and
sidebar scroll stay independent of it.

## Model tick

`ClientModel.sidebar_animation_frame`, its revision
(`Version.sidebar_animation`) and `model.sidebar_animation_scheduler` remain.
`sidebar_animation.synchronizeSidebarAnimation` arms a `.sidebar_animation`
timer only when the host reports `model.host.animation_frame_ns`. Neither the
window nor the headless client reports it, so in both the scheduler stays
idle. When armed, each tick releases the pending token, advances the frame
while an agent works or a pane shows progress, and rearms. The projection
carries the frame as `Projection.sidebar_animation_frame`, which `AgentCard`
reads only when it paints without a frame clock.

## Validation

- `src/gui/tests/sidebar_cards.zig` proves the working pulse samples its
  alpha from presentation time.
- `src/gui/tests/widget_animation.zig` proves widget frames paint without
  model ticks, fold rejected and late frames, and drop their deadline when the
  animated widget is hidden.
- `src/model/state/tests/observations.zig` proves active-only frame
  advancement and isolated versioning.
- `sidebar animation commits model state before the presenter observes it` in
  `src/client_tests/notifications_and_agents.zig` sets a host frame interval
  and proves a scheduled tick mutates the model without requesting
  presentation.
