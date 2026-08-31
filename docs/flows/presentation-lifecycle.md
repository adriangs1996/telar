# Client presentation lifecycle

This flow starts after a client event commits semantic or physical display
state. It ends when the latest state reaches the host terminal, its frame
acknowledgements enter runtime transport, and any remaining graphics work has
one media task scheduled.

## Boundary

`Presenter` owns the host screen buffers, pane compositor, observed and
presented revisions, frame pacing, draw and media scheduling tokens and the
last presented timestamp. It decides whether a revision needs a frame. Client
use cases never schedule a frame; visible changes reach the presenter through
the observation boundary.

`presentation_lifecycle` is the asynchronous adapter. `client_events`
delegates `.draw` and `.media_tick` events to it and publishes one observation
after every non-terminal event. The adapter releases task tokens, asks the
presenter for a delivery and supplies concrete effects to
`DeliverPresentationHandler`. The handler owns the irreversible post-flush
policy. Neither component decides which parts of the screen changed.

```text
committed client event
        |
presentation_lifecycle.observe
        |
model Version + graphics/attachment ingress + PresentationIngress
        |
Presenter.observe -> one paced draw task
        |
ClientEvent.draw -> presentation_lifecycle.handleDraw
        |
presentation_projection -> Presenter.presentDue -> cell flush
        |
DeliverPresentationHandler
        |
PresentationCommit -> graphics credits -> frame_ack messages -> optional media task
        |
ClientEvent.media_tick -> presentation_lifecycle.handleMediaTick
        |
bounded graphics flush
```

## Observation and frame choice

The dispatcher publishes one complete `Presenter.Observation` after every
non-terminal event. It contains the semantic `ClientModel.Version` and the
ingress versions of pane graphics, client attachments, view interactions and
visible input routing. `Presenter` compares it with both the last observation
and the last successful presentation.

An identical observation does nothing while a draw is pending. A newer
observation increments the saturating `pending_updates` count but retains the
same draw task. Once no draw task is pending, an observation newer than the
last successful presentation schedules one task. The pacer emits an idle frame
immediately and limits burst presentation to one frame per `1 / 60` second.

The `presentation_projection` adapter captures one bounded immutable projection
from the concrete client aggregate. It includes the model version, immutable
semantic snapshots, active tab model and copy-mode value. It separately exposes
the mutable view, graphics store and host writer that presentation owns.
`Presenter` imports neither `Client` nor its event union; an opaque scheduling
port arms the client-owned draw and media tasks.

`PresentationIngress` keeps disposable hover, sidebar scroll, attachment-modal
and prefix-router state out of `ClientModel`. Their owners expose only monotonic
revisions. Input adapters do not return redraw commands or call
`Presenter.requestDraw`; the event-loop observation is the scheduling boundary.

`ClientModel.activeTabModelConst` returns null during bootstrap and workspace
handoff. A due draw then flushes an explicit empty screen instead of unwrapping
a missing tab.

## Cell and media passes

The draw adapter releases `draw_pending` before checking the worker result.
`Presenter.presentDue` compares changed model revisions, projects disposable
view state, asks its `multiplexer.Compositor` to compose the immutable active
tab, composes chrome and flushes the terminal cell diff. The compositor owns
the last-painted cells, layout snapshot and copy projection. Copy selection
changes patch only their affected visible ranges.

Only a successful flush advances the presented revisions and clears
`pending_updates`. The returned `PresentationCommit` describes the exact pane
damage and pending frame identifiers safe to retire after that flush, including
panes intentionally hidden by fullscreen layout. `DeliverPresentationHandler`
applies it to `ClientModel` before invoking any external effect. Exact frame
matching prevents an obsolete commit from consuming newer pane work.

The presenter returns a fixed array of at most `multiplexer.max_panes` frame
acknowledgements. `DeliverPresentationHandler` rejects an unbounded command
before mutation, then flushes graphics flow-control credits and acknowledges
each frame in presenter order. It requests media only after every
acknowledgement succeeds. The lifecycle adapter contains only the concrete
transport, telemetry and presenter callbacks. The runtime therefore learns
about a frame only after the host terminal accepted it.

Media uses its own task token and `ClientEvent.media_tick`. A pending cell frame
always defers media. Each pass uses the fixed 256 KiB baseline KGP budget and
keeps incomplete transfers scheduled without blocking cell output. Input
activity can delay graphical toasts, but it does not delay pane cells.

## Failure and lifetime

Draw and media completion release their tokens before propagating a worker
error. A failed cell composition or flush leaves semantic damage and pending
frame identifiers uncommitted, and leaves the observed version newer than the
presented version. After a successful host flush, the handler commits the
presentation before attempting transport. A later credit, acknowledgement or
media scheduling failure preserves every earlier effect and skips the remaining
ones. The current event loop treats either class of error as fatal and destroys
the disposable client. The runtime remains canonical and a new client rebuilds
its projection.

Client destruction cancels the select tasks before deinitializing the
presenter and its screen buffers. `Presenter` owns no work queue. It retains
one draw task, one media task and the latest revisions.

## Proof

- `src/frontend/client/presentation_projection.zig` is the concrete-client to
  immutable-presentation boundary.
- `src/frontend/client/presenter.zig` owns comparison, pacing, composition,
  fixed frame acknowledgements and independent media scheduling without a
  `Client` dependency.
- `src/frontend/client/presentation_lifecycle.zig` proves the event entrypoints
  and adapts concrete transport, telemetry and presenter effects.
- `src/frontend/client/application/presentation_delivery.zig` owns and proves
  bounded post-flush model-commit, credit, acknowledgement and media ordering,
  including partial failure semantics.
- `composition damage retires only after its presentation commits`, `stale
  presentation commits preserve newer pane work` and `fullscreen presentation
  commits include hidden panes` prove bounded commit semantics.
- `presentation folds repeated observations into one draw task` proves that an
  identical observation adds no work and newer revisions share one task.
- `host input presentation state schedules only through observation` proves
  that prefix state cannot schedule a frame before the presenter observes it.
- `attachment modal captures semantic keys until escape closes it` proves that
  a no-op modal key advances no revision and Escape reaches presentation only
  through observation.
- `presentation flushes an explicit empty model before bootstrap` proves the
  no-tab lifecycle.
- `presentation worker failures release their scheduling tokens` injects both
  worker failures and proves token release.
- Pane-frame and pane-graphics integration tests prove acknowledgement order,
  resource observation, cell priority and bounded media continuation.
