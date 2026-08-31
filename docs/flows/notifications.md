# Notifications

Notifications are bounded, disposable client state. `ClientModel` owns their
content, identity and lifecycle. `View` and both toast renderers receive an
immutable snapshot and never decide whether a notification exists, expires or
starts exiting.

## Publication path

```text
runtime event, request failure or local client diagnostic
                         |
                    Client.notify
                         |
              notifications client adapter
                         |
             PublishNotificationHandler
                         |
              ClientModel.publishNotification
                         |
       notifications.Center + Version.notifications
                         |
                  timer reschedule
                         |
                 Client.observeModel
                         |
          Presenter -> View.render(snapshot)
```

The runtime can publish a notification directly. Request failures, agent and
proxy transitions, configuration or plugin diagnostics, and clipboard image
failures use the same local entrypoint. `Client.notify` adds the monotonic
timestamp and delegates to the application handler. The handler commits the
owned model state before it touches timer infrastructure.

`notifications.Center` copies title and message bytes into fixed buffers. It
keeps at most four items, refreshes an equivalent active item and replaces the
oldest item at capacity. Invalid UTF-8 is replaced before storage. Publication
does not request a frame directly.

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

The notification timer asks `ClientModel.nextNotificationDeadline` for the
next useful wakeup. Moving items wake at the presenter's frame interval, while
stable items sleep until expiry. A timer event executes
`AdvanceNotificationsHandler`, which advances the center from elapsed
monotonic time, commits `Version.notifications` only when state changed and
always rearms the next deadline.

The client run loop calls `Client.observeModel` after the event. `Presenter`
compares the notification version with the last version it painted, invalidates
the view and passes `ClientModel.notificationSnapshot()` into the next paced
frame. Several lifecycle ticks inside one frame budget therefore fold into one
projection of the latest state.

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
optional tab, workspace or pane navigation
```

The view returns only the notification ID and consumes the click. Activation
starts the exit transition before the input adapter follows its semantic
target. Dismissal starts the same transition without navigation. Missing IDs
and IDs already exiting are stale no-ops, so a repeated hit cannot repeat its
action or click through into a pane.

## Bounds and recovery

The center allocates nothing in steady state. Titles, messages and the four
slots are fixed-size values. Entering and exiting transitions last 200 ms in
wall-clock time; presentation cadence only selects samples from that curve.
The timer stores one replaceable deadline, so obsolete animation work does not
build a queue.

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
  timer ordering, delivery policy, stale interaction behavior and retained
  commits when timer scheduling fails.
- `src/frontend/client/notifications.zig` proves delivery correlation and
  connects every application notification use case to client infrastructure.
- `src/frontend/client/view.zig` proves immutable rendering, ID-only intents
  and cell restoration after an exit.
- `src/frontend/client/client_test.zig` proves wire and local producers,
  presenter-owned projection and bounded agent alerts.
