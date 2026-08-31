# Client presentation lifecycle

This flow starts after a client event commits semantic or physical display
state. It ends when the latest state reaches the host terminal, its frame
acknowledgements enter runtime transport, and any remaining graphics work has
one media task scheduled.

## Boundary

`Presenter` owns the host screen buffers, observed and presented revisions,
frame pacing, draw and media scheduling tokens, copy-mode projection and the
last presented timestamp. It decides whether a revision needs a frame. Client
use cases never schedule a frame; visible changes reach the presenter through
the observation boundary.

`presentation_lifecycle` is the asynchronous adapter. The client loop delegates
observation, `.draw` and `.media_tick` events to it. The adapter releases task
tokens and orders presentation effects that cross into runtime transport. It
does not decide which parts of the screen changed.

```text
committed client event
        |
presentation_lifecycle.observe
        |
model Version + graphics ingress + attachment ingress
        |
Presenter.observe -> one paced draw task
        |
ClientEvent.draw -> presentation_lifecycle.handleDraw
        |
Presenter.presentDue -> cell flush
        |
graphics credits -> frame_ack messages -> optional media task
        |
ClientEvent.media_tick -> presentation_lifecycle.handleMediaTick
        |
bounded graphics flush
```

## Observation and frame choice

The loop publishes one complete `Presenter.Observation` after every event. It
contains the semantic `ClientModel.Version` and the ingress versions of pane
graphics and client attachments. `Presenter` compares it with both the last
observation and the last successful presentation.

An identical observation does nothing while a draw is pending. A newer
observation increments the saturating `pending_updates` count but retains the
same draw task. Once no draw task is pending, an observation newer than the
last successful presentation schedules one task. The pacer emits an idle frame
immediately and limits burst presentation to one frame per `1 / 60` second.

The model query `ClientModel.activeTabModel` returns null during bootstrap and
workspace handoff. A due draw then flushes an explicit empty screen instead of
unwrapping a missing tab.

## Cell and media passes

The draw adapter releases `draw_pending` before checking the worker result.
`Presenter.presentDue` projects changed model revisions into disposable view
state, composes the active tab and chrome, and flushes the terminal cell diff.
Only a successful flush advances the presented revisions and clears
`pending_updates`.

The presenter returns a fixed array of at most `multiplexer.max_panes` frame
acknowledgements. The adapter first flushes graphics flow-control credits, then
enqueues each `.frame_ack`. The runtime therefore learns about a frame only
after the host terminal accepted it.

Media uses its own task token and `ClientEvent.media_tick`. A pending cell frame
always defers media. Each pass uses the fixed 256 KiB baseline KGP budget and
keeps incomplete transfers scheduled without blocking cell output. Input
activity can delay graphical toasts, but it does not delay pane cells.

## Failure and lifetime

Draw and media completion release their tokens before propagating a worker
error. A failed cell composition or flush leaves the observed version newer
than the presented version. The current event loop treats that error as fatal
and destroys the disposable client. Transport failure after a successful host
flush has the same policy. The runtime remains canonical and a new client
rebuilds its projection.

Client destruction cancels the select tasks before deinitializing the
presenter and its screen buffers. `Presenter` owns no work queue. It retains
one draw task, one media task and the latest revisions.

## Proof

- `src/frontend/client/presenter.zig` owns comparison, pacing, composition,
  fixed frame acknowledgements and independent media scheduling.
- `src/frontend/client/presentation_lifecycle.zig` proves the event entrypoints
  and post-flush transport ordering.
- `presentation folds repeated observations into one draw task` proves that an
  identical observation adds no work and newer revisions share one task.
- `presentation flushes an explicit empty model before bootstrap` proves the
  no-tab lifecycle.
- `presentation worker failures release their scheduling tokens` injects both
  worker failures and proves token release.
- Pane-frame and pane-graphics integration tests prove acknowledgement order,
  resource observation, cell priority and bounded media continuation.
