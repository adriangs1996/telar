# Notifications

Notifications are bounded, disposable client state. `ClientModel` owns their
content, identity and lifecycle. The window's toast widgets borrow the
immutable center and never decide whether a notification exists, expires or
starts exiting.

## Publication path

```text
runtime notification                         local semantic event
        |                                              |
notifications.applyRuntimeNotification               Client procedure
        |                                              |
wire-to-client translation              construct NotificationInput
        |                                              |
        |                        notifications.publishNotificationNow
        |                                              |
notifications.publishNotification <-------------------+
                               |
                    notifications.publish
                               |
            model.notification_center + notifications_revision
                               |
                   notifications.scheduleNotificationTimer
                               |
                notifications.deliverHostNotification
                               |
               Client.presentation.observe after the turn
                               |
      GuiAdapter.prepare -> widgets/overlays/Notifications.prepare
```

`runtime_messages.handleServerMessage` delegates a runtime event to
`notifications.applyRuntimeNotification`. It translates protocol level, target
and millisecond duration into client notification values, samples monotonic
time and calls `notifications.publishNotification`. Request failures, agent
and proxy transitions, configuration or plugin diagnostics, and clipboard image
failures enter as complete `NotificationInput` values. Those procedures call
`notifications.publishNotificationNow`, which samples monotonic time and
delegates to `notifications.publishNotification`.
Diagnostic-producing procedures commit their banner before constructing
the input. Publication commits its owned model state before it touches the
timer. `deliverHostNotification` then follows the configured
`notification_delivery`: `telar` shows only the in-app center, and `system`
queues a best-effort `.system_notification` job on `client.to_background`;
a saturated queue drops it. Configuration refuses `terminal`, the OSC 9
channel of the retired terminal client, because neither the window nor the
headless client has an outer terminal to write it to.

`notifications.Center` copies title and message bytes into fixed buffers. It
keeps at most four items, refreshes an equivalent active item and replaces the
oldest item at capacity. Invalid UTF-8 is replaced before storage. Publication
does not request a frame directly. In particular, no title or message borrowed
from a decoded runtime buffer survives the synchronous adapter call.

## Runtime delivery request

```text
semantic notification action
             |
     actions.executeAction
             |
notifications.requestNotificationDelivery
             |
request_lifecycle.nextId + notifications.sendNotificationRequest
             |
      model.to_runtime.pushNotification -> show_notification
```

The action dispatcher delegates the complete bounded value.
`requestNotificationDelivery` allocates the request identity from
`model.request_lifecycle`, translates the semantic action to the wire value and
registers a `notification` continuation before delivery. `model.to_runtime`
copies title and message bytes, so a configuration reload or plugin
completion cannot invalidate queued text.

Accepted delivery changes no `ClientModel.Version` and schedules no frame. If
`model.to_runtime` rejects the request, the tracker removes the continuation
and the error propagates. The allocated identity is not reused.

## Runtime delivery report

```text
show_notification request + notification continuation
                         |
                  runtime fan-out
                         |
                 notification_shown
                         |
       notifications.completeNotificationDelivery
                         |
         delivered or local failure publication
```

`runtime_messages.handleServerMessage` passes the report to
`completeNotificationDelivery`. It removes the request identity by consuming
its continuation, then requires the exact `notification` type. The same
procedure owns delivery policy. A positive client count returns `delivered`
without changing the model or timer. A zero count publishes one local failure
through the normal owned notification flow and returns `undelivered`.

An unknown request or a continuation from another operation becomes
`UnexpectedNotificationReply`. Once found, the continuation is consumed before
type validation or publication, so a rejected or replayed report cannot finish
another request later.

## Time and presentation

`notifications.scheduleNotificationTimer` asks
`model.notification_center.nextDeadline` for the next useful wakeup. Moving
items wake at `model.host.animation_frame_ns`, while stable items sleep until
expiry. The deadline lives in `model.notification_scheduler`, a
`pacing.DeadlineScheduler` like the bar and sidebar animation timers. The
scheduler owns one atomic deadline, one wake event and one pending flag. When
it reports `.schedule`, the client queues one `.timer` job on
`client.to_workers`; `job_runner` waits in `deadline_timer.wait`. Replacing
or removing a deadline sets the wake event rather than adding another job. Its
fixed two-way select discards whichever wait loses the race.

The timer completes as one `.notification_tick` message.
`Client.update` passes it to `notifications.completeNotificationTick`,
which releases the scheduler before checking the result. It then advances the
center from elapsed monotonic time, bumps `notifications_revision` only when
state changed and rearms the next deadline.

`GuiAdapter.update` calls `Client.presentation.observe` after the turn. A
changed `notifications` version asks for a frame, and `GuiAdapter.prepare`
passes `projection.notifications`, a borrow of `model.notification_center`,
into that paced frame. Several lifecycle ticks inside one frame budget
therefore fold into one projection of the latest state.

The native GUI samples a copy of each visible item at `FrameClock.now_ns`.
`widgets/overlays/Notifications` owns four bounded stack-position slots keyed by item
ID; at most two cards draw. Whole-card translation and opacity never change
the measured text width. Position changes start from the current sampled
position. Tiny viewports and absent cards retire their motion slots.
The GUI's shared notification scheduler requests only transition completion
and expiry; host frame requests cover intermediate visible samples. Stable
cards request no animation frames.

`NotificationHits` captures pixel bounds and owned widget actions. The widget
dispatcher publishes those actions with the matching delivered frame, gives
the close control precedence, and retains gesture ownership if a card exits.
Modal scope suppresses notification input. Failed delivery preserves the old
controls while later preparation samples current time.

## Interaction path

```text
toast card or close control
      |
GuiAdapter.widgetInput -> widget routing (NotificationCard target)
      |
.notification_activate(id) or .notification_dismiss(id)
      |
view_interactions.apply (routing.dispatchIntent)
      |
notifications.activateNotificationNow or notifications.dismissNotificationNow
      |
ClientModel commit + notifications.scheduleNotificationTimer
      |
notifications.navigateNotification -> optional tab, workspace or pane navigation
```

The card's target carries only the notification ID and consumes the click.
Activation starts the exit transition and rearms its timer before
`navigateNotification` follows the semantic target through tab selection,
workspace handoff or pane focus. Dismissal starts the same transition without
navigation. Missing IDs and IDs already exiting are stale no-ops, so a repeated
hit cannot repeat its action or click through into a pane. Timer failure
prevents navigation; navigation failure retains both the committed exit and the
rearmed timer.

## Bounds and recovery

The center allocates nothing in steady state. Titles, messages and the four
slots are fixed-size values. Entering and exiting transitions last 200 ms in
wall-clock time; presentation cadence only selects samples from that curve.
The timer stores one replaceable deadline, so obsolete animation work does not
build a queue. Scheduling failure clears the pending token. Timer-task failure
also clears it before the event error reaches the client loop. Application
tests prove that scheduling failure leaves an earlier notification commit
intact. Scheduler tests prove that every job completion releases its token.

Notifications do not survive client death or reconnect. A new disposable
client starts with an empty center. Runtime-owned facts that must survive, such
as proxy status and agent state, rebuild their own model replicas and may emit
new notifications after reconciliation.

## Validation

- `src/gui/tests/notifications.zig` covers host-time sampling, failed delivery,
  fixed text geometry, stack motion, retirement, Unicode wrapping, pixel hit
  boundaries, warm allocation bounds and lifecycle-only GUI deadlines.
- `src/gui/tests/overlays.zig` covers notification replacement, close precedence,
  captured release and modal input isolation through the native dispatcher.

- `src/model/notifications/notifications.zig` proves bounds, owned text,
  duplicate refresh, replacement, elapsed-time transitions, stale interaction
  and UTF-8 handling.
- `src/model/state/tests/observations.zig` proves isolated notification
  versioning.
- `src/client/notifications/notifications.zig` owns local timestamp acquisition,
  diagnostic publication, host delivery, outbound action translation,
  delivery correlation, timer event ordering and the mapping from model
  deadlines to `model.notification_scheduler`.
- `lib/pacing/deadline_timer.zig` proves deadline replacement,
  removal, parking and pending-token release after successful and failed
  completions.
- `src/client_tests/notifications_and_agents.zig` proves outbound
  delivery and rollback, wire and local producers, commit-before-navigation
  ordering, a real lifecycle tick, presentation observation, retained
  commits after host failures and bounded agent alerts.
