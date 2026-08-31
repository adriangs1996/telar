# Client event dispatch

This flow starts when the client's select completes one asynchronous event. It
ends after the owning adapter finishes and the presenter observes the resulting
state, or when that event terminates the disposable client.

## Boundary

`run` owns platform setup, the runtime handshake, resource lifetime and the
blocking `select.await`. It does not know which adapter handles each event.

`client_events.handle` is the single entrypoint for a completed `ClientEvent`.
It owns three policies:

- classification into the interactive, media or observation path;
- exhaustive delegation to the adapter that owns the event;
- one presentation observation after every successful non-terminal event.

The dispatcher contains no slice flow. Input routing, transport, timers,
presentation workers, plugin completion and clipboard completion remain in
their existing adapters. Adding a `ClientEvent` requires an explicit dispatcher
case and an explicit budget.

```text
run: select.await
        |
client_events.handle
        |
diagnostics path guard
        |
one owning adapter
        |
keep_running -----------------> presentation_lifecycle.observe
        |
exit status ------------------> run returns, Client.deinit cancels tasks
```

## Borrowed resources

Most events need only `Client`. Host resize also borrows the live TTY and resize
watcher. Telemetry borrows the process heap counter. `client_events.Resources`
groups those three process-owned values without transferring ownership.

The dispatcher retains no event payload. The resize adapter may rearm a task
that borrows the watcher; `run` keeps that watcher alive until `Client.deinit`
cancels the select. A runtime receive buffer may be reused only after its server
event has completed dispatch.

## Continuation and termination

`Outcome.keep_running` means the selected adapter completed and the client can
present its resulting state. The dispatcher calls
`presentation_lifecycle.observe` before returning that outcome. Unchanged
versions schedule no frame.

`Outcome.exit` carries the process status selected by an input stop, runtime
shutdown or plugin exit. The dispatcher skips presentation observation because
this client will deliver no later frame. An adapter error also skips observation
and propagates to `run`; client teardown cancels outstanding workers before
freeing their borrowed state.

## Path budgets

Input, deadlines, resize, runtime transport, cell presentation and sidebar
animation remain on the interactive path. Clipboard image and media pacing use
the media path. Notification, sound, telemetry, configuration and plugin worker
completions use the observation path.

The path guard covers both adapter work and the post-event presentation
observation. Release builds keep the same routing without diagnostics counters.

## Proof

- `client event paths preserve interactive media and observation budgets` in
  `src/frontend/client/client_events.zig` covers every event tag.
- `client event dispatch observes a completed capability expiry` proves that a
  non-terminal commit reaches Presenter before the next event.
- `client event dispatch skips observation after terminal input` proves that
  EOF returns status `0` without scheduling a frame.
- Existing substituted-platform tests exercise the adapters that the
  dispatcher delegates to, including transport, timers, workers and
  presentation completion.
