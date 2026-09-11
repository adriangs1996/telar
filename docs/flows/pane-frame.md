# Pane frame

A pane frame is the runtime's bounded screen projection for one client
attachment. The client commits that projection to disposable state, repairs
client-only resources and presents it before acknowledging the frame. The
runtime remains authoritative for terminal history and never publishes the
next dependent patch until the acknowledgement arrives.

## Client boundary

```text
schema.pane_frame
       |
server_messages dispatcher
       |
pane_frames adapter
       |
ApplyPaneFrameHandler
       |
ClientModel.applyPaneFrame
       |
multiplexer.Model.applyFrame + copy-mode reconciliation
       |
PaneFrameOutcome
       |
       +-- detached -> no effects
       +-- resync   -> request_snapshot
       +-- applied  -> ClientModel.Version.frame
                              |
                    DeliverPaneFrameHandler
                              |
                    validate exact commit
                              |
                    graphics + active resources + telemetry
                              |
                    presentation_lifecycle.observe
                              |
                     host flush -> frame_ack
```

`ClientModel.applyPaneFrame` owns the semantic transaction. It resolves pane
membership, rejects frames for unknown panes, ignores frames made stale by
detach and compares patch bases with the last applied frame. A broken base
returns the pane identity and known frame id without changing the model.

A valid frame applies cells, cursor, mouse mode, input modes and scroll state
through `multiplexer.Model.applyFrame`, which delegates identity/base admission,
cell ownership, damage and child modes to `telar-client.panes.Pane.applyFrame`.
That pane capability has no renderer dependency. `ClientModel` also reconciles
active copy state against retained-history pruning before publishing one frame revision. The
returned commit contains values only: pane and tab identity, frame id,
visibility, snapshot status, applied work and the exact workspace, tab,
active-tab, pane and frame revisions.

Every successfully applied frame advances `ClientModel.Version.frame`, even
when it changes no visible cell. The revision represents an acknowledgement
obligation as well as screen content. Failed application, broken bases and
detached frames do not advance it.

## Effects and failure policy

`ApplyPaneFrameHandler` runs recovery or post-commit effects according to the
model outcome. The `pane_frames` adapter maps a broken base to
`request_snapshot`. After a valid commit it delegates to
`DeliverPaneFrameHandler`, which rejects stale identity, topology, frame and
visibility state before ordering physical graphics visibility and active-pane
resource synchronization. The adapter implements those ports through the
graphics store and `DeliverActivePaneResourcesHandler`, then records frame
telemetry against the committed state. A focused pane that has just enabled
focus events receives one focus-in. Report state advances no presentation
revision.

No use case or protocol adapter requests a draw. If a resource effect fails,
the applied frame and copy-state reconciliation remain committed. Rolling them
back would invent a second client state after the runtime frame was already
accepted; reconnect or canonical reconciliation repairs disposable resources.

## Presentation and acknowledgement

After each event, `client_events` publishes the latest model version through
`presentation_lifecycle.observe`. `Presenter` compares that value with the
version it last observed and folds all pending revisions into one paced draw.
Frame application records only semantic pane damage in the multiplexer. The
presenter-owned compositor decides whether the immutable projection needs full
or incremental composition.

`Presenter.presentDue` composes the active model and prepares the terminal cell
diff. The common presentation lifecycle seals one owned commit and returns its
token. Only successful host-write completion releases that commit to the shared
application handler. It filters attachment generations, retires exact pending
frame IDs and derives `frame_ack` messages. A frame cannot release the runtime's
next dependent patch merely because composition finished.

The model allocates attachment generations across detach, reattach and workspace
reconstruction. An old completion cannot ACK a new attachment with an equal
wire frame ID. Receiving frame N+1 while N is being delivered leaves N+1's damage
pending. The headless adapter proves these rules through the same handlers and
outbox without terminal resources.

## Proof

- `src/client/model/Model.zig` and `src/client/model/tests/` proves atomic screen and copy-state commit,
  exact revisions, stale detach handling, base recovery and failed-apply
  behavior.
- `src/client/application/panes/pane_frame.zig` proves effect selection,
  commit-before-effect ordering and failure policy.
- `src/client/application/panes/pane_frame_delivery.zig` proves exact
  post-commit validation, graphics idempotence, resource ordering and partial
  failure semantics.
- `src/frontend/client/tests/pane_updates.zig` and `src/client/presentation/headless_tests.zig` proves recovery IPC, resource
  synchronization, presenter-owned scheduling and acknowledgement after
  presentation.
- `src/client/panes/tests.zig` proves owned cells, child modes, base and identity
  rejection, resize admission, stale presentation retirement, allocation-free
  same-size patches and allocation-failure cleanup without a terminal.
- `src/frontend/workspace/multiplexer.zig` retains composition and integration
  tests against that shared pane capability.
- `src/backend/runtime/attachment/cell.zig` and transport integration tests prove
  diff publication against acknowledged bases.
