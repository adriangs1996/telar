# Client presentation lifecycle

A client event commits semantic or physical display state. Presentation observes
that state, prepares bounded work and reports delivery. Only then can the
application retire exact frame damage and enqueue acknowledgements.

## Boundary

The common `telar-client.presentation` capability owns the borrowed projection,
observations, pane-coordinate geometry and single-flight completion identity.
Each client has its own lifecycle. The TUI `Presenter` owns `Screen`, compositor,
pacing, draw/media deadlines and physical caches. Handlers never request draws.

```text
committed client event
        |
presentation_lifecycle.observe
        |
model version + resource/input/geometry revisions
        |
common lifecycle.observe -> TUI pacing
        |
shared capture + TUI resources -> Presenter.presentDue
        |
compose and encode -> lifecycle.begin -> owned token
        |
sealed output bytes -> host write completion
        |
lifecycle.complete(token, delivered)
        |
DeliverPresentationHandler
        |
filter attachment generations + exact damage commit
        |
graphics credits -> frame_ack -> optional media task
```

The headless adapter uses the same projection, lifecycle and delivery handler.
It copies cells into bounded storage instead of encoding a terminal diff. Its
caller controls when preparation and delivery fail or finish.

## Observation and preparation

`Observation` contains `ClientModel.Version`, graphics and attachment ingress,
visible input/view interaction revisions and the workbench-grid revision. The
lifecycle keeps observed, prepared and delivered values separately. Observing
unchanged prepared work adds no frame, including while its write is pending.
A newer observation replaces the desired version; there is no frame queue.

TUI scheduling retains burst credit, input grace and the existing paced draw
deadline. An event may prepare immediately or coalesce onto that deadline.
`presentation_projection` supplies host context to the shared `capture` builder.
Rendering borrows model data synchronously and receives TUI resources separately.
No worker borrows the model or the projection.

The compositor keeps last-painted cells, its layout snapshot and copy projection.
It reads the shared workspace and returns its bounded `PresentationCommit`,
including fullscreen-hidden panes. An empty active model composes an explicit
empty screen. Preparation advances prepared revisions, not delivered revisions
or pane acknowledgement state.

## Output and completion

`host_output.Output` keeps one sealed byte slice in flight. Sideband bytes may
accumulate in its other bounded buffer. When output is occupied, the lifecycle
records deferred draw/media work without composing another diff or discarding
the partly written one. The actor returns after the complete write and flush.
A zero-byte diff may complete inline because the host already has those cells.

The common lifecycle consumes the matching token once. A duplicate or replaced
token cannot complete a newer flight. A valid completion for an older model
version still identifies only that version's captured pane frames.

`ClientModel.commitPresentation` rejects retired attachment generations, even
when a reconstructed pane reuses the same wire frame number. Exact pending-frame
matching prevents an old delivery from clearing newer damage. The handler
derives ACKs from the accepted commit rather than accepting an unrelated array.
It orders model commit, released graphics credit, ACKs and optional media work.

`Geometry` owns region, tab, layout, host size and pane-shape identities. A new
TUI pointer gesture cannot use changed pane geometry during an in-flight
presentation. Captured gestures retain their existing owner. Widget hit maps
remain adapter-owned; the contract does not prescribe native widget layout.

## Media and host services

Media retains its existing independent deadline, quotas and byte budget. Cell
output takes priority. Image and attachment consumers acquire explicit leases
when bytes outlive a synchronous call. Obsolete allocations stay charged until
the last consumer releases them; completing cells alone cannot return that
storage's credit.

Window-title formatting and change suppression use a shared synchronous title
port. The TUI supplies hostname lookup and OSC encoding. Clipboard, links,
notifications, sound and other host effects continue through their application
ports. No common handler receives a terminal writer or a GPU device.

## Failure and teardown

Failed preparation cannot create a delivery. Failed or cancelled completion
keeps model damage pending and permits a fresh preparation. Cancellation means
that consumers have stopped borrowing, not that their storage may be reused
while they are still running.

The TUI never cancels a partial diff to replace it. Write failure ends that
client. The driver cancels and joins actors before freeing output, graphics and
model storage; a new connection rebuilds runtime snapshots. Runtime PTYs and
history remain valid after client death.

After successful delivery, a credit, ACK or media-scheduling error does not
undo earlier effects. The existing event loop closes that client and snapshot
reconciliation recovers it. Completion does not claim physical input-to-photon
or monitor presentation timing.

## Proof

- `src/client/presentation/lifecycle.zig` tests coalescing, busy admission,
  failure, cancellation and exact-token completion.
- `src/client/presentation/headless_tests.zig` exercises shared entrypoints,
  handlers, resource lifetime and outbox without a terminal.
- `src/client/application/presentation/presentation_delivery.zig` tests bounded
  commits, effect ordering and failures after commit.
- `src/frontend/client/tests/presentation.zig` tests TUI pacing, observations,
  media priority and the successful/failed host-write boundary.
- `src/frontend/client/resources/host_output.zig` tests immutable sealed bytes,
  nonblocking prefixes, exact-once writes and token release.
- `src/frontend/workspace/multiplexer.zig` keeps full/incremental composition,
  hidden-pane and stale-damage tests against the common pane model.
