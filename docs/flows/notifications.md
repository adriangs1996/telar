# Notifications

Notifications are bounded, disposable client state. `ClientModel` owns their
content, identity and lifecycle. `View` and both toast renderers receive an
immutable snapshot and never decide whether a notification exists, expires or
starts exiting.

## Publication path

```text
runtime notification             request failure or local diagnostic
        |                                      |
notifications.applyRuntime       publishNow or publishDiagnostic
        |                                      |
wire-to-client translation                    |
        +------------------+-------------------+
                           |
                notifications.publish
                         |
             PublishNotificationHandler
                         |
              ClientModel.publishNotification
                         |
       notifications.Center + Version.notifications
                         |
             notification_timers.reschedule
                         |
                 presentation_lifecycle.observe
                         |
          Presenter -> View.render(snapshot)
```

The dispatcher delegates a runtime event to `notifications.applyRuntime`. The
adapter translates protocol level, target and millisecond duration into client
notification values, adds the monotonic timestamp and invokes the existing
publication use case. Request failures, agent and proxy transitions,
configuration or plugin diagnostics, and clipboard image failures enter
through `notifications.publishNow` or `publishDiagnostic` and converge on the
same use case. `publishNow` owns monotonic timestamp acquisition.
`publishDiagnostic` requires the model's current diagnostic and applies the
bounded failure level and seven-second duration. The handler commits the owned
model state before it touches timer infrastructure.

`notifications.Center` copies title and message bytes into fixed buffers. It
keeps at most four items, refreshes an equivalent active item and replaces the
oldest item at capacity. Invalid UTF-8 is replaced before storage. Publication
does not request a frame directly. In particular, no title or message borrowed
from a decoded runtime buffer survives the synchronous adapter call.

## Runtime delivery request

```text
semantic notification action
             |
     client_actions.apply
             |
notifications.requestDelivery
             |
request_lifecycle.nextId + deliverNotification
             |
      show_notification
```

The action dispatcher delegates the complete bounded value. The notification
adapter allocates its request identity, translates the semantic action to the
wire value and registers a `notification` continuation before delivery. The
outbox copies title and message bytes, so a configuration reload or plugin
completion cannot invalidate queued text.

Accepted delivery changes no `ClientModel.Version` and schedules no frame. If
the bounded outbox rejects the request, request lifecycle removes the
continuation and propagates the error. It does not reuse the allocated identity.

## Runtime delivery report

```text
show_notification request + notification continuation
                         |
                  runtime fan-out
                         |
                 notification_shown
                         |
       notifications.applyDeliveryReport
                         |
       HandleNotificationDeliveryHandler
                         |
         delivered or local failure publication
```

The client adapter removes the request identity by consuming its continuation,
then requires the exact `notification` type. The application handler owns
delivery policy. A positive client count returns `delivered` without changing
the model or timer. A zero count publishes one local failure through the normal
owned notification flow and returns `undelivered`.

An unknown request or a continuation from another operation becomes
`UnexpectedNotificationReply`. Once found, the continuation is consumed before
type validation or publication, so a rejected or replayed report cannot finish
another request later.

## Time and presentation

`notification_timers` asks
`ClientModel.nextNotificationDeadline` for the next useful wakeup. Moving
items wake at the presenter's frame interval, while stable items sleep until
expiry. It uses the same `deadline_timer.Scheduler` as host input. The
scheduler owns one atomic deadline, one wake event and one pending client
select task. Replacing or removing a deadline sets the wake event rather than
adding another task. Its fixed two-way select discards whichever wait loses
the race.

`notifications.handleTick` releases the completed task before checking its
result. It then executes `AdvanceNotificationsHandler`, which advances the
center from elapsed monotonic time, commits `Version.notifications` only when
state changed and rearms the next deadline.

`client_events` calls `presentation_lifecycle.observe` after the event.
`Presenter` compares the notification version with the last version it painted,
invalidates the view and passes `ClientModel.notificationSnapshot()` into the
next paced frame. Several lifecycle ticks inside one frame budget therefore
fold into one projection of the latest state.

Cell toasts and the Kitty Graphics renderer consume the same immutable center.
The view stores only physical presentation state such as hit regions, overlay
cleanup and prepared raster data. Graphics preparation runs on the independent
media path and cannot mutate notification semantics.

## Interaction path

```text
toast hit region
      |
View.handleMouse
      |
activate(id) or dismiss(id) intent
      |
InputHandler
      |
ActivateNotificationHandler or DismissNotificationHandler
      |
ClientModel commit + timer reschedule
      |
notification adapter -> optional tab, workspace or pane navigation
```

The view returns only the notification ID and consumes the click. Activation
starts the exit transition and rearms its timer before the notification adapter
follows the semantic target through the tab, workspace or pane use case.
Dismissal starts the same transition without navigation. Missing IDs and IDs
already exiting are stale no-ops, so a repeated hit cannot repeat its action or
click through into a pane. Timer failure prevents navigation; navigation
failure retains both the committed exit and the rearmed timer.

## Bounds and recovery

The center allocates nothing in steady state. Titles, messages and the four
slots are fixed-size values. Entering and exiting transitions last 200 ms in
wall-clock time; presentation cadence only selects samples from that curve.
The timer stores one replaceable deadline, so obsolete animation work does not
build a queue. Scheduling failure clears the pending token. Timer-task failure
also clears it before the event error reaches the client loop. Application
tests prove that scheduling failure leaves an earlier notification commit
intact. Scheduler tests prove that every task completion releases its token.

Notifications do not survive client death or reconnect. A new disposable
client starts with an empty center. Runtime-owned facts that must survive, such
as proxy status and agent state, rebuild their own model replicas and may emit
new notifications after reconciliation.

## Proof

- `src/frontend/notifications/root.zig` proves bounds, owned text, duplicate
  refresh, replacement, elapsed-time transitions, stale interaction and UTF-8
  handling.
- `src/frontend/client/model.zig` proves isolated notification versioning and
  immutable snapshot access.
- `src/frontend/client/application/notifications.zig` proves commit-before-
  timer-before-navigation ordering, delivery policy, stale interaction
  behavior and retained commits after effect failures.
- `src/frontend/client/notifications.zig` owns local timestamp acquisition,
  diagnostic publication, outbound action translation, delivery correlation
  and timer event ordering.
- `src/frontend/client/notification_timers.zig` maps model deadlines to the
  shared scheduler and notification events.
- `src/frontend/client/deadline_timer.zig` proves deadline replacement,
  removal, parking and pending-token release after successful and failed
  completions.
- `src/frontend/client/view.zig` proves immutable rendering, ID-only intents
  and cell restoration after an exit.
- `src/frontend/client/client_test.zig` proves outbound delivery and rollback,
  wire and local producers, diagnostic ownership and duration, a real lifecycle
  tick, presenter-owned projection and bounded agent alerts.
