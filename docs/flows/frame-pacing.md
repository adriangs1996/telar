# Frame pacing

A window presents frames at the refresh rate of the display it is on: 120 Hz
on ProMotion, 144 or 165 on an external monitor, 60 elsewhere. Nothing is
gained past the display's rate, because vsync discards the extra frames, so
the display is the ceiling. `gui.max_fps` caps it lower, for example to save
battery. The runtime sends each client its pane output at that client's
interval, so a faster window also receives cell frames faster.

Throttling and folding keep their shape at every rate: the same burst of four
frames after idle, the same 30 ms of input grace, and an idle window draws
nothing. Only the interval changes.

## End-to-end path

```text
NSScreen.maximumFramesPerSecond          wl_output current mode refresh
(viewDidMoveToWindow, windowDidChange-   (display_rate.c, on the outputs
 Screen, screen parameters change)        the window's surface entered)
        |                                          |
        +------- callbacks.display_interval -------+
                            |
             GuiAdapter.observeDisplay
                            |
     FramePacer.pace: max(display, 1/max_fps) within 1/240..1/30 s
                            |
        +-------------------+---------------------------+
        |                                               |
  FramePacer.cadence.interval              host_capabilities.frame_interval_ns
  (frameDelayNs on macOS;                  host_resize.deliverHostCommit
   frame_clock on Wayland through          -> configure_frame_interval
   callbacks.frame_interval_ns)            (also in every bootstrap)
        |                                               |
  CADisplayLink preferredFrameRateRange      frame_pacing.configure (runtime)
  follows callbacks.frame_interval_ns        -> Session.frame_interval_ns
                                             -> Attachment.cell_pacer.interval
```

## Window

`TelarView` reports `1 / NSScreen.maximumFramesPerSecond` of the window's
screen when the view enters a window, when the window changes screen and when
the screen parameters change (a display changing its rate, or one plugged in or
removed). After each report and each preparation it reads
`callbacks.frame_interval_ns` and asks the display link for that rate,
`CAFrameRateRangeMake(min(60, rate), rate, rate)`, so a capped window also
wakes less.

On Wayland, `display_rate.c` binds every `wl_output`, keeps the refresh of each
output's current mode and follows `enter` and `leave` on the window's surface.
The window reports the fastest output it is on; an output that reports no
refresh, as a virtual one may, keeps the previous interval. `frame_clock.c`
still waits for the compositor's frame callback and caps submission at the
interval Zig answers, instead of a fixed 60 Hz.

`GuiAdapter.observeDisplay` stores the display interval in `FramePacer` and
`FramePacer.pace` derives the window's interval: the display's, or longer under
`gui.max_fps`, clamped to the cadences the runtime accepts. A configuration
adoption runs the same derivation. Credits, grace and the cadence anchor carry
over, so a window moved to another display keeps its burst.

## Client and runtime

The interval is a host capability (`HostCapabilities.frame_interval_ns`,
1/60 s for a host that reports none, such as the terminal client). Once the
window has started, a changed interval commits through
`host_resize.applyHostUpdate`, which queues `configure_frame_interval` while
startup is opening or active, and `window_machines.shareHost` gives it to every
other machine the window shows. `Outbox.pushBootstrap` sends the current value
after `configure_terminal_colors`, so a reconnect never restores a stale rate.

`configure_frame_interval { interval_ns }` refuses an interval outside
`core.min_frame_interval_ns` (1/240 s) and `core.max_frame_interval_ns`
(1/30 s) on encode and on decode; both bounds are part of the schema
fingerprint. `frame_pacing.configure` clamps to the same bounds, stores the
interval on the session and sets it on each of the session's attachments;
`pane_attachment.attach` gives it to attachments created later. One client's
interval never changes another's cell pacing.

## Proof

- `lib/pacing/pace.zig`: a one-second flood presents 60, 120 or 144 frames at
  those rates, never more than the rate plus the burst; grace and burst keep
  their size at every rate.
- `src/gui/tests/frame_pacer.zig`: the window's interval follows the display,
  the cap and the bounds, and a 120 Hz cadence keeps its slots.
- `src/backend/runtime/tests/requests_test.zig`: the cell pacer follows the
  requested interval, clamps it, and stays per client.
- `src/core/schema_contract_test.zig`: the bounds are refused in both
  directions; the golden corpus pins the encoding.
- `src/client/config/gui_config_test.zig`: `gui.max_fps` accepts integers in
  30..240 and inherits through profiles.
